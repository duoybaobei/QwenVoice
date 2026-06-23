// swift-tools-version:6.1
import PackageDescription

// Vocello-specialized fork: Qwen3-TTS + Qwen3-ASR (2026-06-09, ASR added 2026-06-23).
// The upstream multi-model targets (STS/VAD/LID/G2P/UI/Tools and the
// non-Mimi codec families) were deleted — restorable from upstream
// (Blaizzy/mlx-audio-swift @ fcbd04d) or git history. MLXAudioSTT is restored
// in minimal form (Qwen3-ASR only) for the read-along training feature.
// MLXAudioCodecs remains as the home of the Mimi transformer/conv/quantization
// primitives the Qwen3 speech tokenizer builds on.
let package = Package(
    name: "MLXAudio",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Core foundation library
        .library(name: "MLXAudioCore", targets: ["MLXAudioCore"]),

        // Audio codec primitives (Mimi subset used by Qwen3-TTS)
        .library(name: "MLXAudioCodecs", targets: ["MLXAudioCodecs"]),

        // Text-to-Speech (Qwen3-TTS)
        .library(name: "MLXAudioTTS", targets: ["MLXAudioTTS"]),

        // Vocello addition: re-exported on-device text-LLM surface (story-text
        // generation). Single-sources the mlx-swift-lm pin in this package.
        .library(name: "MLXAudioLLM", targets: ["MLXAudioLLM"]),

        // Vocello addition: Speech-to-Text (Qwen3-ASR) for the read-along
        // training feature. Minimal upstream restoration: Qwen3-ASR model only.
        .library(name: "MLXAudioSTT", targets: ["MLXAudioSTT"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.30.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.30.6"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.1.9")
    ],
    targets: [
        // MARK: - MLXAudioCore
        .target(
            name: "MLXAudioCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/MLXAudioCore",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"], .when(configuration: .debug))
            ]
        ),

        // MARK: - MLXAudioCodecs
        .target(
            name: "MLXAudioCodecs",
            dependencies: [
                "MLXAudioCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/MLXAudioCodecs"
        ),

        // MARK: - MLXAudioTTS
        .target(
            name: "MLXAudioTTS",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioCodecs",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/MLXAudioTTS"
        ),

        // MARK: - MLXAudioLLM (Vocello addition)
        // Thin @_exported re-export of the upstream text-LLM modules so the app
        // can drive on-device story-text generation. No local logic lives here.
        .target(
            name: "MLXAudioLLM",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/MLXAudioLLM"
        ),

        // MARK: - MLXAudioSTT (Vocello addition)
        // Minimal restoration of upstream Speech-to-Text: Qwen3-ASR model only.
        // Used by the read-along training feature for on-device recognition.
        // Dependencies match Qwen3ASR.swift imports — MLXAudioCodecs is NOT
        // needed (Qwen3-ASR does not use the Mimi codec).
        .target(
            name: "MLXAudioSTT",
            dependencies: [
                "MLXAudioCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/MLXAudioSTT"
        ),
    ]
)
