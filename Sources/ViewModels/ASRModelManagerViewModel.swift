import Foundation
import Observation

/// Manages install state, download, and delete for the standalone read-along
/// training ASR model (Qwen3-ASR).
///
/// This is intentionally separate from `ModelManagerViewModel` (which owns the
/// TTS models): the ASR model is a speech-recognition model that must never
/// enter the TTS `models` array, and it is downloaded/unloaded independently
/// so it stays co-resident with the TTS engine only during the read-along
/// loop. The status machine is presence-based (no TTS-style deep integrity /
/// install metadata).
@MainActor
@Observable
final class ASRModelManagerViewModel {

    struct DownloadProgress: Equatable, Sendable {
        enum Phase: String, Equatable, Sendable {
            case downloading
            case interrupted
            case resuming
            case verifying
            case installing
        }

        let downloadedBytes: Int64
        let totalBytes: Int64?
        let completedFiles: Int
        let totalFiles: Int?
        let bytesPerSecond: Int64?
        let isStalled: Bool
        let phase: Phase

        static let initial = DownloadProgress(
            downloadedBytes: 0,
            totalBytes: nil,
            completedFiles: 0,
            totalFiles: nil,
            bytesPerSecond: nil,
            isStalled: false,
            phase: .downloading
        )
    }

    enum Status: Equatable {
        case unavailable
        case checking
        case notDownloaded(message: String?)
        case downloading(progress: DownloadProgress)
        case repairAvailable(missingRequiredPaths: [String], message: String?)
        case downloaded(sizeBytes: Int)
    }

    /// The ASR model declared in the contract, or `nil` when the contract has
    /// none (in which case the Settings section hides itself).
    let model: ASRModel?
    private(set) var status: Status

    private let fileManager: FileManager
    private let modelsDirectory: URL

    private var downloader: HuggingFaceDownloader?
    private var downloadTask: Task<Void, Never>?
    private var stateEpoch = 0
    private var lastProgressPublishTime: ContinuousClock.Instant?
    private var lastFailureMessage: String?

    init(
        model: ASRModel? = ASRModelContract.asrModel,
        fileManager: FileManager = .default,
        modelsDirectory: URL = QwenVoiceApp.modelsDir
    ) {
        self.model = model
        self.fileManager = fileManager
        self.modelsDirectory = modelsDirectory
        self.status = model == nil ? .unavailable : .checking
        refreshSync()
    }

    // MARK: - Derived state

