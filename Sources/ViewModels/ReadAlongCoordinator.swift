import AVFoundation
import Foundation
import Observation
import os
import QwenVoiceCore
import QwenVoiceNative

/// The voice the read-along loop speaks the target word and feedback with.
enum ReadAlongVoiceSource: String, CaseIterable, Identifiable, Sendable {
    /// A built-in Qwen3-TTS speaker (`.custom` payload).
    case builtIn
    /// A cloned reference voice (`.clone` payload) — reuses the voice the
    /// parent already enrolled, so the child trains against a familiar voice.
    case clone

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .builtIn: return "内置声音"
        case .clone: return "克隆声音"
        }
    }
}

/// Coarse state for the read-along loop UI. The coordinator is the single
/// source of truth for which step the loop is on; `ReadAlongView` binds to
/// `phase` to swap affordances (listen / speak / recognize / feedback).
enum ReadAlongPhase: Equatable, Sendable {
    case idle
    /// Generating the target word's TTS audio.
    case speakingTarget
    /// Playing back the target word (waiting for `audioPlayer` to finish).
    case playingTarget
    /// Mic is open, waiting for the child to speak.
    case listening
    /// Recognizing the captured audio with Qwen3-ASR.
    case recognizing
    /// Speaking the verdict feedback ("真棒!" / "再试一次").
    case speakingFeedback
    /// Playing back the feedback audio.
    case playingFeedback
    /// All words in the session are done.
    case sessionComplete
    case failed(String)
}

/// Orchestrates the read-along training loop end to end:
///
/// 1. **Speak the target** — generate TTS for the current word and play it.
/// 2. **Listen** — open the mic, let the VAD-lite auto-stop on silence.
/// 3. **Recognize** — run Qwen3-ASR on the captured samples.
/// 4. **Judge** — pure-Swift Levenshtein comparison against the target text.
/// 5. **Feedback** — generate + play a short TTS line for the verdict.
/// 6. **Advance** — on `.pass` go to the next word; on `.close`/`.retry`
///    repeat the same word (capped at `maxAttemptsPerWord`).
///
/// TTS and ASR **alternate**, never co-resident: the ASR transcriber loads
/// its model only for the `recognize` step and unloads + `Memory.clearCache()`
/// before the feedback TTS generation, mirroring the Story Kingdom writer's
/// strict-serial discipline so an 8 GB Mac can run the whole loop.
///
/// The coordinator is `@MainActor` + `@Observable` so `ReadAlongView` can
/// bind directly to `phase`, `currentTrial`, `lastAttempt`, etc.
@MainActor
@Observable
final class ReadAlongCoordinator {

    // MARK: - Published state

    private(set) var phase: ReadAlongPhase = .idle
    private(set) var session: ReadAlongSession?
    /// Index into `session.trials` for the current word.
    private(set) var currentWordIndex: Int = 0
    /// The most recent attempt result (for the feedback banner).
    private(set) var lastAttempt: ReadAlongAttempt?
    /// The exact feedback line spoken for `lastAttempt` (already interpolated
    /// with `kidTerm`). The banner shows this so the on-screen text matches
    /// what the child just heard, including the chosen term and rotated phrasing.
    private(set) var lastFeedbackText: String?
    /// Live mic level 0…1 for the listening meter.
    var micLevel: Float = 0
    /// Whether a session loop task is active.
    var isRunning: Bool { loopTask != nil }

    // MARK: - Configuration

    /// Max attempts at one word before we move on anyway (keeps the loop
    /// from stalling on a word the child can't yet say).
    var maxAttemptsPerWord: Int = 3
    /// Which voice the loop speaks with.
    var voiceSource: ReadAlongVoiceSource = .builtIn
    /// Built-in speaker ID when `voiceSource == .builtIn`.
    var builtInSpeakerID: String = "Cherry"
    /// Cloned-voice reference when `voiceSource == .clone`.
    var cloneReference: CloneReference?
    /// What to call the child in feedback lines (e.g. "宝贝", "闺女", "儿子").
    /// Defaults to the neutral "宝贝".
    var kidTerm: String = "宝贝"

