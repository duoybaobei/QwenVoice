import Foundation
@preconcurrency import MLXAudioCore

/// One durable telemetry row for a single generation, written by one layer.
///
/// Every layer (engine / engine-service / app) emits its own
/// record keyed by the same `generationID` (threaded app → engine, see
/// `NativeEngineRuntime`), so the per-layer JSONL streams join cleanly into the
/// unified `generations-merged.jsonl` (`layer == "merged"`).
///
/// Naming note: deliberately avoids the `Probe`/`Benchmark` tokens banned by
/// `scripts/check_project_inputs.sh`.
public struct GenerationTelemetryRecord: Hashable, Codable, Sendable {
    public enum Layer: String, Hashable, Codable, Sendable {
        case engine
        case engineService = "engine-service"
        case app
        case merged
    }

    /// v2 added the backend-optimization payload: `derivedMetrics` (RTF, tokens/sec),
    /// `mlxMemoryByStage` (per-stage MLX GPU memory), and `chunkTimeline` (per-chunk
    /// decode substage breakdown). v3 added `modelID` + `warmState` so each row
    /// self-identifies its benchmark cell (model variant × cold/warm). v4 added
    /// `audioQC` (reference-free output-quality verdict + defect flags). v5 added
    /// high-resolution `mach_absolute_time` nanoseconds (`clockSource`, stage-mark
    /// `tNS`/`sequence`, sample `tNS`/`actualElapsedNS`, chunk `arrivalNS`). All
    /// optional, so older rows still decode.
    public static let currentSchemaVersion = 5

    public let clockSource: String?

    public let schemaVersion: Int
    public let generationID: String
    public let layer: Layer
    public let processName: String
    public let processIdentifier: Int32
    public let recordedAt: String
    public let mode: String?
    /// The resolved model id for this generation (variant-specific — distinguishes
    /// Speed 4-bit vs Quality 8-bit). Lets a benchmark attribute the row to its cell.
    public let modelID: String?
    /// Whether the model was loaded by THIS generation (`.cold`) or reused from a
    /// prior one (`.warm`). The benchmark's cold/warm axis.
    public let warmState: EngineWarmState?
    public let usedStreaming: Bool?
    public let finishReason: String?
    public let stageMarks: [NativeTelemetryStageMark]
    /// Raw integer timings. For the engine layer this carries the full MLX decode
    /// breakdown (talker forward, code predictor, decoder, stream-step eval/EOS,
    /// token-loop total, unattributed) + counters (generated codes, decoder calls),
    /// re-read from the model AFTER the decode loop so the hot-loop totals are final.
    public let timingsMS: [String: Int]
    public let counters: [String: Int]
    public let notes: [String: String]
    public let summary: TelemetrySummary?
    public let thermalState: ThermalStateSnapshot?
    /// Headline derived throughput KPIs (engine layer): `audioSeconds`,
    /// `decodeWallSeconds`, `audioSecondsPerWallSecond` (>1 = faster than realtime),
    /// `tokensPerSecond`, `generatedTokenCount`. nil when not computed.
    public let derivedMetrics: [String: Double]?
    /// Per-stage MLX GPU memory (active/cache/peak MB) — e.g. before_stream,
    /// first_chunk, after_stream, after_generation_trim. nil when not collected.
    public let mlxMemoryByStage: [String: NativeMLXMemorySnapshot]?
    /// Per-chunk decode substage breakdown for streaming runs (cold-start vs
    /// steady-state, stall localization). nil for non-streaming / when gated off.
    public let chunkTimeline: [GenerationChunkTelemetry]?
    /// Reference-free audio-quality verdict for this take (defect detection on the
    /// final PCM — NaN/clip/click/dropout/level). The objective regression tripwire
    /// for backend changes; nil when not computed. Perceptual quality still needs the
    /// listening pass — this catches gross defects, not subtle "sounds worse".
    public let audioQC: AudioQCReport?

