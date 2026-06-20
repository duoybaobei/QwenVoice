import SwiftUI
import AppKit
import QwenVoiceNative

@main
struct QwenVoiceApp: App {
    @NSApplicationDelegateAdaptor(QwenVoiceApplicationDelegate.self)
    private var appDelegate
    @StateObject private var ttsEngineStore: TTSEngineStore
    @State private var didInitializeSelectedTTSEngine = false
    @StateObject private var audioPlayer = AudioPlayerViewModel()
    @State private var modelManager = ModelManagerViewModel()
    @State private var savedVoicesViewModel = SavedVoicesViewModel()
    @StateObject private var appCommandRouter = AppCommandRouter.shared
    @StateObject private var generationLibraryEvents = GenerationLibraryEvents.shared
    @StateObject private var appStartupCoordinator = AppStartupCoordinator()
    private let appEngineSelection: AppEngineSelection

    init() {
        let appEngineSelection = AppEngineSelection.current()
        self.appEngineSelection = appEngineSelection
        let engine = appEngineSelection.makeEngine()
        _ttsEngineStore = StateObject(
            wrappedValue: TTSEngineStore(
                engine: engine
            )
        )
    }

    var body: some Scene {
        WindowGroup(id: "mainWindow") {
            mainWindowContent
        }
        .defaultSize(width: 720, height: 560)
        Settings {
            // The Cmd+, scene hosts the same SettingsView the
            // sidebar shows, so muscle memory keeps working. Deep
            // link highlighting is a no-op in this surface (the
            // sidebar has no notion of "the user just clicked a
            // disabled mode" inside the standalone settings
            // window).
            SettingsView(highlightedMode: .constant(nil))
                .environment(modelManager)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        }
        .commands {
            CommandGroup(replacing: .newItem) { }

            // Playback commands
            CommandMenu("播放") {
                Button("播放 / 暂停") {
                    audioPlayer.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!audioPlayer.hasAudio)

                Button("停止") {
                    audioPlayer.dismiss()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!audioPlayer.hasAudio)
            }

            CommandMenu("导航") {
                Button("自定义声音") {
                    appCommandRouter.navigate(to: .customVoice)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("声音设计") {
                    appCommandRouter.navigate(to: .voiceDesign)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("声音克隆") {
                    appCommandRouter.navigate(to: .voiceCloning)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("历史记录") {
                    appCommandRouter.navigate(to: .history)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("已保存声音") {
                    appCommandRouter.navigate(to: .voices)
                }
                .keyboardShortcut("5", modifiers: .command)

                Button("模型") {
                    appCommandRouter.navigate(to: .settings)
                }
                .keyboardShortcut("6", modifiers: .command)
            }

            // File menu additions
            CommandGroup(after: .saveItem) {
                Divider()
                Button("打开输出文件夹") {
                    NSWorkspace.shared.open(Self.outputsDir)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("在 Finder 中显示") {
                    if let path = audioPlayer.currentFilePath {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(audioPlayer.currentFilePath == nil)
            }
        }
    }

    @ViewBuilder
    private var mainWindowContent: some View {
        Group {
            if let launchDiagnostics = appStartupCoordinator.launchDiagnostics {
                StartupDiagnosticsView(
                    snapshot: launchDiagnostics,
                    onRetry: retryLaunchPreflight
                )
                .frame(minWidth: 520, minHeight: 420)
            } else {
                ContentView()
                    .environmentObject(ttsEngineStore)
                    .environmentObject(audioPlayer)
                    .environmentObject(audioPlayer.playbackProgress)
                    .environment(modelManager)
                    .environment(savedVoicesViewModel)
                    .environmentObject(appCommandRouter)
                    .environmentObject(generationLibraryEvents)
                    .frame(minWidth: 720, minHeight: 560)
            }
        }
        .onAppear {
            appStartupCoordinator.setupAppSupport()
            startSelectedTTSEngineIfNeeded()
            appStartupCoordinator.refreshLaunchDiagnostics()
            AppLaunchConfiguration.openSettingsWindowIfNeeded()
        }
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }

    static var voicesDir: URL { AppPaths.voicesDir }

    static var appSupportDir: URL {
        AppPaths.appSupportDir
    }

    static var modelsDir: URL { AppPaths.modelsDir }
    static var outputsDir: URL { AppPaths.outputsDir }

    private func startSelectedTTSEngineIfNeeded() {
        guard appEngineSelection.requiresManualInitialization() else { return }
        guard !didInitializeSelectedTTSEngine else { return }
        didInitializeSelectedTTSEngine = true

        Task {
            do {
                try await ttsEngineStore.initialize(appSupportDirectory: Self.appSupportDir)
            } catch {
                // Native engine initialization publishes its own failure snapshot.
            }
        }
    }

    private func retryLaunchPreflight() {
        appStartupCoordinator.refreshLaunchDiagnostics()
    }
}
