import Foundation
import MLX
import MLXAudioLLM
import Observation

/// Streams a single child-safe story from the on-device Qwen3 text model.
///
/// `StoryTextGenerator` is the **text** half of the Story Kingdom writer. It is
/// deliberately kept separate from the TTS engine:
///
/// - It loads a plain Qwen3 chat model (no `speech_tokenizer`, no variants)
///   straight from the local download directory managed by
///   `StoryModelManagerViewModel`.
/// - It runs **in-process** (not in the TTS XPC service) and is the only code
///   path that touches the story LLM.
/// - To protect 8 GB Macs where the TTS model and the story LLM cannot be
///   co-resident, the generator enforces strict serial usage: it loads the
///   model only for the duration of a single `generate(theme:)` call, streams
///   the answer, then drops the `ChatSession` + `ModelContainer` and calls
///   `Memory.clearCache()` before returning. By the time the caller hands the
///   finished story text to the TTS read-aloud path, the story LLM is fully
///   unloaded.
///
/// The generator is `@MainActor` + `@Observable` so a SwiftUI view can bind to
/// `streamingText` / `phase` directly. Only one generation may be active at a
/// time (`phase` guards reentrancy); `cancel()` aborts an in-flight stream.
@MainActor
@Observable
final class StoryTextGenerator {

    /// Coarse progress for the writer UI.
    enum Phase: Equatable, Sendable {
        case idle
        case loadingModel
        case generating
        /// Generation finished (or was cancelled) and the model is being unloaded.
        case unloading
        case failed(String)
    }

    /// A finished, parsed story. The header (`title`/`subtitle`) comes from the
    /// model's structured output; `body` is the read-aloud text handed to TTS.
    struct StoryResult: Equatable, Sendable {
        let title: String
        let subtitle: String
        let body: String
    }

    /// The story **body** accumulated so far for the in-flight (or
    /// just-finished) story, with `<think>…</think>` reasoning blocks and the
    /// structured header (`标题:`/`简介:`/`故事:`) stripped out. This is what
    /// the child-facing streaming surface shows. Reset to `""` at the start of
    /// each `generate(theme:)` call.
    private(set) var streamingText: String = ""

    /// The parsed header + body of the last finished generation. Set when the
    /// phase flips to `.idle` after a successful generation; `nil` otherwise.
    /// The view reads `title`/`subtitle` from here to build the list row.
    private(set) var lastResult: StoryResult?

    /// Current writer phase. Drives the generate / stop / loading affordances.
    private(set) var phase: Phase = .idle

    /// `true` while a story is being produced (loading, generating, or
    /// unloading). Convenience for view enablement.
    var isActive: Bool {
        switch phase {
        case .loadingModel, .generating, .unloading:
            return true
        case .idle, .failed:
            return false
        }
    }

    private var generationTask: Task<Void, Never>?
    private var generationEpoch = 0
    /// Raw, never-stripped accumulation of every streamed chunk. We re-strip
    /// the *whole* buffer each frame because stripping in place corrupts
    /// mid-stream `<think>` blocks (the opening tag gets removed and its
    /// contents leak as ordinary text). Kept private — only `streamingText`
    /// and `lastResult` are view-facing.
    private var rawBuffer: String = ""

    private let modelsDirectory: URL

    init(modelsDirectory: URL = QwenVoiceApp.modelsDir) {
        self.modelsDirectory = modelsDirectory
    }

    // MARK: - Generation