    // MARK: - Dependencies (injected at start time)

    private var ttsEngineStore: TTSEngineStore?
    private var audioPlayer: AudioPlayerViewModel?
    private var transcriber: Qwen3ASRTranscriber?
    private var micCapture: ReadAlongMicCapture?
    /// The resolved TTS model variant the loop speaks with. Injected at
    /// `start()` time from `modelManager.generationActiveVariant(for: .custom)`
    /// — NOT `TTSModel.model(for:)`, which returns the top-level (quality/8bit)
    /// descriptor that may not be the installed variant on a memory-constrained
    /// Mac. Using the active variant matches every other coordinator.
    private var ttsModel: TTSModel?
    private let judge = ReadAlongPronunciationJudge()

    /// Identity key of the clone reference the engine has already primed
    /// during this session. We skip re-priming when this matches the current
    /// reference — priming is the slow step in the clone path (reference
    /// normalization + conditioning build), and the read-along loop speaks
    /// many lines with the *same* reference, so re-priming each line adds a
    /// visible stall before every word. Mirrors VoiceCloningCoordinator's
    /// `primedReferenceMatches` short-circuit. Only meaningful when
    /// `voiceSource == .clone`.
    private var primedCloneKey: String?

    private var loopTask: Task<Void, Never>?

    init() {}

    private static let logger = Logger(
        subsystem: "com.qwenvoice.app",
        category: "ReadAlongCoordinator"
    )

    // MARK: - Session control

    /// Starts a new read-along session for the given category. Replaces any
    /// in-flight session. The loop runs on a detached `@MainActor` task so
    /// the UI stays responsive; cancellation is cooperative via `stop()`.
    func start(
        category: ReadAlongCategory,
        ttsModel: TTSModel,
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel,
        transcriber: Qwen3ASRTranscriber,
        micCapture: ReadAlongMicCapture
    ) {
        stop()
        self.ttsModel = ttsModel
        self.ttsEngineStore = ttsEngineStore
        self.audioPlayer = audioPlayer
        self.transcriber = transcriber
        self.micCapture = micCapture
        // Reset the primed-reference tracker so a fresh session re-primes
        // the current clone reference at least once (the engine may have
        // evicted it between sessions).
        primedCloneKey = nil

        let newSession = ReadAlongSession(category: category)
        session = newSession
        currentWordIndex = 0
        lastAttempt = nil
        phase = .idle

        loopTask = Task { @MainActor [weak self] in
            await self?.runLoop()
        }
    }

