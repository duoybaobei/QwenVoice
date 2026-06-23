import Foundation

/// A standalone, downloadable **speech recognition** model used by the
/// read-along training feature to transcribe the child's spoken repetitions.
///
/// Like `StoryModel`, this is deliberately *not* a `TTSModel`: the ASR model
/// is a Qwen3-ASR encoder-decoder (no TTS variants, no `speech_tokenizer`,
/// no `qwen3Capabilities`), so it must never enter the TTS `models` array or
/// it would trip the backend contract validation. It lives under the separate
/// top-level `asrModels` key in `qwenvoice_contract.json` and is managed by
/// its own lightweight `ASRModelManagerViewModel`, independent of the TTS
/// engine.
struct ASRModel: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    /// One-line description shown under the package name in Settings.
    let shortDescription: String?
    let huggingFaceRepo: String
    let huggingFaceRevision: String?
    /// On-disk folder name under the models directory (e.g. "Qwen3-ASR-0.6B-4bit").
    let folder: String
    let estimatedDownloadBytes: Int64?
    /// The minimal set of files that must be present for the model to load.
    let requiredRelativePaths: [String]

    func installDirectory(in modelsDirectory: URL) -> URL {
        modelsDirectory.appendingPathComponent(folder, isDirectory: true)
    }

    func isAvailable(in modelsDirectory: URL, fileManager: FileManager = .default) -> Bool {
        missingRequiredPaths(in: modelsDirectory, fileManager: fileManager).isEmpty
    }

    /// Required files that are not present on disk. Empty when complete.
    func missingRequiredPaths(
        in modelsDirectory: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        let installDirectory = installDirectory(in: modelsDirectory)
        guard fileManager.fileExists(atPath: installDirectory.path) else {
            // No folder yet: treat as "not downloaded", not "repairable".
            return []
        }
        return requiredRelativePaths.filter { relativePath in
            !fileManager.fileExists(atPath: installDirectory.appendingPathComponent(relativePath).path)
        }
    }
}

// MARK: - Contract loader

private final class ASRModelContractBundleLocator: NSObject { }

/// Reads only the `asrModels` array out of the bundled
/// `qwenvoice_contract.json`. The TTS contract decoder (`TTSContract` /
/// `ContractBackedModelRegistry`) ignores this key, so the two surfaces stay
/// independent: TTS validation never sees the ASR model, and a malformed
/// `asrModels` entry can't break the TTS pipeline.
enum ASRModelContract {
    private struct Manifest: Decodable {
        let asrModels: [ASRModel]?
    }

    /// All ASR models declared in the contract (currently just one).
    static let asrModels: [ASRModel] = loadASRModels()

    /// The single recommended ASR model, or `nil` if the contract has none.
    static var asrModel: ASRModel? {
        asrModels.first
    }

    private static func loadASRModels() -> [ASRModel] {
        guard let url = locateManifestURL(),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return []
        }
        return manifest.asrModels ?? []
    }

    private static func locateManifestURL() -> URL? {
        let bundles = [Bundle.main, Bundle(for: ASRModelContractBundleLocator.self)]
            + Bundle.allBundles
            + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(forResource: "qwenvoice_contract", withExtension: "json") {
                return url
            }
        }
        return nil
    }
}