    public init(
        generationID: String,
        layer: Layer,
        recordedAt: String,
        mode: String? = nil,
        modelID: String? = nil,
        warmState: EngineWarmState? = nil,
        usedStreaming: Bool? = nil,
        finishReason: String? = nil,
        stageMarks: [NativeTelemetryStageMark] = [],
        summary: TelemetrySummary? = nil,
        thermalState: ThermalStateSnapshot? = nil,
        timingsMS: [String: Int] = [ :],
        counters: [String: Int] = [:],
        notes: [String: String] = [:],
        derivedMetrics: [String: Double]? = nil,
        mlxMemoryByStage: [String: NativeMLXMemorySnapshot]? = nil,
        chunkTimeline: [GenerationChunkTelemetry]? = nil,
        audioQC: AudioQCReport? = nil,
        clockSource: String? = "mach_absolute_time",
        schemaVersion: Int = GenerationTelemetryRecord.currentSchemaVersion,
        processName: String = ProcessInfo.processInfo.processName,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.clockSource = clockSource
        self.schemaVersion = schemaVersion
        self.generationID = generationID
        self.layer = layer
        self.processName = processName
        self.processIdentifier = processIdentifier
        self.recordedAt = recordedAt
        self.mode = mode
        self.modelID = modelID
        self.warmState = warmState
        self.usedStreaming = usedStreaming
        self.finishReason = finishReason
        self.stageMarks = stageMarks
        self.summary = summary
        self.thermalState = thermalState
        self.timingsMS = timingsMS
        self.counters = counters
        self.notes = notes
        self.derivedMetrics = derivedMetrics
        self.mlxMemoryByStage = mlxMemoryByStage
        self.chunkTimeline = chunkTimeline
        self.audioQC = audioQC
    }
}

/// Reference-free audio-quality verdict for one generated take, derived from the
/// `PCM16StreamLimiter` per-sample pass (no stored golden, no model). The objective
/// half of the quality gate: it catches gross defects (unstable model output,
/// clipping, chunk-boundary clicks/discontinuities, mid-utterance dropouts, dead
/// output). It deliberately does NOT judge subtle perceptual quality — that's the
/// human/agent listening pass. Thresholds are conservative + tunable (see the
/// builder in `NativeStreamingSynthesisSession`).
public struct AudioQCReport: Hashable, Codable, Sendable {
    public enum Verdict: String, Hashable, Codable, Sendable {
        case pass
        case warn
        case fail
    }

    public let verdict: Verdict
    /// Human-readable defect tags that tripped (e.g. "nonfinite", "clipping",
    /// "clicks", "dropout:240ms", "near_silent"). Empty on a clean pass.
    public let flags: [String]
    /// Whole-clip RMS in dBFS (nil = total silence).
    public let rmsDBFS: Double?
    public let peak: Double
    /// Samples that exceeded unit range (true digital clipping, pre-limiter).
    public let clippedSamples: Int
    /// Samples above the limiter ceiling (hot but not hard-clipped).
    public let hotSamples: Int
    /// Non-finite (NaN/Inf) input samples scrubbed by the limiter — model instability.
    public let nonFiniteSamples: Int
    /// Slew-limited steps: sample-to-sample jumps beyond the click ceiling
    /// (chunk-boundary clicks / decoder discontinuities).
    public let clickEvents: Int
    /// Longest interior near-silent run (mid-utterance dropout), in milliseconds.
    public let longestSilenceMS: Int
    /// Absolute sample index of the first non-finite sample, or nil if none.
    public let firstNonFiniteSample: Int?
    /// Absolute sample index of the first sample outside the digital unit range,
    /// or nil if none.
    public let firstClipSample: Int?
    /// Start time of the longest interior near-silent run, in milliseconds since
    /// the start of the clip, or nil if none.
    public let longestSilenceStartMS: Int?
    public let durationSeconds: Double
    /// Optional per-chunk QC snapshots (verbose mode only). nil when not computed.
    public let chunkQC: [AudioQCChunkReport]?

    public init(
        verdict: Verdict,
        flags: [String],
        rmsDBFS: Double?,
        peak: Double,
        clippedSamples: Int,
        hotSamples: Int,
        nonFiniteSamples: Int,
        clickEvents: Int,
        longestSilenceMS: Int,
        durationSeconds: Double,
        firstNonFiniteSample: Int? = nil,
        firstClipSample: Int? = nil,
        longestSilenceStartMS: Int? = nil,
        chunkQC: [AudioQCChunkReport]? = nil
    ) {
        self.verdict = verdict
        self.flags = flags
        self.rmsDBFS = rmsDBFS
        self.peak = peak
        self.clippedSamples = clippedSamples
        self.hotSamples = hotSamples
        self.nonFiniteSamples = nonFiniteSamples
        self.clickEvents = clickEvents
        self.longestSilenceMS = longestSilenceMS
        self.durationSeconds = durationSeconds
        self.firstNonFiniteSample = firstNonFiniteSample
        self.firstClipSample = firstClipSample
        self.longestSilenceStartMS = longestSilenceStartMS
        self.chunkQC = chunkQC
    }

