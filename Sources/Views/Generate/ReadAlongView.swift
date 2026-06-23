import QwenVoiceCore
import QwenVoiceNative
import SwiftUI

/// 跟读训练 (Read-Along Training): the system speaks a word/phrase, the child
/// repeats it, on-device Qwen3-ASR recognizes the speech, a pure-Swift judge
/// scores it, and the loop gives feedback + advances. Reuses the TTS engine
/// (built-in speaker or the user's cloned voice) for both the target word and
/// the feedback line, so the whole loop runs locally with no network.
///
/// The view is a thin SwiftUI surface over `ReadAlongCoordinator` (loop logic),
/// `ReadAlongMicCapture` (16 kHz capture + VAD-lite), `Qwen3ASRTranscriber`
/// (recognition), and `ReadAlongPronunciationJudge` (Levenshtein scoring).
struct ReadAlongView: View {
    @ObservedObject private var ttsEngineStore: TTSEngineStore
    private let audioPlayer: AudioPlayerViewModel
    private let modelManager: ModelManagerViewModel
    private let savedVoicesViewModel: SavedVoicesViewModel

    @State private var coordinator = ReadAlongCoordinator()
    @State private var micCapture = ReadAlongMicCapture()
    @State private var transcriber = Qwen3ASRTranscriber()

    /// Read from the environment so the single source of truth for ASR model
    /// state lives in Settings. The read-along screen only *detects* readiness
    /// here and links to Settings if the model isn't installed — it never
    /// starts a download itself.
    @Environment(ASRModelManagerViewModel.self) private var asrModelManager
    @EnvironmentObject private var appCommandRouter: AppCommandRouter

    @AppStorage("readAlong.voiceSource") private var voiceSource: ReadAlongVoiceSource = .builtIn
    @AppStorage("readAlong.speaker") private var builtInSpeakerID: String = TTSModel.defaultSpeaker
    @AppStorage("readAlong.savedVoiceID") private var persistedSavedVoiceID: String = ""
    /// What to call the child in feedback lines. Persisted so it sticks
    /// across sessions; defaults to the neutral "宝贝".
    @AppStorage("readAlong.kidTerm") private var kidTerm: String = "宝贝"

    @State private var selectedCategory: ReadAlongCategory = .animals

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Readiness

    /// The generation mode whose model we drive the loop with. Built-in
    /// voices use the Custom Voice model (`pro_custom`); cloned voices need
    /// the Base/Clone model (`pro_clone`), which is a *different* weight set
    /// — the CustomVoice model's `supportsVoiceClone` is false and it cannot
    /// consume a reference clip. This mirrors StoryKingdomView's
    /// `activeMode` switch.
    private var activeMode: GenerationMode {
        voiceSource == .clone ? .clone : .custom
    }

    /// Both models must be ready: the TTS model (to speak) and the ASR model
    /// (to recognize). The TTS model follows the voice source — built-in
    /// resolves the `.custom` variant, clone resolves the `.clone` variant.
    private var isTTSModelAvailable: Bool {
        guard let model = modelManager.generationActiveVariant(for: activeMode) else { return false }
        return modelManager.isAvailable(model)
    }

    private var isASRModelAvailable: Bool {
        asrModelManager.isAvailable
    }

    private var canStartSession: Bool {
        ttsEngineStore.isReady
            && isTTSModelAvailable
            && isASRModelAvailable
            && !coordinator.isRunning
            && (voiceSource == .builtIn || selectedSavedVoice != nil)
    }

    private var selectedSavedVoice: Voice? {
        guard voiceSource == .clone, !persistedSavedVoiceID.isEmpty else { return nil }
        return savedVoicesViewModel.voices.first { $0.id == persistedSavedVoiceID }
    }

    // MARK: - Init

    init(
        ttsEngineStore: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel,
        modelManager: ModelManagerViewModel,
        savedVoicesViewModel: SavedVoicesViewModel
    ) {
        _ttsEngineStore = ObservedObject(wrappedValue: ttsEngineStore)
        self.audioPlayer = audioPlayer
        self.modelManager = modelManager
        self.savedVoicesViewModel = savedVoicesViewModel
    }

    // MARK: - Body

