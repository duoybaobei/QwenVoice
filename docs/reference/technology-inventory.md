# Vocello Technology Inventory

> **Living document.** This file tracks the core technologies, components, APIs, and dependencies used by Vocello/QwenVoice. Update it whenever dependencies, targets, entitlements, supported models, or major architecture change. When this doc disagrees with the code, the code wins — fix this file.
>
> Last reviewed: 2026-06-15.

---

## 1. Project Overview & Metadata

| Item | Detail |
|---|---|
| **Product** | Vocello (formerly QwenVoice) — local-first, private text-to-speech studio for Apple Silicon Macs and iPhones. |
| **Current release** | Vocello 2.1.0 (`v2.1.0` tag). |
| **Platforms** | macOS 26.0+, iOS 26.0+, Apple Silicon (`arm64`) only. |
| **Primary languages** | Swift 6 (app + engine), Python 3 (benchmark/diagnostic scripts), React/Vite (marketing website). |
| **Project generator** | XcodeGen 2.45.4 (`project.yml` is the single source of truth; `QwenVoice.xcodeproj` is generated). |
| **Build system** | `xcodebuild` + SwiftPM; `scripts/build.sh` (dev `-Onone`) and `scripts/release.sh` (optimized DMG). |
| **Repository** | `https://github.com/PowerBeef/QwenVoice` |
| **Website** | `https://vocello.vercel.app` |

---

## 2. Core TTS / ML Backend

| Technology | Role |
|---|---|
| **Qwen3-TTS** | Generative TTS model family used for all synthesis (Custom Voice, Voice Design, Voice Cloning). |
| **MLX (Apple)** | On-device ML compute framework for Apple Silicon; unified memory, lazy evaluation, Metal backend. |
| **mlx-swift** | Swift bindings for MLX. |
| **mlx-swift-lm** | Swift language-model utilities used transitively by the vendored audio stack. |
| **mlx-audio-swift** | Vendored under `third_party_patches/mlx-audio-swift/`. Provides `MLXAudioCore`, `MLXAudioCodecs`, `MLXAudioTTS` for Qwen3-TTS loading, tokenization, and decoding. Snapshot based on upstream `v0.1.2` / commit `fcbd04d`, specialized to Qwen3-TTS only. See [`mlx-audio-swift-patching.md`](mlx-audio-swift-patching.md). |
| **Mimi codec** | Neural audio codec used by Qwen3-TTS; only the Transformer/Conv/Quantization/Seanet primitives are retained in the vendored snapshot. |
| **Model variants** | **Speed** (4-bit, macOS + iOS) and **Quality** (8-bit, macOS only). |

### Shipped Models (`Sources/Resources/qwenvoice_contract.json`)

| Model ID | Mode | Speed repo | Quality repo |
|---|---|---|---|
| `pro_custom` | Custom Voice | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit` | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` |
| `pro_design` | Voice Design | `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit` | `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` |
| `pro_clone` | Voice Cloning | `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit` | `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit` |

### Built-in Speakers

`aiden`, `ryan`, `vivian`, `serena`, `uncle_fu`, `dylan`, `eric`, `ono_anna`, `sohee` (English, Chinese, Japanese, Korean native voices).

### Delivery (Tone/Emotion) Presets

`neutral`, `happy`, `sad`, `angry`, `fearful`, `surprised`, `whisper`, `dramatic`, `calm`, `excited`, `narrator`, `news` — each at `subtle`/`normal`/`strong` intensity (`Sources/QwenVoiceCore/EmotionPreset.swift`).

---

## 3. Swift Package Manager Dependencies