    /// Backward-compatible decoding: older JSONL rows written before Phase 4
    /// lack the localization fields and per-chunk QC. Defaults keep them decodeable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.verdict = try container.decode(Verdict.self, forKey: .verdict)
        self.flags = try container.decode([String].self, forKey: .flags)
        self.rmsDBFS = try container.decodeIfPresent(Double.self, forKey: .rmsDBFS)
        self.peak = try container.decode(Double.self, forKey: .peak)
        self.clippedSamples = try container.decode(Int.self, forKey: .clippedSamples)
        self.hotSamples = try container.decode(Int.self, forKey: .hotSamples)
        self.nonFiniteSamples = try container.decode(Int.self, forKey: .nonFiniteSamples)
        self.clickEvents = try container.decode(Int.self, forKey: .clickEvents)
        self.longestSilenceMS = try container.decode(Int.self, forKey: .longestSilenceMS)
        self.durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        self.firstNonFiniteSample = try container.decodeIfPresent(Int.self, forKey: .firstNonFiniteSample)
        self.firstClipSample = try container.decodeIfPresent(Int.self, forKey: .firstClipSample)
        self.longestSilenceStartMS = try container.decodeIfPresent(Int.self, forKey: .longestSilenceStartMS)
        self.chunkQC = try container.decodeIfPresent([AudioQCChunkReport].self, forKey: .chunkQC)
    }
}

/// Reference-free audio-quality snapshot for one streaming chunk. Computed in
/// verbose mode so engineers can localize early corruption, chunk-boundary
/// clicks, or drift before the final clip is assembled. All sample indices are
/// absolute from the start of the generation.
public struct AudioQCChunkReport: Hashable, Codable, Sendable {
    public let chunkIndex: Int
    public let frameOffset: Int
    public let frameCount: Int
    public let verdict: AudioQCReport.Verdict
    public let flags: [String]
    public let rmsDBFS: Double?
    public let peak: Double
    public let clippedSamples: Int
    public let hotSamples: Int
    public let nonFiniteSamples: Int
    public let clickEvents: Int
    public let longestSilenceMS: Int
    public let firstNonFiniteSample: Int?
    public let firstClipSample: Int?
    public let longestSilenceStartMS: Int?
    public let durationSeconds: Double

    public init(
        chunkIndex: Int,
        frameOffset: Int,
        frameCount: Int,
        verdict: AudioQCReport.Verdict,
        flags: [String],
        rmsDBFS: Double?,
        peak: Double,
        clippedSamples: Int,
        hotSamples: Int,
        nonFiniteSamples: Int,
        clickEvents: Int,
        longestSilenceMS: Int,
        durationSeconds: Double,
        firstNonFiniteSample: Int? = nil,
        firstClipSample: Int? = nil,
        longestSilenceStartMS: Int? = nil
    ) {
        self.chunkIndex = chunkIndex
        self.frameOffset = frameOffset
        self.frameCount = frameCount
        self.verdict = verdict
        self.flags = flags
        self.rmsDBFS = rmsDBFS
        self.peak = peak
        self.clippedSamples = clippedSamples
        self.hotSamples = hotSamples
        self.nonFiniteSamples = nonFiniteSamples
        self.clickEvents = clickEvents
        self.longestSilenceMS = longestSilenceMS
        self.durationSeconds = durationSeconds
        self.firstNonFiniteSample = firstNonFiniteSample
        self.firstClipSample = firstClipSample
        self.longestSilenceStartMS = longestSilenceStartMS
    }
}

/// Per-chunk decode substage timing for one streaming audio chunk — a Codable,
/// persistence-safe mirror of the vendored `ChunkSubstageTimings` plus the chunk
/// index and wall-clock arrival (ms since the generation's telemetry start clock).
/// All substage values are millisecond deltas since the previous chunk boundary.
public struct GenerationChunkTelemetry: Hashable, Codable, Sendable {
    public let chunkIndex: Int
    public let arrivalMS: Int
    /// High-resolution arrival timestamp in nanoseconds since the generation's
    /// shared telemetry clock start (v5). nil for older rows.
    public let arrivalNS: UInt64?
    public let talkerForwardMS: Double
    public let codePredictorMS: Double
    public let audioDecoderMS: Double
    public let streamStepEvalMS: Double
    /// Phase 2a split of `streamStepEvalMS`: enqueued eval work wall time.
    public let streamStepEvalEnqueueMS: Double
    /// Phase 2a split of `streamStepEvalMS`: GPU drain wait time.
    public let streamStepEvalWaitMS: Double
    public let streamStepEOSReadMS: Double
    public let audioChunkEvalMS: Double
    /// Phase 2a KV-cache diagnostic snapshot at this chunk boundary.
    public let kvCacheDiagnostics: KVCacheDiagnostics?
    /// Phase 4 per-frame Mimi decoder step breakdown for this chunk.
    public let mimiDecoderBreakdownMS: MimiDecoderStepTimings?

