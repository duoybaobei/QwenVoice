import Foundation

@MainActor
final class AppStartupCoordinator: ObservableObject {
    @Published private(set) var launchDiagnostics: AppLaunchDiagnosticsSnapshot?

    func setupAppSupport() {
        let fm = FileManager.default
        let outputSubdirectories = Set(TTSModel.all.map(\.outputSubfolder))
        let appSupportDir = AppPaths.appSupportDir

        let dirs = [
            appSupportDir.path,
            appSupportDir.appendingPathComponent("models").path,
            appSupportDir.appendingPathComponent("outputs").path,
            appSupportDir.appendingPathComponent("voices").path,
            appSupportDir.appendingPathComponent("cache").path,
            appSupportDir.appendingPathComponent("cache/stream_sessions").path,
        ] + outputSubdirectories.sorted().map {
            appSupportDir.appendingPathComponent("outputs/\($0)").path
        }

        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        AppPaths.excludeFromBackup(appSupportDir.appendingPathComponent("models", isDirectory: true))
        AppPaths.excludeFromBackup(appSupportDir.appendingPathComponent("cache", isDirectory: true))
    }

    func refreshLaunchDiagnostics() {
        launchDiagnostics = AppLaunchPreflight.run()
    }

    func clearLaunchDiagnostics() {
        launchDiagnostics = nil
    }
}
