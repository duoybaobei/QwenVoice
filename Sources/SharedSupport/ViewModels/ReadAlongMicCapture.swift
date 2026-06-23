import AVFoundation
import Foundation
import Observation

/// Real-time 16 kHz mono microphone capture for the read-along loop, with a
/// lightweight silence detector (VAD-lite) that auto-stops when the child
/// finishes speaking.
///
/// The capture engine is a non-`@MainActor` `AVAudioEngine` tap (audio thread
/// writes, main thread reads), producing 16 kHz Float32 samples via
/// `AVAudioConverter`. A sliding-window RMS energy detector tracks speech
/// state: when energy rises above `speechThreshold` we mark speech started;
/// when it stays below `silenceThreshold` for `silenceDuration` seconds after
/// speech started, we auto-stop and deliver the captured samples.
///
/// For development / UI testing on Macs without a microphone, the
/// `QWENVOICE_FAKE_MIC_WAV` env var (same convention as
/// `ReferenceClipRecorder`) points at a WAV file that is fed through as if it
/// were live mic input.
@MainActor
@Observable
final class ReadAlongMicCapture {

    /// Coarse state for the capture UI.
    enum Phase: Equatable, Sendable {
        case idle
        /// Mic is open, waiting for the child to start speaking.
        case listening
        /// Speech has been detected; recording until silence.
        case capturing
        /// Capture finished (auto-stop or manual). Samples are available.
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var isRecording: Bool = false
    /// Live input level 0…1 for the mic meter.
    private(set) var currentLevel: Float = 0
    /// Elapsed capture time in seconds.
    private(set) var elapsed: TimeInterval = 0

    /// The captured 16 kHz mono samples from the last `start()` → `stop()`
    /// cycle. `nil` if capture produced nothing.
    private(set) var samples: [Float]?

    /// Whether the last capture ended by auto silence-detection (vs manual
    /// stop). Drives a subtle "auto-stopped" UI hint.
    private(set) var endedBySilenceDetection: Bool = false

    // MARK: - VAD thresholds (tunable, lenient for kids)

    /// RMS above this → speech is happening. Calibrated for a normal speaking
    /// voice at arm's length from a MacBook mic.
    var speechThreshold: Float = 0.015
    /// RMS below this → silence. Must be < speechThreshold.
    var silenceThreshold: Float = 0.008
    /// Seconds of continuous silence (after speech started) before auto-stop.
    var silenceDuration: TimeInterval = 1.2
    /// Hard cap on a single capture to avoid runaway recordings.
    var maxCaptureDuration: TimeInterval = 10.0

    private let engine = AudioCaptureEngine()
    private var monitorTimer: Timer?
    private var startTime: Date?
    private var speechStarted = false
    private var silenceStart: Date?

    init() {}

    // MARK: - Capture control