    var isAvailable: Bool {
        if case .downloaded = status { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    var primaryActionTitle: String? {
        switch status {
        case .notDownloaded:
            return "下载语音识别模型"
        case .repairAvailable:
            return "修复语音识别模型"
        default:
            return nil
        }
    }

    /// Localized size string for the download control. Uses the resolved on-disk
    /// size when installed, falling back to the manifest estimate otherwise.
    var sizeText: String? {
        switch status {
        case .downloaded(let sizeBytes):
            guard sizeBytes > 0 else { return nil }
            return Self.formattedFileSize(Int64(sizeBytes))
        case .notDownloaded, .repairAvailable:
            guard let estimated = model?.estimatedDownloadBytes, estimated > 0 else {
                return nil
            }
            return Self.formattedFileSize(estimated)
        case .downloading, .checking, .unavailable:
            return nil
        }
    }

    func downloadDetail(for progress: DownloadProgress) -> String? {
        if progress.isStalled {
            return "等待网络恢复…"
        }
        if let totalBytes = progress.totalBytes, totalBytes > 0 {
            let downloaded = Self.formattedFileSize(progress.downloadedBytes)
            let total = Self.formattedFileSize(totalBytes)
            return "\(downloaded) / \(total)"
        }
        if let totalFiles = progress.totalFiles, totalFiles > 0 {
            return "\(progress.completedFiles) / \(totalFiles) 个文件"
        }
        return nil
    }

    // MARK: - Mutations

    func refresh() {
        guard model != nil else { return }
        guard !isDownloading else { return }
        refreshSync()
    }

    func download() async {
        guard let model else { return }
        if let downloadTask {
            await downloadTask.value
            return
        }

        let epoch = beginEpoch()
        lastFailureMessage = nil
        status = .downloading(progress: .initial)

        let targetDir = model.installDirectory(in: modelsDirectory)
        let modelsDirectory = self.modelsDirectory

        downloader?.cancel()
        downloader = nil

        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let downloader = HuggingFaceDownloader(progressHandler: { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.publishDownloadProgressIfCurrent(epoch: epoch, progress: progress)
            }
        })
        self.downloader = downloader

        let task = Task {
            do {
                try await downloader.downloadRepo(
                    repo: model.huggingFaceRepo,
                    revision: model.huggingFaceRevision ?? "main",
                    to: targetDir
                )
                guard isCurrentEpoch(epoch) else { return }
                let missing = model.missingRequiredPaths(in: modelsDirectory, fileManager: fileManager)
                if !missing.isEmpty {
                    lastFailureMessage = "下载完成，但仍缺少必要的模型文件。"
                }
                handleMutationCompletion()
            } catch is CancellationError {
                guard isCurrentEpoch(epoch) else { return }
                handleMutationCompletion()
            } catch let dlError as HuggingFaceDownloader.DownloadError {
                guard isCurrentEpoch(epoch) else { return }
                switch dlError {
                case .cancelled:
                    lastFailureMessage = nil
                default:
                    lastFailureMessage = dlError.localizedDescription
                }
                handleMutationCompletion()
            } catch {
                guard isCurrentEpoch(epoch) else { return }
                lastFailureMessage = error.localizedDescription
                handleMutationCompletion()
            }
        }
        downloadTask = task
        await task.value
    }

    func cancelDownload() {
        _ = beginEpoch()
        downloader?.cancel()
        downloader = nil
        downloadTask?.cancel()
        downloadTask = nil
        handleMutationCompletion()
    }

    func delete() {
        guard let model else { return }
        _ = beginEpoch()
        downloader?.cancel()
        downloader = nil
        downloadTask?.cancel()
        downloadTask = nil

        let modelDir = model.installDirectory(in: modelsDirectory)
        try? fileManager.removeItem(at: modelDir)
        lastFailureMessage = nil
        handleMutationCompletion()
    }

    // MARK: - Internals

    private func handleMutationCompletion() {
        downloader = nil
        downloadTask = nil
        lastProgressPublishTime = nil
        refreshSync()
    }

    private func refreshSync() {
        guard let model else {
            status = .unavailable
            return
        }
        let installDirectory = model.installDirectory(in: modelsDirectory)
        let rootExists = fileManager.fileExists(atPath: installDirectory.path)
        guard rootExists else {
            status = .notDownloaded(message: lastFailureMessage)
            return
        }
        let missing = model.missingRequiredPaths(in: modelsDirectory, fileManager: fileManager)
        if missing.isEmpty {
            lastFailureMessage = nil
            status = .downloaded(sizeBytes: Self.directorySize(url: installDirectory))
        } else {
            status = .repairAvailable(missingRequiredPaths: missing, message: lastFailureMessage)
        }
    }

    private func publishDownloadProgressIfCurrent(
        epoch: Int,
        progress: HuggingFaceDownloader.RepositoryProgress
    ) {
        guard isCurrentEpoch(epoch) else { return }
        guard case .downloading = status else { return }

        let now = ContinuousClock.now
        if let lastPublish = lastProgressPublishTime,
           now - lastPublish < .milliseconds(100) {
            return
        }
        lastProgressPublishTime = now

        status = .downloading(
            progress: DownloadProgress(
                downloadedBytes: progress.downloadedBytes,
                totalBytes: progress.totalBytes > 0 ? progress.totalBytes : nil,
                completedFiles: progress.completedFiles,
                totalFiles: progress.totalFiles > 0 ? progress.totalFiles : nil,
                bytesPerSecond: progress.bytesPerSecond,
                isStalled: progress.isStalled,
                phase: DownloadProgress.Phase(progress.phase)
            )
        )
    }

    private func beginEpoch() -> Int {
        stateEpoch += 1
        return stateEpoch
    }

    private func isCurrentEpoch(_ epoch: Int) -> Bool {
        stateEpoch == epoch
    }

    private nonisolated static func formattedFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private nonisolated static func directorySize(url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
    }
}

extension ASRModelManagerViewModel.DownloadProgress.Phase {
    var displayLabel: String {
        switch self {
        case .downloading:
            return "下载中"
        case .interrupted:
            return "已中断"
        case .resuming:
            return "恢复中"
        case .verifying:
            return "校验中"
        case .installing:
            return "安装中"
        }
    }

    init(_ phase: HuggingFaceDownloader.DownloadPhase) {
        switch phase {
        case .downloading:
            self = .downloading
        case .interrupted:
            self = .interrupted
        case .resuming:
            self = .resuming
        case .verifying:
            self = .verifying
        case .installing:
            self = .installing
        }
    }
}
