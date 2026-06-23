import QwenVoiceCore
import QwenVoiceNative
import SwiftUI

/// 故事王国 (Story Kingdom): pick a built-in speaker, language, and tone, then
/// tap a story to hear it rendered in real time. Generation routes through the
/// same Custom Voice path (`CustomVoiceCoordinator` + `GenerationMode.custom`),
/// so playback streams live exactly like the Custom Voice screen — the only
/// difference is the script comes from a curated `Story` instead of a text box.
/// Which voice powers the story narration: a built-in speaker (the original
/// Story Kingdom behaviour) or the user's own cloned voice (reusing the Voice
/// Cloning import/record reference path + clone model).
enum StoryVoiceSource: String, CaseIterable, Identifiable {
    case builtIn
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .builtIn: return "内置声音"
        case .custom: return "自定义声音"
        }
    }
}

struct StoryKingdomView: View {
    @Binding private var draft: CustomVoiceDraft
    @Binding private var cloneDraft: VoiceCloningDraft
    @State private var coordinator = CustomVoiceCoordinator()
    /// The story whose play button kicked off the in-flight generation, so the
    /// list can show a stop control on exactly that row.
    @State private var activeStoryID: String?

    /// Built-in speaker vs. cloned-voice narration. Built-in keeps the original
    /// flow untouched; custom routes through the Voice Cloning reference + clone
    /// model and exposes only the language control. Persisted so the pick (and
    /// the resumed saved voice) survives relaunch.
    @AppStorage("storyKingdom.voiceSource") private var voiceSource: StoryVoiceSource = .builtIn
    /// The saved-voice id last used for cloned narration, restored on launch so
    /// the user can resume with the same voice without re-importing.
    @AppStorage("storyKingdom.savedVoiceID") private var persistedSavedVoiceID = ""
    @State private var cloneCoordinator = VoiceCloningCoordinator()
    @State private var isRecordSheetPresented = false
    /// Drives the "保存声音" enroll sheet for a freshly imported/recorded clip.
    @State private var savedVoiceSheetConfig: SavedVoiceSheetConfiguration?

    private let savedVoicesViewModel: SavedVoicesViewModel
    private let stories = Story.sample

    /// All stories shown in the list: writer-generated takes (newest first) on
    /// top of the built-in library. Generated stories are ephemeral (in-memory
    /// only); built-ins are the curated `Story.sample` set.
    private var displayedStories: [Story] {
        generatedStories + stories
    }

    /// Standalone text LLM writer. Streams a child-safe story from the on-device
    /// Qwen3 model (loaded only for the duration of a single generation, then
    /// unloaded so it is never co-resident with the TTS model on 8 GB Macs).
    /// Generated stories are committed to `generatedStories` and read aloud via
    /// the same TTS path as the built-in `Story.sample` entries.
    @State private var storyWriter = StoryTextGenerator()
    /// Curated preset themes shown in the writer. Frozen here so the view never
    /// rebuilds the list mid-session.
    private let storyThemes: [StoryTheme] = StoryTheme.presets
    /// The theme currently selected in the writer chip row. Defaults to the
    /// first preset (bedtime).
    @State private var selectedThemeID: String = StoryTheme.presets.first?.id ?? ""
    /// Stories produced by the writer this session, shown above the built-in
    /// library. Kept in memory (not persisted) per the "one at a time" spec —
    /// each generation is a fresh, ephemeral take.
    @State private var generatedStories: [Story] = []
    /// Monotonic counter so each committed generated story gets a unique id
    /// (never collides with the static `Story.sample` ids).
    @State private var generatedStoryCounter = 0
    /// Drives the writer loading animation (wand pulse) while the model is
    /// loading or the story is streaming.
    @State private var isWriterAnimating = false
    /// `true` while a generated story is actively streaming from the writer,
    /// used to gate the writer controls and show a live "typing" surface.
    private var isWriterActive: Bool {
        storyWriter.isActive
    }

    /// The story currently driving (or that just drove) a generation, used to
    /// render the synced reader and the per-row stop control.
    private var activeStory: Story? {
        guard let activeStoryID else { return nil }
        return displayedStories.first { $0.id == activeStoryID }
    }

    @ObservedObject private var ttsEngineStore: TTSEngineStore
    private var modelManager: ModelManagerViewModel
    private let audioPlayer: AudioPlayerViewModel
    private let storyModelManager: StoryModelManagerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeMode: GenerationMode {
        voiceSource == .custom ? .clone : .custom
    }

    private var activeModel: TTSModel? {
        modelManager.generationActiveVariant(for: activeMode)
    }

    private var isModelAvailable: Bool {
        guard let activeModel else { return false }
        return modelManager.isAvailable(activeModel)
    }

    private var modelDisplayName: String {
        activeModel.map(modelManager.generationVariantDisplayName) ?? "Unknown"
    }

    private var supportsDeliveryControl: Bool {
        activeModel?.supportsInstructionControl ?? false
    }

    /// Custom (clone) mode needs a reference clip before any story can play.
    private var hasCloneReference: Bool {
        cloneDraft.referenceAudioPath != nil
    }