    /// Begins streaming a story for `theme`. Throws / surfaces failures via
    /// `phase` (`.failed`) rather than rethrowing, so the caller doesn't need
    /// its own do/catch for the common error paths.
    ///
    /// - Precondition: no other generation is active. A second call while
    ///   `isActive` is `true` is ignored.
    /// - Postcondition: when the call returns (success, cancellation, or
    ///   failure) the story LLM is unloaded and `Memory.clearCache()` has run,
    ///   so the TTS engine is free to take over.
    func generate(theme: StoryTheme) {
        guard !isActive else { return }
        cancelPreviousGeneration()
        let epoch = makeNewGenerationEpoch()

        streamingText = ""
        rawBuffer = ""
        lastResult = nil
        phase = .loadingModel

        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runGeneration(theme: theme, epoch: epoch)
        }
    }

    /// Aborts an in-flight generation. The model is still unloaded afterwards.
    func cancel() {
        generationTask?.cancel()
    }

    /// Resets to `idle`, clearing any partial text. Safe to call any time; if a
    /// generation is active it is cancelled first.
    func reset() {
        cancel()
        generationEpoch &+= 1
        generationTask = nil
        streamingText = ""
        rawBuffer = ""
        lastResult = nil
        phase = .idle
    }

    // MARK: - Internals

    private func runGeneration(theme: StoryTheme, epoch: Int) async {
        // Snapshot the model directory up front; if the user deletes the story
        // model mid-generation we want a clean failure, not a half-loaded state.
        guard let storyModel = StoryModelContract.storyModel else {
            phase = .failed("没有可用的故事模型。")
            generationTask = nil
            return
        }

        let installDir = storyModel.installDirectory(in: modelsDirectory)
        let fileManager = FileManager.default
        if !storyModel.isAvailable(in: modelsDirectory, fileManager: fileManager) {
            phase = .failed("故事模型尚未下载完成，请先在「设置」中下载。")
            generationTask = nil
            return
        }

        var container: ModelContainer?
        do {
            // Load from the already-downloaded local directory — never re-fetch.
            // `loadModelContainer(hub:directory:)` is a free function in
            // MLXLMCommon (re-exported via MLXAudioLLM).
            container = try await loadModelContainer(directory: installDir)
        } catch is CancellationError {
            await finishCancelled(epoch: epoch)
            return
        } catch {
            await unloadAndFinish(.failed("加载故事模型失败：\(error.localizedDescription)"), epoch: epoch)
            return
        }

        guard epoch == generationEpoch else {
            // A newer generation superseded this one; just drop our container.
            await unload(container: container)
            return
        }

        guard let container else {
            await finishCancelled(epoch: epoch)
            return
        }

        phase = .generating
        // `enable_thinking: false` is the Qwen3 chat-template switch that
        // pre-fills an empty `<think>\n\n</think>` block at the assistant turn,
        // so the model skips reasoning and emits the story directly. This keeps
        // streaming latency low and means `<think>` blocks never appear in
        // output (the strip logic stays as a belt-and-suspenders guard).
        let session = ChatSession(
            container,
            instructions: StoryTheme.systemPrompt,
            generateParameters: GenerateParameters(maxTokens: 2048, temperature: 0.7, topP: 0.95),
            additionalContext: ["enable_thinking": false]
        )

        do {
            let stream = session.streamResponse(to: theme.prompt)
            for try await chunk in stream {
                if Task.isCancelled { break }
                if epoch != generationEpoch { break }
                // Accumulate the raw chunk verbatim, then re-strip the ENTIRE
                // buffer each frame. Stripping incrementally corrupts mid-stream
                // <think> blocks: once the opening tag is removed, the reasoning
                // text leaks as ordinary output and `</think>` shows up literal.
                rawBuffer += chunk
                let stripped = Self.stripThinkContent(from: rawBuffer)
                streamingText = Self.extractStoryBody(from: stripped)
            }
            try await session.synchronize()
        } catch is CancellationError {
            // Fall through to unload; streamingText retains whatever streamed.
        } catch {
            await unload(container: container)
            phase = .failed("生成故事时出错：\(error.localizedDescription)")
            generationTask = nil
            return
        }

        await unload(container: container)

        if epoch == generationEpoch && !Task.isCancelled {
            let stripped = Self.stripThinkContent(from: rawBuffer)
            let result = Self.parseStoryResult(from: stripped, fallbackTheme: theme)
            let body = result.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                phase = .failed("模型没有返回有效的故事内容，请重试。")
            } else {
                streamingText = body
                lastResult = result
                phase = .idle
            }
        }
        generationTask = nil
    }

    /// Drops the `ChatSession` (by going out of scope) and the `ModelContainer`,
    /// then clears the MLX compute cache so the TTS engine is free to allocate.
    /// Called on every exit path — success, cancel, failure.
    private func unload(container: ModelContainer?) async {
        phase = .unloading
        // `container` is the only strong reference once the ChatSession built
        // from it is dropped; nil-ing it + clearCache() releases the weights.
        _ = container
        Memory.clearCache()
    }

    private func finishCancelled(epoch: Int) async {
        await unload(container: nil)
        if epoch == generationEpoch {
            phase = .idle
        }
        generationTask = nil
    }

    private func unloadAndFinish(_ newPhase: Phase, epoch: Int) async {
        await unload(container: nil)
        if epoch == generationEpoch {
            phase = newPhase
        }
        generationTask = nil
    }

    private func cancelPreviousGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }

    private func makeNewGenerationEpoch() -> Int {
        generationEpoch &+= 1
        return generationEpoch
    }

    // MARK: - Think stripping

    /// Removes `<think>…</think>` reasoning blocks (including unclosed ones
    /// mid-stream) and trims surrounding whitespace. Matches the approach used
    /// by the vendored SimpleChat `ConversationController`. Operates on the
    /// full raw buffer so a half-arrived `<think>` open tag is handled
    /// correctly (it cuts everything from the open tag to the end until the
    /// closing tag streams in).
    private static let thinkRegex: NSRegularExpression = {
        // Case-insensitive, dot-matches-newline. `<think` + optional attrs up to
        // `>`, then anything (non-greedy) up to `</think>`.
        let pattern = #"(?is)<think\b[^>]*>.*?</think>"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    static func stripThinkContent(from text: String) -> String {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = thinkRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: fullRange,
            withTemplate: ""
        )
        // Also drop an unclosed trailing `<think…` block (happens while the
        // reasoning section is still streaming, before `</think>` arrives).
        guard let openRange = stripped.range(of: #"(?is)<think\b[^>]*>"#, options: .regularExpression) else {
            return stripped
        }
        // If there's no closing tag after the open, cut from the open to the end.
        let afterOpen = stripped[openRange.upperBound...]
        if afterOpen.range(of: #"(?i)</think>"#, options: .regularExpression) == nil {
            return String(stripped[..<openRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stripped
    }

    // MARK: - Structured header parsing

    /// Parses the model's structured output (`标题:`/`简介:`/`故事:`) into a
    /// `StoryResult`. Falls back to the theme label + the whole text as body
    /// when the header markers are missing (e.g. the model ignored the format),
    /// so the writer never shows a blank or malformed row.
    static func parseStoryResult(from stripped: String, fallbackTheme: StoryTheme) -> StoryResult {
        let title = Self.extractField("标题", from: stripped)
            ?? Self.extractField("Title", from: stripped)
            ?? fallbackTheme.title
        let subtitle = Self.extractField("简介", from: stripped)
            ?? Self.extractField("Synopsis", from: stripped)
            ?? fallbackTheme.subtitle
        let body = Self.extractStoryBody(from: stripped)
        return StoryResult(title: title, subtitle: subtitle, body: body)
    }

    /// Pulls the value of a labeled header field (e.g. `标题: xxx`). Returns
    /// everything after the `label:` up to the next field marker or end of
    /// text. Tolerates a full-width or ASCII colon and surrounding whitespace.
    private static func extractField(_ label: String, from text: String) -> String? {
        // Match `label` + optional space + (：or :) + optional space, then
        // capture up to the next line that starts with a known field marker
        // (标题/简介/故事/Title/Synopsis/Story) or end of string.
        let pattern = #"(?is)\#(NSRegularExpression.escapedPattern(for: label))\s*[：:]\s*(.+?)(?:\n\s*(?:标题|简介|故事|Title|Synopsis|Story)\s*[：:]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let value = String(text[captureRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Extracts just the story body — everything after the `故事:` / `Story:`
    /// marker, or the whole stripped text if no marker is present.
    static func extractStoryBody(from stripped: String) -> String {
        // Find the first `故事:` or `Story:` marker (full-width or ASCII colon)
        // and return everything after it.
        let pattern = #"(?is)(?:故事|Story)\s*[：:]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        guard let match = regex.firstMatch(in: stripped, options: [], range: range),
              let bodyRange = Range(match.range(at: 0), in: stripped) else {
            // No body marker yet (header still streaming): show nothing so the
            // child-facing surface stays empty until the actual story arrives.
            return ""
        }
        return String(stripped[bodyRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