    /// Opens the mic and begins capturing. Auto-stops on silence detection or
    /// `maxCaptureDuration`. Call `stop()` to end early; `cancel()` to abort
    /// and discard.
    func start() async throws {
        guard !isRecording else { return }

        // Reset state
        samples = nil
        endedBySilenceDetection = false
        speechStarted = false
        silenceStart = nil
        currentLevel = 0
        elapsed = 0
        startTime = Date()

        try await requestMicrophoneAccess()
        try engine.start()
        engine.reset()

        isRecording = true
        phase = .listening

        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    /// Ends capture and returns the accumulated samples. Safe to call when not
    /// recording (returns `nil`).
    @discardableResult
    func stop() -> [Float]? {
        guard isRecording else { return nil }
        endCapture(autoStopped: false)
        return samples
    }

    /// Aborts capture and discards samples.
    func cancel() {
        guard isRecording else { return }
        endCapture(autoStopped: false, discard: true)
    }

    // MARK: - Internals

    private func tick() {
        guard isRecording, let startTime else { return }

        let level = engine.currentLevel
        currentLevel = min(level * 5, 1.0) // scale for UI visibility
        elapsed = Date().timeIntervalSince(startTime)

        // VAD state machine
        if !speechStarted {
            if level >= speechThreshold {
                speechStarted = true
                silenceStart = nil
                phase = .capturing
            }
        } else {
            if level < silenceThreshold {
                if silenceStart == nil {
                    silenceStart = Date()
                }
                if let silenceStart,
                   Date().timeIntervalSince(silenceStart) >= silenceDuration {
                    // Sustained silence after speech → auto-stop.
                    endCapture(autoStopped: true)
                    return
                }
            } else {
                // Voice came back → reset silence timer.
                silenceStart = nil
            }
        }

        // Hard cap.
        if elapsed >= maxCaptureDuration {
            endCapture(autoStopped: true)
        }
    }

    private func endCapture(autoStopped: Bool, discard: Bool = false) {
        monitorTimer?.invalidate()
        monitorTimer = nil
        startTime = nil

        if !discard, let (slice, _) = engine.getAudio(from: 0) {
            samples = slice
        } else {
            samples = nil
        }
        endedBySilenceDetection = autoStopped

        engine.stop()
        engine.reset()

        isRecording = false
        currentLevel = 0
        phase = .finished
    }

    // MARK: - Microphone permission

    private func requestMicrophoneAccess() async throws {
        #if os(macOS)
        // Honor the virtual-mic dev override — no TCC prompt needed.
        guard Self.virtualMicrophoneURL == nil else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw MicError.permissionDenied
            }
        case .denied, .restricted:
            throw MicError.permissionDenied
        @unknown default:
            break
        }
        #endif
    }

    // MARK: - Errors

    enum MicError: LocalizedError {
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "需要麦克风权限才能录音。请在「系统设置 > 隐私与安全 > 麦克风」中授权。"
            }
        }
    }

    // MARK: - Virtual microphone (dev override)

    /// Development-only virtual microphone (same convention as
    /// `ReferenceClipRecorder`): when `QWENVOICE_FAKE_MIC_WAV` points at a
    /// readable audio file, the capture is simulated so the read-along flow
    /// runs end-to-end with no input hardware and no TCC prompt. Inert in
    /// production.
    static var virtualMicrophoneURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["QWENVOICE_FAKE_MIC_WAV"],
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Audio Capture Engine

/// Non-`@MainActor` engine that captures 16 kHz mono Float32 via
/// `AVAudioEngine.installTap`. Thread-safe: the tap callback writes on the
/// audio thread, reads happen on the main thread.
private final class AudioCaptureEngine: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var _currentLevel: Float = 0

    let targetSampleRate: Double = 16000

    var currentLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return _currentLevel
    }

    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        let sampleRate = targetSampleRate
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "ReadAlongMic", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建目标音频格式"])
        }

        let converter: AVAudioConverter?
        if nativeFormat.sampleRate != sampleRate || nativeFormat.channelCount != 1 {
            converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
        } else {
            converter = nil
        }

        let nativeSampleRate = nativeFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) {
            [weak self] buffer, _ in
            guard let self else { return }

            let floats: [Float]
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * sampleRate / nativeSampleRate
                )
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: frameCapacity
                ) else { return }

                var error: NSError?
                var consumed = false
                converter.convert(to: converted, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error != nil { return }

                floats = Array(UnsafeBufferPointer(
                    start: converted.floatChannelData![0],
                    count: Int(converted.frameLength)
                ))
            } else {
                floats = Array(UnsafeBufferPointer(
                    start: buffer.floatChannelData![0],
                    count: Int(buffer.frameLength)
                ))
            }

            // RMS level for VAD + UI meter.
            let rms = sqrt(floats.reduce(0) { $0 + $1 * $1 } / max(Float(floats.count), 1))

            self.lock.lock()
            self.samples.append(contentsOf: floats)
            self._currentLevel = rms
            self.lock.unlock()
        }

        try engine.start()
        self.engine = engine
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Get audio from a sample offset to the end.
    func getAudio(from startSample: Int) -> ([Float], Int)? {
        lock.lock()
        let count = samples.count
        guard startSample < count else {
            lock.unlock()
            return nil
        }
        let slice = Array(samples[startSample...])
        lock.unlock()

        guard !slice.isEmpty else { return nil }
        return (slice, count)
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        _currentLevel = 0
        lock.unlock()
    }
}