    /// The saved voice currently backing the clone draft, if its id resolves to
    /// a loaded entry.
    private var selectedSavedVoice: Voice? {
        guard let id = cloneDraft.selectedSavedVoiceID else { return nil }
        return savedVoicesViewModel.voices.first { $0.id == id }
    }

    /// A fresh imported/recorded clip that hasn't been persisted yet can be
    /// offered a "保存声音" action; an already-saved selection cannot.
    private var canSaveCurrentReference: Bool {
        cloneDraft.referenceAudioPath != nil && cloneDraft.selectedSavedVoiceID == nil
    }

    /// Picker binding mirroring Voice Cloning: selecting hydrates the draft from
    /// the saved voice; clearing drops the reference.
    private var savedVoiceSelectionBinding: Binding<String?> {
        Binding(
            get: { cloneDraft.selectedSavedVoiceID },
            set: { newID in
                guard let newID else {
                    if cloneDraft.referenceAudioPath != nil || cloneDraft.selectedSavedVoiceID != nil {
                        cloneCoordinator.clearReference(draft: $cloneDraft)
                    }
                    return
                }
                guard let voice = savedVoicesViewModel.voices.first(where: { $0.id == newID }) else { return }
                cloneCoordinator.selectSavedVoice(voice, draft: $cloneDraft)
            }
        )
    }

    /// Priming key for the cloned reference so the engine can pre-condition the
    /// take; nil when not in custom mode or no reference is selected yet.
    private var clonePrimingRequestKey: String? {
        guard voiceSource == .custom,
              ttsEngineStore.isReady,
              isModelAvailable,
              let model = activeModel,
              let refPath = cloneDraft.referenceAudioPath else {
            return nil
        }
        return GenerationSemantics.clonePreparationKey(
            modelID: model.id,
            reference: CloneReference(
                audioPath: refPath,
                transcript: cloneDraft.trimmedReferenceTranscript,
                preparedVoiceID: nil
            )
        )
    }

    /// Re-runs proactive clone priming whenever the reference (or model)
    /// changes; idle string when there's nothing to warm.
    private var clonePrimingTaskID: String {
        clonePrimingRequestKey ?? "clone-priming-idle"
    }

    private var isGenerationActive: Bool {
        coordinator.isGenerating
            || cloneCoordinator.isGenerating
            || ttsEngineStore.hasActiveGeneration
    }

    private var canGenerate: Bool {
        ttsEngineStore.isReady
            && isModelAvailable
            && !ttsEngineStore.hasActiveGeneration
            && (voiceSource == .builtIn || hasCloneReference)
    }

    /// `true` when the standalone story text model is installed and ready to
    /// generate. The writer is disabled (with a hint pointing to Settings) until
    /// the user downloads it.
    private var isStoryModelAvailable: Bool {
        storyModelManager.isAvailable
    }

    /// `true` only while the writer is producing text. Distinct from
    /// `isGenerationActive` (which tracks the TTS read-aloud path) so the two
    /// engines never get confused — the writer and TTS run strictly serial.
    private var isWriterStreaming: Bool {
        isWriterActive
    }

    /// The currently selected writer theme, resolved from `selectedThemeID`.
    private var selectedTheme: StoryTheme? {
        storyThemes.first { $0.id == selectedThemeID }
    }

    /// Whether the writer can start a new story right now: model installed and
    /// no writer generation already in flight.
    private var canWriteStory: Bool {
        isStoryModelAvailable && !isWriterActive
    }

    private var activeErrorMessage: String? {
        voiceSource == .custom ? cloneCoordinator.errorMessage : coordinator.errorMessage
    }

    private var readiness: CustomVoiceReadinessPresentation {
        CustomVoiceReadinessPresentation.resolve(
            snapshot: ttsEngineStore.snapshot,
            activeModelID: activeModel?.id,
            isModelAvailable: isModelAvailable,
            // Stories always carry text; gate purely on engine + model state.
            hasText: true,
            isGenerating: isGenerationActive,
            modelDisplayName: modelDisplayName
        )
    }

    init(
        draft: Binding<CustomVoiceDraft>,
        cloneDraft: Binding<VoiceCloningDraft>,
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel,
        savedVoicesViewModel: SavedVoicesViewModel,
        storyModelManager: StoryModelManagerViewModel
    ) {
        _draft = draft
        _cloneDraft = cloneDraft
        _ttsEngineStore = ObservedObject(wrappedValue: ttsEngineStore)
        self.modelManager = modelManager
        self.audioPlayer = audioPlayer
        self.savedVoicesViewModel = savedVoicesViewModel
        self.storyModelManager = storyModelManager
    }