    var body: some View {
        PageScaffold(
            accessibilityIdentifier: "screen_readAlong",
            fillsViewportHeight: true,
            contentSpacing: LayoutConstants.generationSectionSpacing,
            contentMaxWidth: LayoutConstants.generationContentMaxWidth,
            topPadding: LayoutConstants.generationPageTopPadding,
            bottomPadding: LayoutConstants.generationPageBottomPadding
        ) {
            readinessBanner
            if coordinator.session != nil && coordinator.phase != .idle {
                trainingSurface
                    .layoutPriority(1)
            } else {
                setupSurface
                    .layoutPriority(1)
            }
        }
        .modeGlassTint(AppTheme.customVoice)
        .modeCanvasBackdrop(AppTheme.customVoice)
        .task {
            await savedVoicesViewModel.ensureLoaded(using: ttsEngineStore)
        }
        .onChange(of: ttsEngineStore.isReady) { _, ready in
            guard ready else { return }
            Task { await savedVoicesViewModel.ensureLoaded(using: ttsEngineStore) }
        }
        .onChange(of: voiceSource) { _, _ in syncCoordinatorVoiceSource() }
        .onChange(of: builtInSpeakerID) { _, _ in syncCoordinatorVoiceSource() }
        .onChange(of: persistedSavedVoiceID) { _, _ in syncCoordinatorVoiceSource() }
        .onChange(of: kidTerm) { _, _ in syncCoordinatorVoiceSource() }
        .onAppear { syncCoordinatorVoiceSource() }
    }

    // MARK: - Readiness banner