    /// Stops the loop after the current step finishes and tears down mic/audio.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        micCapture?.cancel()
        audioPlayer?.stop()
        transcriber?.cancel()
        phase = .idle
    }

    /// Skips the current word (counts as not passed) and moves to the next.
    func skipCurrentWord() {
        guard isRunning, var session else { return }
        if currentWordIndex < session.trials.count {
            session.trials[currentWordIndex].passed = false
            self.session = session
        }
        advanceToNextWord()
    }

    // MARK: - Loop

    private func runLoop() async {
        guard let session else { return }

        for index in currentWordIndex..<session.trials.count {
            if Task.isCancelled { return }
            currentWordIndex = index
            let word = session.trials[index].word

            // Attempt loop: repeat the word until passed or max attempts.
            var attemptsAtThisWord = 0
            var passed = false
            while !passed, attemptsAtThisWord < maxAttemptsPerWord {
                if Task.isCancelled { return }
                attemptsAtThisWord += 1

                // 1. Speak the target word.
                guard await speakTarget(word.text) else { return }

                // 2. Listen for the child's repetition.
                guard let samples = await listen() else { return }

                // 3. Recognize.
                phase = .recognizing
                guard let recognized = await recognize(samples: samples) else {
                    // ASR failed — record an empty attempt and let the judge retry.
                    let attempt = ReadAlongAttempt(
                        recognizedText: "",
                        score: 0,
                        verdict: .retry
                    )
                    recordAttempt(attempt, forWordAt: index)
                    continue
                }

                // 4. Judge.
                let result = judge.judge(target: word.text, recognized: recognized)
                let attempt = ReadAlongAttempt(
                    recognizedText: recognized,
                    score: result.score,
                    verdict: result.verdict
                )
                recordAttempt(attempt, forWordAt: index)
                lastAttempt = attempt

                // 5. Speak feedback.
                guard await speakFeedback(for: result.verdict, attemptIndex: attemptsAtThisWord - 1) else { return }

                passed = result.verdict == .pass
            }

            // Mark the trial's pass/final state.
            if var session = self.session {
                session.trials[index].passed = passed
                session.trials[index].bestScore = session.trials[index]
                    .attempts.map(\.score).max() ?? 0
                self.session = session
            }
        }

        // All words done.
        if var session = self.session {
            session.completedAt = Date()
            self.session = session
        }
        phase = .sessionComplete
        loopTask = nil
    }

    // MARK: - Step 1: Speak the target word

    private func speakTarget(_ text: String) async -> Bool {
        guard let ttsEngineStore, let audioPlayer else { return false }
        phase = .speakingTarget

        guard let request = makeRequest(text: text) else {
            phase = .failed("无法生成语音：请先选择声音。")
            return false
        }

        // For clone voices, the engine must pre-process the reference clip
        // into clone conditioning before it can generate. Built-in voices
        // skip this — `.custom` payload has no reference to prime. We only
        // prime when the reference changed since the last prime (tracked in
        // `primedCloneKey`): the read-along loop speaks many lines with the
        // *same* reference, and re-priming each line is the slow step
        // (reference normalization + conditioning build) that stalls the
        // loop before every word. Mirrors VoiceCloningCoordinator's
        // `primedReferenceMatches` short-circuit.
        guard await primeCloneReferenceIfNeeded(modelID: request.modelID) else { return false }

        // Ensure the TTS model is loaded before generating. The sidebar
        // warmup coordinator usually handles this, but the read-along loop
        // can be the first generation after app launch, so be explicit.
        await ttsEngineStore.ensureModelLoadedIfNeeded(id: request.modelID)

        let audioPath: String
        do {
            let result = try await ttsEngineStore.generate(request)
            audioPath = result.audioPath
        } catch is CancellationError {
            return false
        } catch {
            Self.logger.error("readAlong speakTarget FAILED: type=\(String(describing: type(of: error)), privacy: .public) desc=\(error.localizedDescription, privacy: .public)")
            phase = .failed("生成语音失败：\(error.localizedDescription)")
            return false
        }

        if Task.isCancelled { return false }

        // Play the generated file and wait for completion.
        audioPlayer.playFile(audioPath, title: text, isAutoplay: true)
        phase = .playingTarget
        await waitForPlaybackCompletion()

        return !Task.isCancelled
    }

    // MARK: - Step 2: Listen (mic capture)

    private func listen() async -> [Float]? {
        guard let micCapture else { return nil }
        phase = .listening
        micLevel = 0

        do {
            try await micCapture.start()
        } catch is CancellationError {
            return nil
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }

        // Wait for the capture to auto-stop on silence (phase → .finished).
        await waitForMicCaptureCompletion()

        // Mirror the live level into our published property while waiting.
        // (The capture sets phase = .finished when done; we poll the level
        // opportunistically in the wait loop below.)
        let samples = micCapture.samples
        micLevel = 0
        return samples
    }

    // MARK: - Step 3: Recognize

    private func recognize(samples: [Float]) async -> String? {
        guard let transcriber else { return nil }
        guard !samples.isEmpty else { return nil }

        // Write the captured samples to a temp WAV so the transcriber (which
        // takes a file URL and resamples internally) can read them.
        guard let wavURL = writeSamplesToTempWAV(samples) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        return await transcriber.transcribe(audioURL: wavURL, language: "Chinese")
    }

    // MARK: - Step 5: Speak feedback

    private func speakFeedback(for verdict: ReadAlongVerdict, attemptIndex: Int) async -> Bool {
        guard let ttsEngineStore, let audioPlayer else { return false }
        phase = .speakingFeedback

        let feedbackText = verdict.feedbackLine(forKidTerm: kidTerm, attemptIndex: attemptIndex)
        lastFeedbackText = feedbackText
        guard let request = makeRequest(text: feedbackText) else {
            // If we can't build a request, just advance without feedback audio.
            return true
        }

        await ttsEngineStore.ensureModelLoadedIfNeeded(id: request.modelID)

        // Clone voices reuse the same reference as the target line. The
        // target step already primed it (and cached the key), so this is a
        // no-op unless the reference changed or the engine evicted it under
        // memory pressure. Feedback failing shouldn't kill the loop, so we
        // best-effort prime and let generation surface its own error.
        await primeCloneReferenceIfNeeded(modelID: request.modelID)

        let audioPath: String
        do {
            let result = try await ttsEngineStore.generate(request)
            audioPath = result.audioPath
        } catch is CancellationError {
            return false
        } catch {
            // Feedback TTS failing shouldn't kill the loop — skip the audio.
            return true
        }

        if Task.isCancelled { return false }

        audioPlayer.playFile(audioPath, title: feedbackText, isAutoplay: true)
        phase = .playingFeedback
        await waitForPlaybackCompletion()

        return !Task.isCancelled
    }

    // MARK: - Clone priming

    /// Primes the engine's clone conditioning for the current reference, but
    /// only when the reference hasn't already been primed in this session.
    ///
    /// Priming normalizes the reference clip and builds the voice-clone
    /// conditioning the model speaks with — it's the slow step in the clone
    /// path and the main reason clone read-along felt slower than built-in.
    /// The read-along loop speaks many lines with one reference, so we prime
    /// once on the first line and skip on the rest. We also honor the
    /// engine's own published `clonePreparationState` as a second source of
    /// truth (it can evict under memory pressure), matching
    /// VoiceCloningCoordinator's `primedReferenceMatches` check.
    ///
    /// Returns `false` only on a hard priming failure that should stop the
    /// loop; `true` otherwise (including built-in voices, which don't prime).
    private func primeCloneReferenceIfNeeded(modelID: String) async -> Bool {
        guard voiceSource == .clone, let cloneReference,
              let ttsEngineStore else { return true }

        let key = GenerationSemantics.clonePreparationKey(
            modelID: modelID,
            reference: cloneReference
        )

        // Already primed for this reference in this session — skip the XPC
        // round-trip entirely. The engine snapshot is a second check: if it
        // reports primed for the same key, the conditioning is still resident
        // even if our local flag was reset.
        let storePrimed = ttsEngineStore.clonePreparationState.isPrimed
            && ttsEngineStore.clonePreparationState.key == key
        if primedCloneKey == key || storePrimed {
            primedCloneKey = key
            Self.logger.debug("readAlong clone prime SKIPPED (cached) key=\(key, privacy: .public)")
            return true
        }

        Self.logger.debug("readAlong clone prime RUNNING (cold) key=\(key, privacy: .public)")
        do {
            try await ttsEngineStore.ensureCloneReferencePrimed(
                modelID: modelID,
                reference: cloneReference
            )
            primedCloneKey = key
            return true
        } catch is CancellationError {
            return false
        } catch {
            Self.logger.error("readAlong clone prime FAILED: \(error.localizedDescription, privacy: .public)")
            phase = .failed("准备克隆声音失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Request construction

    /// Builds a `GenerationRequest` for a short read-along line.
    ///
    /// Uses `shouldStream: false` deliberately. The read-along loop plays each
    /// line itself via `audioPlayer.playFile` after generation completes, so it
    /// must NOT also trigger the streaming-preview auto-play path (which
    /// listens for chunk events and would double-play every line). Streaming
    /// is for the interactive generation tabs where the user watches a live
    /// waveform; the read-along loop is a fire-and-forget TTS step.
    private func makeRequest(text: String) -> GenerationRequest? {
        guard let model = ttsModel else {
            Self.logger.error("readAlong makeRequest: ttsModel is nil — start() was called without resolving an active variant")
            return nil
        }
        // The Qwen3 custom-voice model rejects very short prompts ("红色" →
        // 9 chat tokens) with "requires a longer tokenized prompt". Read-along
        // words are deliberately short, so wrap them in a carrier sentence the
        // model accepts. The spoken audio still centers on the target word —
        // the carrier phrasing is natural for a child-facing read-along.
        let spokenText = text.count <= 6 ? "请跟我读：\(text)。" : text
        let outputPath = makeOutputPath(subfolder: model.outputSubfolder, text: text)

        let payload: GenerationRequest.Payload
        switch voiceSource {
        case .builtIn:
            payload = .custom(speakerID: builtInSpeakerID, deliveryStyle: nil)
        case .clone:
            guard let cloneReference else { return nil }
            payload = .clone(reference: cloneReference)
        }

        return GenerationRequest(
            modelID: model.id,
            text: spokenText,
            outputPath: outputPath,
            shouldStream: false,
            streamingTitle: String(spokenText.prefix(40)),
            languageHint: Qwen3SupportedLanguage.chinese.rawValue,
            payload: payload,
            generationID: UUID(),
            variation: GenerationVariationPreference.requestValue()
        )
    }

    // MARK: - Waiting helpers

    /// Polls `audioPlayer.isPlaying` until playback finishes or the task is
    /// cancelled. The `AVAudioPlayerDelegate` flips `isPlaying` to `false`
    /// on completion; we poll on a short cadence rather than plumbing a
    /// continuation so the coordinator stays self-contained and cancellable.
    private func waitForPlaybackCompletion() async {
        guard let audioPlayer else { return }
        // Give playback a moment to flip isPlaying to true (playFile is async-ish).
        for _ in 0..<20 where !audioPlayer.isPlaying {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        // Now wait for it to finish.
        while audioPlayer.isPlaying, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    /// Waits for `micCapture` to reach `.finished` (auto-stop on silence)
    /// or the hard `maxCaptureDuration`. Pumps `micLevel` for the meter
    /// while waiting.
    private func waitForMicCaptureCompletion() async {
        guard let micCapture else { return }
        while micCapture.phase != .finished, !Task.isCancelled {
            micLevel = micCapture.currentLevel
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        micLevel = 0
    }

    // MARK: - WAV writing

    /// Writes 16 kHz mono Float32 samples to a temp `.wav` file the ASR
    /// transcriber can read. Returns the file URL or `nil` on failure.
    private func writeSamplesToTempWAV(_ samples: [Float]) -> URL? {
        let sampleRate: Double = 16000
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        let frameCount = AVAudioFrameCount(samples.count)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: Int(frameCount))
        }

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("readalong_\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Session bookkeeping

    private func recordAttempt(_ attempt: ReadAlongAttempt, forWordAt index: Int) {
        guard var session else { return }
        guard index < session.trials.count else { return }
        session.trials[index].attempts.append(attempt)
        if attempt.score > session.trials[index].bestScore {
            session.trials[index].bestScore = attempt.score
        }
        self.session = session
    }

    private func advanceToNextWord() {
        let next = currentWordIndex + 1
        if var session, next < session.trials.count {
            currentWordIndex = next
            self.session = session
        }
    }
}