    var body: some View {
        PageScaffold(
            accessibilityIdentifier: "screen_storyKingdom",
            fillsViewportHeight: true,
            contentSpacing: LayoutConstants.generationSectionSpacing,
            contentMaxWidth: LayoutConstants.generationContentMaxWidth,
            topPadding: LayoutConstants.generationPageTopPadding,
            bottomPadding: LayoutConstants.generationPageBottomPadding
        ) {
            configurationPanel
            storyWriterPanel
            if let activeStory {
                storyReaderPanel(for: activeStory)
            }
            storyListPanel
                .layoutPriority(1)
        }
        .overlay {
            StoryPrimingOverlay(
                progress: audioPlayer.playbackProgress,
                isGenerating: isGenerationActive,
                accentColor: AppTheme.customVoice
            )
        }
        .modeGlassTint(AppTheme.customVoice)
        .modeCanvasBackdrop(AppTheme.customVoice)
        .onAppear(perform: reconcileGenerationVariantSelection)
        .onChange(of: voiceSource) { _, _ in reconcileGenerationVariantSelection() }
        .onChange(of: modelManager.statuses) { _, _ in reconcileGenerationVariantSelection() }
        .onChange(of: modelManager.activeVariantRevision) { _, _ in reconcileGenerationVariantSelection() }
        .task {
            await savedVoicesViewModel.ensureLoaded(using: ttsEngineStore)
            hydratePersistedSavedVoiceIfNeeded()
        }
        .task(id: clonePrimingTaskID) {
            // Proactively warm the clone model + reference conditioning the
            // moment a reference is selected, so the first story play skips the
            // slow cold-start priming. No-op (and cancels stale priming) when
            // not in custom mode or no reference is set.
            await cloneCoordinator.syncCloneReferencePriming(
                draft: cloneDraft,
                cloneModel: activeModel,
                isModelAvailable: isModelAvailable,
                clonePrimingRequestKey: clonePrimingRequestKey,
                ttsEngineStore: ttsEngineStore
            )
        }
        .onChange(of: ttsEngineStore.isReady) { _, ready in
            guard ready else { return }
            Task {
                await savedVoicesViewModel.ensureLoaded(using: ttsEngineStore)
                hydratePersistedSavedVoiceIfNeeded()
            }
        }
        .onChange(of: savedVoicesViewModel.voices) { _, _ in
            hydratePersistedSavedVoiceIfNeeded()
        }
        .onChange(of: cloneDraft.selectedSavedVoiceID) { _, id in
            persistedSavedVoiceID = id ?? ""
        }
        .onChange(of: storyWriter.phase) { _, newPhase in
            commitGeneratedStoryIfNeeded(phase: newPhase)
        }
        .sheet(isPresented: $isRecordSheetPresented) {
            RecordReferenceClipSheet { url in
                cloneCoordinator.replaceReference(with: url.path, draft: $cloneDraft)
            }
        }
        .sheet(item: $coordinator.presentedSheet) { presentedSheet in
            switch presentedSheet {
            case .batch(let configuration):
                BatchGenerationSheet(
                    mode: configuration.mode,
                    voice: configuration.voice,
                    emotion: configuration.emotion,
                    languageHint: draft.selectedLanguage.rawValue,
                    voiceDescription: configuration.voiceDescription,
                    refAudio: configuration.refAudio,
                    refText: configuration.refText,
                    initialText: configuration.initialText,
                    initialSegmentationMode: configuration.initialSegmentationMode
                )
                .environmentObject(ttsEngineStore)
                .environmentObject(audioPlayer)
            }
        }
    }

    func reconcileGenerationVariantSelection() {
        modelManager.reconcileGenerationVariantSelectionIfNeeded(for: activeMode)
    }
}

// MARK: - Subviews