    @ViewBuilder
    private var readinessBanner: some View {
        if !isTTSModelAvailable || !isASRModelAvailable {
            CompactConfigurationSection(
                title: "准备",
                iconName: "exclamationmark.triangle.fill",
                accentColor: .orange
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if !isTTSModelAvailable {
                        Label(ttsModelMissingMessage, systemImage: "person.wave.2")
                            .font(.callout)
                    }
                    if !isASRModelAvailable {
                        asrNotReadyRow
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The TTS model the loop needs depends on the voice source: built-in
    /// voices need the Custom Voice model, cloned voices need the Clone
    /// (Base) model. The banner names the right one so the user knows which
    /// to download from Settings.
    private var ttsModelMissingMessage: String {
        voiceSource == .clone
            ? "需要下载声音克隆模型才能用克隆声音跟读。"
            : "需要下载语音合成模型才能开始跟读训练。"
    }

    /// Points the user to Settings to download the ASR model. The read-along
    /// screen never starts the download itself — it only detects readiness and
    /// links to the single source of truth in Settings (mirroring how Story
    /// Kingdom points to Settings for the story text model).
    @ViewBuilder
    private var asrNotReadyRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("需要下载语音识别模型才能识别孩子的发音。", systemImage: "waveform")
                .font(.callout)
            Spacer(minLength: 8)
            Button {
                appCommandRouter.navigate(to: .settings)
            } label: {
                Label("去设置", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("readAlong_goToSettingsButton")
        }
    }

    // MARK: - Setup surface (category + voice pick + start)

    private var setupSurface: some View {
        VStack(alignment: .leading, spacing: LayoutConstants.generationSectionSpacing) {
            categoryPickerPanel
            voiceSourcePanel
            startPanel
        }
    }

    private var categoryPickerPanel: some View {
        CompactConfigurationSection(
            title: "选择词包",
            iconName: "square.grid.2x2.fill",
            accentColor: AppTheme.customVoice
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(ReadAlongCategory.allBuiltIn) { category in
                    categoryCard(category)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func categoryCard(_ category: ReadAlongCategory) -> some View {
        let isSelected = selectedCategory.id == category.id
        return Button {
            selectedCategory = category
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: category.icon)
                        .font(.title3)
                        .foregroundStyle(AppTheme.customVoice)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.customVoice)
                    }
                }
                Text(category.title)
                    .font(.headline)
                Text("\(category.words.count) 个词")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                    .fill(isSelected ? AppTheme.customVoice.opacity(0.12) : AppTheme.inlineFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? AppTheme.customVoice.opacity(0.5) : AppTheme.inlineStroke.opacity(0.3),
                        lineWidth: isSelected ? 1.5 : 0.75
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("readAlong_category_\(category.id)")
    }

    private var voiceSourcePanel: some View {
        CompactConfigurationSection(
            title: "声音",
            iconName: "speaker.wave.2.fill",
            accentColor: AppTheme.customVoice
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("声音来源", selection: $voiceSource) {
                    ForEach(ReadAlongVoiceSource.allCases) { source in
                        Text(source.displayTitle).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("readAlong_voiceSourcePicker")

                if voiceSource == .builtIn {
                    builtInSpeakerPicker
                } else {
                    cloneVoicePicker
                }

                kidTermPicker
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var builtInSpeakerPicker: some View {
        HStack {
            Text("说话人")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("说话人", selection: $builtInSpeakerID) {
                ForEach(TTSModel.allSpeakers, id: \.self) { speaker in
                    Text(TTSModel.speakerPickerLabel(for: speaker)).tag(speaker)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            .accessibilityIdentifier("readAlong_speakerPicker")
        }
    }

    @ViewBuilder
    private var cloneVoicePicker: some View {
        if savedVoicesViewModel.voices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("还没有克隆声音。请先在「声音克隆」中导入或录制一段参考音频。", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Text("克隆声音")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("克隆声音", selection: $persistedSavedVoiceID) {
                    Text("不使用").tag("")
                    ForEach(savedVoicesViewModel.voices) { voice in
                        Text(voice.name).tag(voice.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .accessibilityIdentifier("readAlong_cloneVoicePicker")
            }
        }
    }

    /// Lets the parent pick how the feedback addresses the child. The term is
    /// interpolated into the feedback TTS lines ("太棒了,宝贝,你读得真好!").
    private var kidTermPicker: some View {
        HStack {
            Text("称呼")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("称呼", selection: $kidTerm) {
                ForEach(ReadAlongKidTerm.presets, id: \.self) { term in
                    Text(term).tag(term)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            .accessibilityIdentifier("readAlong_kidTermPicker")
        }
    }

    private var startPanel: some View {
        VStack(spacing: 14) {
            Text("点击「开始训练」，系统会依次读出词包里的每个词，孩子跟读后会自动识别并打分。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button {
                startSession()
            } label: {
                Label("开始训练", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canStartSession)
            .accessibilityIdentifier("readAlong_startButton")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Training surface (live loop UI)

    private var trainingSurface: some View {
        VStack(spacing: LayoutConstants.generationSectionSpacing) {
            sessionProgressHeader

            if let session = coordinator.session,
               coordinator.currentWordIndex < session.trials.count {
                let trial = session.trials[coordinator.currentWordIndex]
                wordCard(word: trial.word, attemptCount: trial.attemptCount)
                phaseIndicator
                micMeter
                feedbackBanner
                trainingControls
            } else if coordinator.phase == .sessionComplete {
                completionCard
            }
        }
    }

    private var sessionProgressHeader: some View {
        HStack {
            if let session = coordinator.session {
                Label(session.categoryTitle, systemImage: selectedCategory.icon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(AppTheme.customVoice)
                    Text("\(session.passedCount) / \(session.trials.count)")
                        .monospacedDigit()
                }
                .font(.subheadline)
            }
        }
        .padding(.horizontal, 4)
    }

    private func wordCard(word: ReadAlongWord, attemptCount: Int) -> some View {
        VStack(spacing: 10) {
            Text(word.text)
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            if let phonetic = word.phonetic {
                Text(phonetic)
                    .font(.title3)
                    .foregroundStyle(AppTheme.customVoice)
            }

            HStack(spacing: 6) {
                ForEach(0..<coordinator.maxAttemptsPerWord, id: \.self) { index in
                    Image(systemName: index < attemptCount ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(index < attemptCount ? AppTheme.customVoice : .secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background {
            RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                .fill(AppTheme.inlineFill)
                .overlay {
                    RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                        .strokeBorder(AppTheme.inlineStroke.opacity(0.3), lineWidth: 0.75)
                }
        }
        .accessibilityIdentifier("readAlong_wordCard")
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        let (text, icon, color) = phaseDescription
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(color)
            .accessibilityIdentifier("readAlong_phaseIndicator")
    }

    private var phaseDescription: (String, String, Color) {
        switch coordinator.phase {
        case .idle:
            return ("准备就绪", "checkmark.circle", .secondary)
        case .speakingTarget:
            return ("正在读出词语…", "speaker.wave.2", AppTheme.customVoice)
        case .playingTarget:
            return ("仔细听～", "ear", AppTheme.customVoice)
        case .listening:
            return ("请跟读…", "mic.fill", .red)
        case .recognizing:
            return ("正在识别…", "waveform.badge.magnifyingglass", .orange)
        case .speakingFeedback:
            return ("正在反馈…", "speaker.wave.2", AppTheme.customVoice)
        case .playingFeedback:
            return ("听得好棒呀～", "sparkles", AppTheme.customVoice)
        case .sessionComplete:
            return ("训练完成!", "checkmark.seal.fill", .green)
        case .failed(let message):
            return (message, "exclamationmark.triangle", .red)
        }
    }

    @ViewBuilder
    private var micMeter: some View {
        if coordinator.phase == .listening {
            VStack(spacing: 4) {
                ProgressView(value: Double(coordinator.micLevel))
                    .progressViewStyle(.linear)
                    .tint(AppTheme.customVoice)
                    .frame(maxWidth: 240)
                Text("说话后自动停止")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("readAlong_micMeter")
        }
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let attempt = coordinator.lastAttempt,
           coordinator.phase == .playingFeedback || coordinator.phase == .speakingFeedback {
            HStack(spacing: 12) {
                Text(attempt.verdict.emoji)
                    .font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.lastFeedbackText ?? attempt.verdict.emoji)
                        .font(.headline)
                    if !attempt.recognizedText.isEmpty {
                        Text("听到：\(attempt.recognizedText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(Int(attempt.score * 100))分")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(scoreColor(attempt.score))
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                    .fill(verdictColor(attempt.verdict).opacity(0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                    .strokeBorder(verdictColor(attempt.verdict).opacity(0.4), lineWidth: 1)
            }
            .accessibilityIdentifier("readAlong_feedbackBanner")
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 0.8 { return .green }
        if score >= 0.5 { return .orange }
        return .red
    }

    private func verdictColor(_ verdict: ReadAlongVerdict) -> Color {
        switch verdict {
        case .pass: return .green
        case .close: return .orange
        case .retry: return .red
        }
    }

    private var trainingControls: some View {
        HStack(spacing: 16) {
            Button {
                coordinator.skipCurrentWord()
            } label: {
                Label("跳过", systemImage: "forward.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!coordinator.isRunning)
            .accessibilityIdentifier("readAlong_skipButton")

            Button {
                coordinator.stop()
            } label: {
                Label("结束", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!coordinator.isRunning)
            .accessibilityIdentifier("readAlong_stopButton")
        }
    }

    // MARK: - Completion card

    private var completionCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "star.fill")
                .font(.system(size: 48))
                .foregroundStyle(AppTheme.customVoice)

            Text("训练完成!")
                .font(.largeTitle.bold())

            if let session = coordinator.session {
                HStack(spacing: 30) {
                    statBlock(value: "\(session.passedCount)", label: "通过")
                    statBlock(value: "\(session.totalAttempts)", label: "总次数")
                    statBlock(
                        value: "\(Int((session.trials.map(\.bestScore).max() ?? 0) * 100))",
                        label: "最高分"
                    )
                }

                Text("词包：\(session.categoryTitle)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                coordinator.stop()
            } label: {
                Label("再来一轮", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("readAgain_restartButton")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .background {
            RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                .fill(AppTheme.inlineFill)
                .overlay {
                    RoundedRectangle(cornerRadius: LayoutConstants.cardRadius, style: .continuous)
                        .strokeBorder(AppTheme.customVoice.opacity(0.3), lineWidth: 1)
                }
        }
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title.bold().monospacedDigit())
                .foregroundStyle(AppTheme.customVoice)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func startSession() {
        syncCoordinatorVoiceSource()
        guard let model = modelManager.generationActiveVariant(for: activeMode) else { return }
        coordinator.start(
            category: selectedCategory,
            ttsModel: model,
            ttsEngineStore: ttsEngineStore,
            audioPlayer: audioPlayer,
            transcriber: transcriber,
            micCapture: micCapture
        )
    }

    private func syncCoordinatorVoiceSource() {
        coordinator.voiceSource = voiceSource
        coordinator.builtInSpeakerID = builtInSpeakerID
        coordinator.kidTerm = kidTerm
        if voiceSource == .clone, let voice = selectedSavedVoice {
            coordinator.cloneReference = CloneReference(
                audioPath: voice.wavPath,
                transcript: try? voice.loadTranscript(),
                preparedVoiceID: voice.id
            )
        } else {
            coordinator.cloneReference = nil
        }
    }
}