    public init(
        chunkIndex: Int,
        arrivalMS: Int,
        arrivalNS: UInt64? = nil,
        talkerForwardMS: Double,
        codePredictorMS: Double,
        audioDecoderMS: Double,
        streamStepEvalMS: Double,
        streamStepEvalEnqueueMS: Double,
        streamStepEvalWaitMS: Double,
        streamStepEOSReadMS: Double,
        audioChunkEvalMS: Double,
        kvCacheDiagnostics: KVCacheDiagnostics? = nil,
        mimiDecoderBreakdownMS: MimiDecoderStepTimings? = nil
    ) {
        self.chunkIndex = chunkIndex
        self.arrivalMS = arrivalMS
        self.arrivalNS = arrivalNS
        self.talkerForwardMS = talkerForwardMS
        self.codePredictorMS = codePredictorMS
        self.audioDecoderMS = audioDecoderMS
        self.streamStepEvalMS = streamStepEvalMS
        self.streamStepEvalEnqueueMS = streamStepEvalEnqueueMS
        self.streamStepEvalWaitMS = streamStepEvalWaitMS
        self.streamStepEOSReadMS = streamStepEOSReadMS
        self.audioChunkEvalMS = audioChunkEvalMS
        self.kvCacheDiagnostics = kvCacheDiagnostics
        self.mimiDecoderBreakdownMS = mimiDecoderBreakdownMS
    }

    /// Backward-compatible decoding: older JSONL rows written before Phase 2a
    /// lack `streamStepEvalEnqueueMS`, `streamStepEvalWaitMS`, and
    /// `kvCacheDiagnostics`; v5 rows add `arrivalNS`; v5+ adds
    /// `mimiDecoderBreakdownMS`. Defaults keep them decodeable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.chunkIndex = try container.decode(Int.self, forKey: .chunkIndex)
        self.arrivalMS = try container.decode(Int.self, forKey: .arrivalMS)
        self.arrivalNS = try container.decodeIfPresent(UInt64.self, forKey: .arrivalNS)
        self.talkerForwardMS = try container.decode(Double.self, forKey: .talkerForwardMS)
        self.codePredictorMS = try container.decode(Double.self, forKey: .codePredictorMS)
        self.audioDecoderMS = try container.decode(Double.self, forKey: .audioDecoderMS)
        self.streamStepEvalMS = try container.decode(Double.self, forKey: .streamStepEvalMS)
        self.streamStepEvalEnqueueMS = try container.decodeIfPresent(Double.self, forKey: .streamStepEvalEnqueueMS) ?? 0
        self.streamStepEvalWaitMS = try container.decodeIfPresent(Double.self, forKey: .streamStepEvalWaitMS) ?? 0
        self.streamStepEOSReadMS = try container.decode(Double.self, forKey: .streamStepEOSReadMS)
        self.audioChunkEvalMS = try container.decode(Double.self, forKey: .audioChunkEvalMS)
        self.kvCacheDiagnostics = try container.decodeIfPresent(KVCacheDiagnostics.self, forKey: .kvCacheDiagnostics)
        self.mimiDecoderBreakdownMS = try container.decodeIfPresent(MimiDecoderStepTimings.self, forKey: .mimiDecoderBreakdownMS)
    }
}

/// The unified per-generation record produced by `GenerationTelemetryMerger`,
/// joining each layer's row under one `generationID`.
public struct MergedGenerationTelemetry: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generationID: String
    public let recordedAt: String
    public let app: GenerationTelemetryRecord?
    public let engineService: GenerationTelemetryRecord?
    public let engine: GenerationTelemetryRecord?

    public init(
        generationID: String,
        recordedAt: String,
        app: GenerationTelemetryRecord?,
        engineService: GenerationTelemetryRecord?,
        engine: GenerationTelemetryRecord?,
        schemaVersion: Int = MergedGenerationTelemetry.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.generationID = generationID
        self.recordedAt = recordedAt
        self.app = app
        self.engineService = engineService
        self.engine = engine
    }
}