private extension StoryKingdomView {
    var configurationPanel: some View {
        CompactConfigurationSection(
            title: "配置",
            iconName: "slider.horizontal.3",
            accentColor: AppTheme.customVoice,
            trailingAccessory: AnyView(variantSelector),
            rowSpacing: LayoutConstants.generationConfigurationRowSpacing,
            panelPadding: LayoutConstants.generationConfigurationPanelPadding
        ) {
            VStack(alignment: .leading, spacing: 0) {
                voiceSourceSettings
                if voiceSource == .custom {
                    savedVoiceSettings
                    cloneReferenceSettings
                    languageOnlySettings
                } else {
                    speakerSettings
                    if supportsDeliveryControl {
                        languageAndDeliverySettings
                    } else {
                        languageOnlySettings
                        deliveryUnsupportedHint
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            HiddenAccessibilityMarker(
                value: "Configuration",
                identifier: "storyKingdom_configuration"
            )
        }
        .animation(.none, value: draft.selectedSpeaker)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $savedVoiceSheetConfig) { config in
            SavedVoiceSheet(configuration: config) { voice in
                savedVoicesViewModel.insertOrReplace(voice)
                cloneCoordinator.selectSavedVoice(voice, draft: $cloneDraft)
            }
            .environmentObject(ttsEngineStore)
        }
    }

    var voiceSourceSettings: some View {
        GenerationSetupRow(
            label: "声音来源",
            accessibilityIdentifier: "storyKingdom_voiceSourceSetup"
        ) {
            Picker("声音来源", selection: $voiceSource) {
                ForEach(StoryVoiceSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(isGenerationActive)
            .frame(maxWidth: 240, alignment: .leading)
            .accessibilityValue(voiceSource.label)
            .accessibilityIdentifier("storyKingdom_voiceSourcePicker")
        }
    }

    @ViewBuilder
    var savedVoiceSettings: some View {
        if !savedVoicesViewModel.voices.isEmpty {
            GenerationSetupRow(
                label: "保存的声音",
                accessibilityIdentifier: "storyKingdom_savedVoiceSetup"
            ) {
                Picker("保存的声音", selection: savedVoiceSelectionBinding) {
                    Text("不使用").tag(String?.none)
                    ForEach(savedVoicesViewModel.voices, id: \.id) { voice in
                        Text(voice.name).tag(Optional(voice.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .focusEffectDisabled()
                .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: 220, alignment: .leading)
                .disabled(isGenerationActive)
                .accessibilityValue(selectedSavedVoice?.name ?? "不使用")
                .accessibilityIdentifier("storyKingdom_savedVoicePicker")
            }
        }
    }

    var cloneReferenceSettings: some View {
        GenerationSetupRow(
            label: "参考声音",
            accessibilityIdentifier: "storyKingdom_cloneReferenceSetup"
        ) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    cloneCoordinator.browseForAudio(draft: $cloneDraft)
                } label: {
                    Label(hasCloneReference ? "替换" : "导入", systemImage: "waveform.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.customVoice)
                .controlSize(.small)
                .disabled(isGenerationActive)
                .accessibilityIdentifier("storyKingdom_importButton")

                Button {
                    isRecordSheetPresented = true
                } label: {
                    Label("录音", systemImage: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.customVoice)
                .controlSize(.small)
                .disabled(isGenerationActive)
                .accessibilityIdentifier("storyKingdom_recordReferenceButton")

                if canSaveCurrentReference {
                    Button {
                        presentSaveVoiceSheet()
                    } label: {
                        Label("保存声音", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.customVoice)
                    .controlSize(.small)
                    .disabled(isGenerationActive)
                    .accessibilityIdentifier("storyKingdom_saveVoiceButton")
                }

                Spacer(minLength: 0)
            }
        } supporting: {
            GenerationSetupHint(
                message: "仅使用你拥有或已获授权的声音片段。",
                accessibilityIdentifier: "storyKingdom_consentNotice"
            )
            cloneReferenceStatus
        }
    }

    @ViewBuilder
    var cloneReferenceStatus: some View {
        if let path = cloneDraft.referenceAudioPath {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.customVoice)

                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button("清除") {
                    AppLaunchConfiguration.performAnimated(.default) {
                        cloneCoordinator.clearReference(draft: $cloneDraft)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGenerationActive)
            }
            .inlinePanel(padding: 8, radius: 10)
            .accessibilityIdentifier("storyKingdom_activeReference")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("尚未选择参考声音。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 1)
        }
    }

    var variantSelector: some View {
        GenerationVariantSelector(
            mode: activeMode,
            modelManager: modelManager,
            accentColor: AppTheme.customVoice,
            accessibilityPrefix: "storyKingdom",
            isDisabled: isGenerationActive
        )
    }

    var speakerSettings: some View {
        GenerationSetupRow(
            label: "说话人",
            accessibilityIdentifier: "storyKingdom_voiceSetup"
        ) {
            Picker("说话人", selection: $draft.selectedSpeaker) {
                ForEach(TTSModel.allSpeakers, id: \.self) { speaker in
                    Text(TTSModel.speakerPickerLabel(for: speaker)).tag(speaker)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .focusEffectDisabled()
            .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: 220, alignment: .leading)
            .accessibilityValue(TTSModel.speakerPickerLabel(for: draft.selectedSpeaker))
            .accessibilityIdentifier("storyKingdom_speakerPicker")
        }
    }

    var languageAndDeliverySettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            DeliveryControlsView(
                emotion: $draft.emotion,
                accentColor: AppTheme.customVoice,
                accessibilityPrefix: "storyKingdom",
                isCompact: true,
                showsLabel: false,
                usesColumnLabels: true,
                leadingColumns: AnyView(languageColumn)
            )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storyKingdom_toneSpeed")
    }

    var languageOnlySettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            languageColumn
        }
        .padding(.vertical, 4)
    }

    var languageColumn: some View {
        ConfigurationColumn(label: "语言") {
            QwenLanguagePicker(
                selectedLanguage: $draft.selectedLanguage,
                accentColor: AppTheme.customVoice,
                accessibilityPrefix: "storyKingdom",
                minWidth: 110
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storyKingdom_languageSetup")
    }

    var deliveryUnsupportedHint: some View {
        GenerationSetupNotice(
            message: "语气控制需要当前的 1.7B 模型支持。",
            iconName: "slider.horizontal.3",
            accentColor: AppTheme.customVoice,
            accessibilityIdentifier: "storyKingdom_deliveryUnsupported"
        )
    }

    func storyReaderPanel(for story: Story) -> some View {
        StudioSectionCard(
            title: "正在朗读",
            iconName: "music.note.list",
            accentColor: AppTheme.customVoice,
            trailingText: story.title,
            accessibilityIdentifier: "storyKingdom_reader"
        ) {
            StoryReaderView(
                story: story,
                progress: audioPlayer.playbackProgress,
                accentColor: AppTheme.customVoice
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The local story writer (故事生成). Picks a preset theme, streams a
    /// child-safe story from the on-device Qwen3 text model, and commits the
    /// finished text to `generatedStories` so it can be read aloud via the
    /// normal TTS path. The text LLM is loaded only for the duration of a
    /// single generation and unloaded before TTS takes over.
    var storyWriterPanel: some View {
        StudioSectionCard(
            title: "生成故事",
            iconName: "wand.and.stars",
            accentColor: AppTheme.customVoice,
            trailingText: writerTrailingStatus,
            accessibilityIdentifier: "storyKingdom_storyWriter"
        ) {
            VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
                if !isStoryModelAvailable {
                    GenerationSetupNotice(
                        message: "请先在「设置」中下载故事模型，才能生成故事。",
                        iconName: "arrow.down.circle",
                        accentColor: AppTheme.customVoice,
                        accessibilityIdentifier: "storyKingdom_storyWriterNeedsModel"
                    )
                }

                themePickerRow

                writerStreamingSurface

                if let failMessage = writerFailureMessage {
                    Label(failMessage, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.callout)
                        .accessibilityIdentifier("storyKingdom_storyWriterError")
                }

                writerActionBar
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var writerTrailingStatus: String? {
        switch storyWriter.phase {
        case .loadingModel: return "加载模型…"
        case .generating: return "生成中…"
        case .unloading: return "释放模型…"
        case .failed: return "失败"
        case .idle: return nil
        }
    }

    private var writerFailureMessage: String? {
        if case .failed(let message) = storyWriter.phase { return message }
        return nil
    }

    /// The theme chip row. Disabled while a generation is in flight so the
    /// user can't switch themes mid-stream.
    private var themePickerRow: some View {
        GenerationSetupRow(
            label: "主题",
            accessibilityIdentifier: "storyKingdom_storyWriterThemeSetup"
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(storyThemes) { theme in
                        themeChip(theme)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minWidth: LayoutConstants.configurationControlMinWidth, maxWidth: 320, alignment: .leading)
        }
    }

    private func themeChip(_ theme: StoryTheme) -> some View {
        let isSelected = theme.id == selectedThemeID
        return Button {
            selectedThemeID = theme.id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: theme.iconName)
                    .font(.system(size: 11, weight: .semibold))
                Text(theme.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AppTheme.customVoice.opacity(0.18) : AppTheme.inlineFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? AppTheme.customVoice.opacity(0.5) : AppTheme.inlineStroke.opacity(0.3),
                        lineWidth: isSelected ? 1 : 0.75
                    )
            )
            .foregroundStyle(isSelected ? AppTheme.customVoice : .primary)
        }
        .buttonStyle(.plain)
        .disabled(isWriterActive)
        .opacity(isWriterActive && !isSelected ? 0.5 : 1)
        .accessibilityLabel(theme.title)
        .accessibilityValue(isSelected ? "已选择" : "")
        .accessibilityIdentifier("storyKingdom_storyWriterTheme_\(theme.id)")
    }

    /// Live streaming surface. Shows the text as it streams (typed out), or a
    /// placeholder while idle. Hidden entirely when the model isn't installed.
    @ViewBuilder
    private var writerStreamingSurface: some View {
        if isStoryModelAvailable {
            let text = storyWriter.streamingText
            let isStreaming = isWriterStreaming
            let isLoadingModel = storyWriter.phase == .loadingModel
            ScrollView {
                ScrollViewReader { proxy in
                    if isLoadingModel && text.isEmpty {
                        writerLoadingPlaceholder
                    } else {
                        Text(text.isEmpty && !isStreaming
                             ? "选好主题，点「生成故事」开始创作。"
                             : text)
                            .font(.body)
                            .foregroundStyle(isStreaming ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id("storyKingdom_writerStreamEnd")
                            .onChange(of: text.count) { _, _ in
                                proxy.scrollTo("storyKingdom_writerStreamEnd", anchor: .bottom)
                            }
                    }
                }
            }
            .frame(maxHeight: 160)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.inlineFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isStreaming || isLoadingModel
                            ? AppTheme.customVoice.opacity(0.4)
                            : AppTheme.inlineStroke.opacity(0.3),
                        lineWidth: isStreaming || isLoadingModel ? 1 : 0.75
                    )
            )
            .appAnimation(.easeInOut(duration: 0.25), value: isStreaming)
            .appAnimation(.easeInOut(duration: 0.25), value: isLoadingModel)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("生成的故事")
            .accessibilityIdentifier("storyKingdom_storyWriterStream")
        }
    }

    /// Animated placeholder shown while the story model is loading and no text
    /// has streamed yet — three pulsing dots + a "正在加载故事模型" hint.
    private var writerLoadingPlaceholder: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(AppTheme.customVoice.opacity(0.7))
                        .frame(width: 8, height: 8)
                        .scaleEffect(isWriterAnimating ? 1.0 : 0.5)
                        .opacity(isWriterAnimating ? 1.0 : 0.3)
                        .appAnimation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.18),
                            value: isWriterAnimating
                        )
                }
            }
            Text("正在加载故事模型…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
        .onAppear { isWriterAnimating = true }
        .onDisappear { isWriterAnimating = false }
    }

    /// Generate / cancel button row.
    private var writerActionBar: some View {
        HStack(spacing: 10) {
            if isWriterActive {
                Button {
                    storyWriter.cancel()
                } label: {
                    Label("停止生成", systemImage: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.customVoice)
                .controlSize(.small)
                .accessibilityIdentifier("storyKingdom_storyWriterCancel")
            } else {
                Button {
                    startStoryGeneration()
                } label: {
                    Label("生成故事", systemImage: "wand.and.stars")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.customVoice)
                .controlSize(.small)
                .disabled(!canWriteStory)
                .accessibilityIdentifier("storyKingdom_storyWriterGenerate")
            }

            if !storyWriter.streamingText.isEmpty && !isWriterActive {
                Button {
                    storyWriter.reset()
                } label: {
                    Label("清空", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("storyKingdom_storyWriterClear")
            }

            // Live phase indicator with a spinning wand while the writer is
            // loading the model or streaming text.
            if isWriterActive {
                HStack(spacing: 5) {
                    Image(systemName: storyWriter.phase == .loadingModel
                          ? "arrow.down.circle"
                          : "wand.and.stars")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.customVoice)
                        .rotationEffect(
                            reduceMotion ? .zero
                                : .degrees(storyWriter.phase == .loadingModel ? isWriterAnimating ? 360 : 0 : 0)
                        )
                        .appAnimation(
                            reduceMotion || storyWriter.phase != .loadingModel
                                ? nil
                                : .linear(duration: 1.2).repeatForever(autoreverses: false),
                            value: isWriterAnimating
                        )
                        .scaleEffect(
                            storyWriter.phase == .generating && !reduceMotion && isWriterAnimating ? 1.12 : 1.0
                        )
                        .appAnimation(
                            reduceMotion || storyWriter.phase != .generating
                                ? nil
                                : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: isWriterAnimating
                        )
                    Text(writerPhaseLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .onAppear { isWriterAnimating = true }
                .onDisappear { isWriterAnimating = false }
                .accessibilityIdentifier("storyKingdom_storyWriterPhaseIndicator")
            }

            Spacer(minLength: 0)
        }
    }

    private var writerPhaseLabel: String {
        switch storyWriter.phase {
        case .loadingModel: return "加载模型中…"
        case .generating: return "正在创作…"
        case .unloading: return "释放模型…"
        default: return ""
        }
    }

    var storyListPanel: some View {
        StudioSectionCard(
            title: "故事列表",
            iconName: "books.vertical",
            accentColor: AppTheme.customVoice,
            trailingText: readiness.trailingText,
            fillsAvailableHeight: true,
            accessibilityIdentifier: "storyKingdom_storyList"
        ) {
            VStack(alignment: .leading, spacing: LayoutConstants.generationConfigurationRowSpacing) {
                WorkflowReadinessNote(
                    isReady: readiness.isReady,
                    title: readiness.title,
                    detail: readiness.detail,
                    accentColor: AppTheme.customVoice,
                    isBusy: readiness.isBusy,
                    accessibilityIdentifier: "storyKingdom_readiness"
                )

                if voiceSource == .custom && !hasCloneReference {
                    GenerationSetupNotice(
                        message: "导入或录制一段参考声音后即可播放故事。",
                        iconName: "mic.fill",
                        accentColor: AppTheme.customVoice,
                        accessibilityIdentifier: "storyKingdom_needsReference"
                    )
                }

                ForEach(displayedStories) { story in
                    StoryRow(
                        story: story,
                        isActive: activeStoryID == story.id && isGenerationActive,
                        isEnabled: canGenerate || (activeStoryID == story.id && isGenerationActive),
                        accentColor: AppTheme.customVoice,
                        onPlay: { play(story) },
                        onStop: stop
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        )
                    )
                }
                .appAnimation(.easeInOut(duration: 0.3), value: generatedStories.count)

                if let errorMessage = activeErrorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Actions

private extension StoryKingdomView {
    func play(_ story: Story) {
        guard canGenerate else { return }
        activeStoryID = story.id
        switch voiceSource {
        case .builtIn:
            playBuiltIn(story)
        case .custom:
            playCloned(story)
        }
    }

    func playBuiltIn(_ story: Story) {
        var storyDraft = draft
        storyDraft.text = story.text
        // Honor a story's natural language only while the selector is still on
        // Auto — never override an explicit user pick.
        if draft.selectedLanguage == .auto,
           let suggested = story.suggestedLanguage,
           suggested != .auto {
            storyDraft.selectedLanguage = suggested
        }
        coordinator.generate(
            draft: storyDraft,
            activeModel: activeModel,
            isModelAvailable: isModelAvailable,
            ttsEngineStore: ttsEngineStore,
            audioPlayer: audioPlayer,
            modelManager: modelManager
        )
    }

    func playCloned(_ story: Story) {
        // Drive the shared Voice Cloning coordinator off Story Kingdom's local
        // clone draft: the story script becomes the line, language follows the
        // story while the picker is still on Auto.
        cloneDraft.text = story.text
        if cloneDraft.selectedLanguage == .auto,
           let suggested = story.suggestedLanguage,
           suggested != .auto {
            cloneDraft.selectedLanguage = suggested
        }
        cloneCoordinator.generate(
            draft: $cloneDraft,
            cloneModel: activeModel,
            isModelAvailable: isModelAvailable,
            clonePrimingRequestKey: clonePrimingRequestKey,
            selectedVoice: nil,
            ttsEngineStore: ttsEngineStore,
            audioPlayer: audioPlayer,
            modelManager: modelManager
        )
    }

    func stop() {
        coordinator.cancelGeneration(
            ttsEngineStore: ttsEngineStore,
            audioPlayer: audioPlayer
        )
        cloneCoordinator.cancelGeneration(
            ttsEngineStore: ttsEngineStore,
            audioPlayer: audioPlayer
        )
        activeStoryID = nil
    }

    /// Open the saved-voices enroll sheet pre-filled with the current fresh
    /// reference clip so it becomes reusable next session.
    func presentSaveVoiceSheet() {
        guard let path = cloneDraft.referenceAudioPath else { return }
        let suggestedName = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
        savedVoiceSheetConfig = .cloneResult(
            suggestedName: suggestedName,
            audioPath: path,
            transcript: cloneDraft.trimmedReferenceTranscript ?? ""
        )
    }

    /// Restore the persisted saved voice on launch — but never clobber a
    /// reference the user already imported/recorded this session.
    func hydratePersistedSavedVoiceIfNeeded() {
        guard cloneDraft.referenceAudioPath == nil else { return }
        guard !persistedSavedVoiceID.isEmpty else { return }
        guard let voice = savedVoicesViewModel.voices.first(where: { $0.id == persistedSavedVoiceID }) else { return }
        cloneCoordinator.selectSavedVoice(voice, draft: $cloneDraft)
    }

    // MARK: - Story writer

    /// Kicks off a fresh story generation from the selected theme. The writer
    /// loads the text LLM, streams the story, and unloads before TTS reads it.
    func startStoryGeneration() {
        guard let theme = selectedTheme else { return }
        storyWriter.generate(theme: theme)
    }

    /// When the writer finishes (phase flips back to `.idle` with a non-empty
    /// body), commit the streamed story to the in-memory list so it can be read
    /// aloud via the normal TTS path. Failures and cancellations are ignored
    /// here — the partial text stays visible until the user clears it.
    ///
    /// This is the handoff point between the two engines: by the time this
    /// fires, `StoryTextGenerator` has already unloaded the text LLM and called
    /// `Memory.clearCache()`, so the TTS engine is free to allocate.
    ///
    /// The story's title/subtitle come from the model's structured output
    /// (`StoryTextGenerator.lastResult`); only the body is committed as the
    /// read-aloud text. Falls back to the theme label if the model didn't emit
    /// a header.
    func commitGeneratedStoryIfNeeded(phase: StoryTextGenerator.Phase) {
        guard case .idle = phase else { return }
        guard let result = storyWriter.lastResult else { return }
        let body = result.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        let theme = selectedTheme
        generatedStoryCounter += 1
        let story = Story(
            id: "generated-\(generatedStoryCounter)",
            title: result.title,
            subtitle: result.subtitle,
            iconName: theme?.iconName ?? "wand.and.stars",
            text: body,
            suggestedLanguage: theme?.suggestedLanguage
        )
        generatedStories.insert(story, at: 0)

        // Reset the writer surface so the next generation starts clean. The
        // committed story now lives in the list above.
        storyWriter.reset()
    }
}

// MARK: - Story Row

private struct StoryRow: View {
    let story: Story
    let isActive: Bool
    let isEnabled: Bool
    let accentColor: Color
    let onPlay: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: story.iconName)
                .font(.title3)
                .foregroundStyle(accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(story.title)
                    .font(.subheadline.weight(.semibold))
                Text(story.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            playButton
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.inlineFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isActive ? accentColor.opacity(0.4) : AppTheme.inlineStroke.opacity(0.3),
                    lineWidth: isActive ? 1 : 0.75
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storyKingdom_story_\(story.id)")
    }

    @ViewBuilder
    private var playButton: some View {
        if isActive {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(CompactGenerateButtonStyle(baseColor: accentColor))
            .accessibilityLabel("停止")
            .accessibilityIdentifier("storyKingdom_stop_\(story.id)")
        } else {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(CompactGenerateButtonStyle(baseColor: accentColor))
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityLabel("播放")
            .accessibilityIdentifier("storyKingdom_play_\(story.id)")
        }
    }
}

// MARK: - First-play priming overlay

/// A tasteful masked overlay shown while a story is priming (model load + clone
/// conditioning) before the first audio arrives. It fades out the moment the
/// take begins to play, so it only ever covers the cold-start wait the user
/// can't otherwise see. Visibility is reset whenever a new generation starts and
/// cleared once the playback head advances past the buffering point.
private struct StoryPrimingOverlay: View {
    @ObservedObject var progress: AudioPlayerViewModel.PlaybackProgress
    let isGenerating: Bool
    let accentColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Latches true once the playback head moves, so streaming audio hides the
    /// overlay even though `isGenerating` stays true while the take finishes.
    @State private var hasAudioStarted = false
    @State private var isAnimating = false

    private var isVisible: Bool { isGenerating && !hasAudioStarted }

    var body: some View {
        ZStack {
            if isVisible {
                overlayContent
                    .transition(.opacity)
            }
        }
        .appAnimation(.easeInOut(duration: 0.28), value: isVisible)
        .onChange(of: isGenerating) { _, generating in
            // A fresh take: re-arm the overlay until its audio starts.
            if generating { hasAudioStarted = false }
        }
        .onChange(of: progress.currentTime) { _, time in
            if isGenerating, time > 0.05 { hasAudioStarted = true }
        }
    }

    private var overlayContent: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(accentColor.opacity(0.18), lineWidth: 5)
                    .frame(width: 52, height: 52)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(
                        accentColor,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .frame(width: 52, height: 52)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .appAnimation(
                        reduceMotion
                            ? nil
                            : .linear(duration: 1.0).repeatForever(autoreverses: false),
                        value: isAnimating
                    )
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .scaleEffect(isAnimating && !reduceMotion ? 1.08 : 1.0)
                    .appAnimation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: isAnimating
                    )
            }

            VStack(spacing: 5) {
                Text("请稍候，精彩即将继续")
                    .font(.headline.weight(.semibold))
                Text("正在准备声音，首次播放需要一点点时间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accentColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("请稍候，精彩即将继续")
        .accessibilityIdentifier("storyKingdom_primingOverlay")
    }
}

// MARK: - Story Reader (synced "lyrics" view)

/// A music-player-style reader that highlights the story sentence currently
/// being spoken and scrolls it into view as playback advances. Sync is
/// estimate-driven (we have no per-word timestamps from the engine): each
/// sentence is weighted by its estimated spoken duration. While the take is
/// still streaming we advance against those raw estimates (the player's
/// `duration` is only the buffered-so-far total, so it can't be trusted yet);
/// once the finished file is playing we rescale the estimates to the real
/// duration for an accurate finish.
private struct StoryReaderView: View {
    let story: Story
    @ObservedObject var progress: AudioPlayerViewModel.PlaybackProgress
    let accentColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sentences: [String] { StoryScript.sentences(from: story.text) }

    /// Fraction of the take that has actually been heard, taken straight from
    /// the player. This is the real playback head (advances with the audio, not
    /// a fixed clock); during streaming `duration` is the buffered-so-far total
    /// and converges to the true total once generation finishes.
    private var playbackFraction: Double {
        guard progress.duration > 0.5 else { return 0 }
        return min(max(progress.currentTime / progress.duration, 0), 1)
    }

    private var activeIndex: Int {
        StoryScript.activeSentenceIndex(
            sentences: sentences,
            playbackFraction: playbackFraction
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                        sentenceLine(sentence, isActive: index == activeIndex)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 220)
            .onChange(of: activeIndex) { _, newIndex in
                let scroll = { proxy.scrollTo(newIndex, anchor: .center) }
                if reduceMotion {
                    scroll()
                } else {
                    AppLaunchConfiguration.performAnimated(.easeInOut(duration: 0.3), scroll)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storyKingdom_readerText")
    }

    @ViewBuilder
    private func sentenceLine(_ sentence: String, isActive: Bool) -> some View {
        Text(sentence)
            .font(isActive ? .title3.weight(.semibold) : .body)
            .foregroundStyle(isActive ? AnyShapeStyle(accentColor) : AnyShapeStyle(.secondary))
            .opacity(isActive ? 1 : 0.55)
            .appAnimation(.easeInOut(duration: 0.25), value: isActive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Sentence segmentation + sync estimates

/// Splits a story script into sentence-sized "lyric" lines and maps playback
/// time onto them. Kept free of view state so it is trivially testable.
enum StoryScript {
    /// Breaks the text on sentence terminators (Chinese and Latin) and explicit
    /// line breaks, trimming whitespace and dropping empties.
    static func sentences(from text: String) -> [String] {
        var result: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }

        for character in text {
            if character == "\n" {
                flush()
                continue
            }
            current.append(character)
            if "。！？.!?".contains(character) {
                flush()
            }
        }
        flush()
        return result
    }

    /// The index of the sentence that should be highlighted when the take is
    /// `playbackFraction` (0...1) of the way through. We have no per-word
    /// timestamps from the engine, so we approximate by spoken weight: each
    /// sentence's share of the total is its character count, and the fraction —
    /// which is the *real* playback head — is mapped onto that cumulative weight.
    static func activeSentenceIndex(
        sentences: [String],
        playbackFraction: Double
    ) -> Int {
        guard !sentences.isEmpty else { return 0 }
        let weights = sentences.map { Double(spokenWeight(of: $0)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }

        let target = min(max(playbackFraction, 0), 1) * total
        var accumulated: Double = 0
        for (index, weight) in weights.enumerated() {
            accumulated += weight
            // Strictly-greater so a fraction of exactly 1.0 lands on the last line.
            if target < accumulated { return index }
        }
        return sentences.count - 1
    }

    /// Rough count of "spoken" units in a sentence: non-whitespace characters.
    /// Good enough as a relative weight across sentences of the same script.
    private static func spokenWeight(of sentence: String) -> Int {
        sentence.reduce(into: 0) { count, character in
            if !character.isWhitespace { count += 1 }
        }
    }
}
