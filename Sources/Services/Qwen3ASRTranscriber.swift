import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import Observation

/// On-device speech recognition for the read-along training feature, backed by
/// the Qwen3-ASR 0.6B model.
///
/// `Qwen3ASRTranscriber` is the **recognition** half of the read-along loop.
/// Like `StoryTextGenerator`, it is deliberately kept separate from the TTS
/// engine and the system `VoiceClipTranscriber` (which wraps `SFSpeechRecognizer`):
///
/// - It loads the Qwen3-ASR model straight from the local download directory
///   managed by `ASRModelManagerViewModel` — never auto-downloads.
/// - It runs **in-process** (not in the TTS XPC service) and is the only code
///   path that touches the ASR model.
/// - To protect 8 GB Macs, the transcriber follows the same strict-serial
///   discipline as the story writer: the model is loaded only for the
///   duration of a `transcribe(audioURL:language:)` call, the result is
///   returned, then the model is dropped and `Memory.clearCache()` runs so the
///   TTS engine is free to take over for the feedback audio. When the read-along
///   loop is the consumer, TTS and ASR alternate rather than stay co-resident.
///
/// The transcriber is `@MainActor` + `@Observable` so a SwiftUI view can bind
/// to `phase` directly. Only one transcription may be active at a time.
@MainActor
@Observable
final class Qwen3ASRTranscriber {

    /// Coarse progress for the recognition UI.
    enum Phase: Equatable, Sendable {
        case idle
        case loadingModel
        case transcribing
        /// Recognition finished (or was cancelled) and the model is being unloaded.
        case unloading
        case failed(String)
    }

    /// The recognized text from the last completed transcription. Reset to
    /// `nil` at the start of each `transcribe` call; set when the phase flips
    /// back to `.idle` after a successful recognition.
    private(set) var recognizedText: String?

    /// Current recognition phase. Drives the transcribing / loading affordances.
    private(set) var phase: Phase = .idle

    /// `true` while recognition is in progress (loading, transcribing, or
    /// unloading). Convenience for view enablement.
    var isActive: Bool {
        switch phase {
        case .loadingModel, .transcribing, .unloading:
            return true
        case .idle, .failed:
            return false
        }
    }

    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionEpoch = 0

    private let modelsDirectory: URL

    init(modelsDirectory: URL = QwenVoiceApp.modelsDir) {
        self.modelsDirectory = modelsDirectory
    }

    // MARK: - Transcription

    /// Transcribes the audio at `audioURL` and returns the recognized text, or
    /// `nil` on failure / cancellation. Failures are also surfaced via `phase`
    /// (`.failed`) so the caller can bind without a do/catch.
    ///
    /// - Precondition: no other transcription is active. A second call while
    ///   `isActive` is `true` is ignored and returns `nil`.
    /// - Postcondition: when the call returns (success, cancellation, or
    ///   failure) the ASR model is unloaded and `Memory.clearCache()` has run.
    ///
    /// - Parameters:
    ///   - audioURL: Path to a WAV/CAF/m4a audio file. Any sample rate is
    ///     accepted — `loadAudioArray` resamples to the model's 16 kHz.
    ///   - language: Optional hint (e.g. `"Chinese"`, `"English"`). `nil` lets
    ///     the model auto-detect.
    ///   - maxTokens: Cap on generated tokens. Short read-along clips rarely
    ///     exceed a few tokens.
    func transcribe(
        audioURL: URL,
        language: String? = "Chinese",
        maxTokens: Int = 256
    ) async -> String? {
        guard !isActive else { return nil }
        cancelPreviousTranscription()
        let epoch = makeNewTranscriptionEpoch()

        recognizedText = nil
        phase = .loadingModel

        await runTranscription(
            audioURL: audioURL,
            language: language,
            maxTokens: maxTokens,
            epoch: epoch
        )

        return recognizedText
    }

    /// Aborts an in-flight transcription. The model is still unloaded afterwards.
    func cancel() {
        transcriptionTask?.cancel()
    }

    /// Resets to `idle`, clearing any partial result. Safe to call any time; if
    /// a transcription is active it is cancelled first.
    func reset() {
        cancel()
        transcriptionEpoch &+= 1
        transcriptionTask = nil
        recognizedText = nil
        phase = .idle
    }

    // MARK: - Internals

    private func runTranscription(
        audioURL: URL,
        language: String?,
        maxTokens: Int,
        epoch: Int
    ) async {
        guard let asrModel = ASRModelContract.asrModel else {
            phase = .failed("没有可用的语音识别模型。")
            transcriptionTask = nil
            return
        }

        let installDir = asrModel.installDirectory(in: modelsDirectory)
        let fileManager = FileManager.default
        if !asrModel.isAvailable(in: modelsDirectory, fileManager: fileManager) {
            phase = .failed("语音识别模型尚未下载完成，请先在「设置」中下载。")
            transcriptionTask = nil
            return
        }

        // Load from the already-downloaded local directory — never re-fetch.
        var model: Qwen3ASRModel?
        do {
            model = try await Qwen3ASRModel.fromModelDirectory(installDir)
        } catch is CancellationError {
            await finishCancelled(epoch: epoch)
            return
        } catch {
            await unloadAndFinish(.failed("加载语音识别模型失败：\(error.localizedDescription)"), epoch: epoch)
            return
        }

        guard epoch == transcriptionEpoch else {
            // A newer transcription superseded this one; just drop our model.
            await unload(model: model)
            return
        }

        guard let model else {
            await finishCancelled(epoch: epoch)
            return
        }

        phase = .transcribing

        do {
            // loadAudioArray resamples to the target rate (16 kHz) automatically
            // when `sampleRate:` is provided.
            let (_, audioData) = try loadAudioArray(from: audioURL, sampleRate: model.sampleRate)

            let output = try model.generate(
                audio: audioData,
                maxTokens: maxTokens,
                temperature: 0.0,
                language: language,
                chunkDuration: 30.0
            )

            await unload(model: model)

            if epoch == transcriptionEpoch && !Task.isCancelled {
                let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                recognizedText = text
                phase = .idle
            }
        } catch is CancellationError {
            await unload(model: model)
            await finishCancelled(epoch: epoch)
        } catch {
            await unload(model: model)
            phase = .failed("语音识别失败：\(error.localizedDescription)")
        }

        transcriptionTask = nil
    }

    /// Drops the `Qwen3ASRModel` (by nil-ing the only strong reference) then
    /// clears the MLX compute cache so the TTS engine is free to allocate.
    /// Called on every exit path — success, cancel, failure.
    private func unload(model: Qwen3ASRModel?) async {
        phase = .unloading
        _ = model
        Memory.clearCache()
    }

    private func finishCancelled(epoch: Int) async {
        await unload(model: nil)
        if epoch == transcriptionEpoch {
            phase = .idle
        }
        transcriptionTask = nil
    }

    private func unloadAndFinish(_ newPhase: Phase, epoch: Int) async {
        await unload(model: nil)
        if epoch == transcriptionEpoch {
            phase = newPhase
        }
        transcriptionTask = nil
    }

    private func cancelPreviousTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    private func makeNewTranscriptionEpoch() -> Int {
        transcriptionEpoch &+= 1
        return transcriptionEpoch
    }
}