Declared in `project.yml`; exact versions pinned in `QwenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

| Package | Version | Purpose |
|---|---|---|
| **mlx-swift** | `0.30.6` | MLX runtime bindings. |
| **mlx-swift-lm** | `2.30.6` | LM utilities (transitive via vendored `mlx-audio-swift`). |
| **GRDB.swift** | `7.10.0` | SQLite wrapper for local `history.sqlite` on macOS. |
| **SwiftHuggingFace** | `0.9.0` | Hugging Face model download / hub access. |
| **swift-transformers** | `1.1.9` | Tokenizer utilities (transitive). |
| **swift-jinja** | `2.3.5` | Chat/template formatting (transitive). |
| **swift-nio** | `2.98.0` | Networking primitives (transitive, via SwiftHuggingFace). |
| **swift-crypto** | `4.4.0` | Hashing (transitive). |
| **swift-collections** | `1.4.1` | Deque/OrderedSet (transitive). |
| **swift-atomics** | `1.3.0` | Atomic operations (transitive). |
| **swift-numerics** | `1.1.1` | Numerics helpers (transitive). |
| **swift-system** | `1.6.4` | System types (transitive). |
| **swift-asn1** | `1.7.0` | ASN.1 parsing (transitive). |
| **EventSource** | `1.4.1` | Server-sent events (transitive). |
| **yyjson** | `0.12.0` | High-performance JSON parser (transitive). |

---

## 4. App Targets & Module Architecture

| Target | Type | Platform | Responsibility |
|---|---|---|---|
| `QwenVoice` | macOS app | macOS | Main SwiftUI app surface (`Vocello.app`). |
| `VocelloiOS` | iOS app | iOS | iOS SwiftUI app surface; engine runs in-process. |
| `QwenVoiceCore` | Static framework | macOS + iOS | Shared engine semantics: `TTSEngine`, generation modes, telemetry, error types. |
| `QwenVoiceBackendCore` | Static framework | macOS + iOS | Low-level MLX/audio primitives, model loading, synthesis, codecs. |
| `QwenVoiceEngineSupport` | Static framework | macOS | Runtime helpers: memory policy, streaming, telemetry aggregation. |
| `QwenVoiceNative` | Static framework | macOS | macOS app-facing engine proxy/store bridging the XPC service. |
| `QwenVoiceEngineService` | XPC service | macOS | Out-of-process engine host for crash isolation and memory containment. |
| `SharedSupport` | Source folder | macOS + iOS | Dual-platform UI share point: player, transcriber, recorder, language detector, telemetry helpers. |
| `VocelloCLI` | CLI tool | macOS | Headless `vocello` binary. |
| `VocelloMacUITests` | XCUITest bundle | macOS | Automated macOS UI smoke. |
| `VocelloiOSUITests` | XCUITest bundle | iOS | Automated iOS UI-flow smoke. |

---

## 5. Apple Frameworks & APIs

Most-frequent imports across `Sources/**/*.swift`:

| Framework | Usage |
|---|---|
| **Foundation** | Base types, JSON, files, processes, networking. |
| **SwiftUI** | macOS + iOS app UI. |
| **UIKit** | iOS-specific UI components. |
| **AppKit** | macOS-specific UI components. |
| **AVFoundation** | Audio playback, recording, PCM/WAV handling. |
| **Combine** | Reactive data flow. |
| **Observation** | SwiftUI `@Observable` state. |
| **Speech** | On-device speech recognition for voice-cloning transcripts. |
| **NaturalLanguage** | Language detection. |
| **CryptoKit** | SHA-256 for download integrity. |
| **Metal / MLX** | GPU compute via MLX. |
| **CoreMedia** | Media timing/types. |
| **Accelerate** | DSP acceleration. |
| **UniformTypeIdentifiers** | File type handling. |
| **OSLog / os** | Logging and signposts. |
| **XPC / `NSXPCConnection`** | macOS engine-service IPC. |
| **ExtensionKit** | (Dead code removed) previously used for iOS extension. |

### Key Apple Runtime APIs

- `os_proc_available_memory()` — iOS process headroom measurement.
- `devicectl` / CoreDevice — iOS on-device install/launch/test.
- `xcodebuild test` with on-device destination — iOS XCUITest.
- `codesign`, `notarytool`, `stapler` — macOS signing + notarization.
- TCC (Transparency, Consent & Control) — mic/speech permissions.

---

## 6. Audio / Media Stack

| Component | Technology |
|---|---|
| **Input audio capture** | `AVAudioEngine` / `AVAudioRecorder` for clone reference clips. |
| **Output audio** | 24 kHz Int16 PCM WAV; `AVAudioFile` / `AVAudioPlayer` for playback. |
| **Streaming preview** | Chunked PCM written during generation; `AVAudioEngine` consumer on iOS. |
| **Audio QC gate** | Custom `PCM16StreamLimiter`/defect detector: clipping, dropouts, clicks, near-silence, nonfinite samples. |
| **Prosody analysis** | Numpy-only Python scripts (`analyze_prosody.py`, `prosody_quality_gate.py`, `bench_delivery_prosody.py`). See [`prosody-qa-research.md`](prosody-qa-research.md). |
| **Codec** | Mimi speech tokenizer/codec (via vendored `MLXAudioCodecs`). |

---

## 7. Storage / Persistence

| Component | Technology |
|---|---|
| **macOS app data** | `~/Library/Application Support/QwenVoice-Local/` (release) or `QwenVoice-Local-Debug/` (debug). |
| **iOS app data** | App Group `group.com.patricedery.vocello.shared`. |
| **History database** | SQLite via **GRDB** (`history.sqlite`). |
| **Settings/preferences** | `UserDefaults`; per-mode model-quality choices. |
| **Download staging** | Custom `.qwenvoice-downloads/` + `swift-huggingface` download layer. |
| **Saved voices / outputs** | File-system folders under `voices/` and `outputs/`. |

See [`privacy-storage.md`](privacy-storage.md) for full detail.

---

## 8. Networking / External Services

| Service | Usage |
|---|---|
| **Hugging Face Hub** | Model package downloads only (`mlx-community/*` repos). No cloud inference. |
| **Hugging Face `swift-huggingface`** | Download manager / hub client. |
| **Vercel** | Marketing website hosting (`vocello.vercel.app`). |
| **GitHub Releases** | macOS DMG distribution. |
| **App Store Connect** | iOS TestFlight/App Store (intended; not yet active in CI), notarization API. |

**Privacy stance:** no telemetry, no cloud generation, no account. `Sources/PrivacyInfo.xcprivacy` declares no tracking and no collected data types.

---

## 9. Python Developer Tooling

Located in `scripts/`. Only third-party Python dependency is **numpy**.

| Script | Purpose |
|---|---|
| `analyze_delivery.py` | Reference-free delivery acoustic analyzer (F0, rate, duration). |
| `analyze_prosody.py` | Numpy-only prosody analyzer (F0 dynamics, rate variability, pauses, energy). |
| `prosody_quality_gate.py` | Flags monotone/rushed/flat/pause-issue takes. |
| `bench_delivery_prosody.py` | Pairs `vocello bench --delivery` WAVs with neutral references. |
| `delivery_adherence.py` | Paired neutral-vs-instructed delivery A/B benchmark. |
| `summarize_generation_telemetry.py` | Aggregates JSONL telemetry into RTF/memory/QC/prosody tables. |
| `ios_device.sh` | `devicectl` driver for on-device iOS build/test/bench. |
| `build.sh` / `release.sh` | Local dev build and optimized DMG release. |
| `regenerate_project.sh` | XcodeGen project regeneration. |
| `check_project_inputs.sh` | Lint for project structure / retired paths. |
| `permissions_doctor.sh` | TCC permission diagnostics. |
| `verify_release_bundle.sh` / `verify_packaged_dmg.sh` / `verify_ios_release_archive.sh` | Signed-archive validation. |
| `export_diagnostics.py` | Diagnostic bundle export. |

---

## 10. Website Stack

In `website/`:

| Technology | Version | Purpose |
|---|---|---|
| **React** | `^18.3.1` | UI library. |
| **React DOM** | `^18.3.1` | DOM rendering. |
| **Vite** | `^7.2.7` | Build tool / dev server. |
| **`@vitejs/plugin-react`** | `^5.1.1` | Vite React plugin. |
| **Vercel** | — | Deployment/hosting. |

---

## 11. CI / Release Tooling

GitHub Actions: `.github/workflows/release.yml`.

| Tool | Role |
|---|---|
| **Xcode 26.0** | Build toolchain. |
| **XcodeGen** | Project generation. |
| **xcbeautify** | Build log formatting (via Homebrew, no version pin). |
| **Developer ID Application cert** | macOS DMG signing. |
| **`codesign`** | Binary/app signing. |
| **`notarytool`** | Apple notarization. |
| **`stapler`** | Notarization ticket stapling. |
| **`create-dmg`** / `scripts/create_dmg.sh` | DMG packaging. |
| **App Store Connect API key** | Notarization + (future) TestFlight upload. |

Required CI secrets: `APPLE_DEV_ID_APP_P12_BASE64`, `APPLE_DEV_ID_APP_P12_PASSWORD`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_PRIVATE_KEY_P8`, `APPLE_NOTARY_ISSUER_ID`, `APPLE_TEAM_ID`.

---

## 12. Platform Restrictions & Entitlements

### macOS (`Sources/QwenVoice.entitlements`)
- Sandboxing disabled (`com.apple.security.app-sandbox = false`).
- `com.apple.security.cs.allow-unsigned-executable-memory` — required for MLX JIT.
- `com.apple.security.cs.disable-library-validation` — required for MLX.
- `com.apple.security.files.user-selected.read-write` — user-selected output folders.
- `com.apple.security.device.audio-input` — microphone access.

### iOS (`Sources/iOS/VocelloiOS.entitlements`)
- App Group for shared container.
- `com.apple.developer.kernel.increased-memory-limit` — raises Jetsam ceiling for model load.

### Info.plist Permissions
- `NSMicrophoneUsageDescription` — reference clip recording.
- `NSSpeechRecognitionUsageDescription` — on-device transcription.
- `ITSAppUsesNonExemptEncryption = false`.

---

## 13. Key Design / Architecture Decisions

- **No Python backend** — everything runs natively in Swift + MLX.
- **No bundled model weights** — models download on demand from Hugging Face.
- **Single shippable config** — no Debug build; runtime debug mode via `QWENVOICE_DEBUG` / version-tap toggle.
- **macOS engine runs out-of-process via XPC** for crash isolation; **iOS engine runs in-process** due to ExtensionKit Jetsam limits.
- **Quality-first full-result generation** is the production default; streaming is used for iOS memory safety and live preview.
- **Local-first / privacy-first** — scripts, history, recordings, and generated audio stay on-device unless explicitly exported.

---

## Related Reference Docs

- [`mlx-audio-swift-patching.md`](mlx-audio-swift-patching.md) — vendored backend patch procedure + validation gates.
- [`prosody-qa-research.md`](prosody-qa-research.md) — prosody QA gate research and implementation.
- [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md) — telemetry schema and benchmark procedure.
- [`cli.md`](cli.md) — `vocello` CLI reference.
- [`ios-engine-optimization.md`](ios-engine-optimization.md) — iPhone engine optimization.
- [`privacy-storage.md`](privacy-storage.md) — local storage and privacy model.
- [`AGENTS.md`](../../AGENTS.md) — agent guide to the repo.
