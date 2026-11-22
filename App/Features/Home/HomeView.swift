import SwiftUI
import ScriberCore
import ScriberShared

/// Home: what Scriber has saved the user, anything still missing from setup, and a mic to try
/// dictation in the app (with a compact engine switch).
struct HomeView: View {
    @Environment(DictationEngine.self) private var engine
    @Environment(SettingsModel.self) private var settings
    @Environment(SetupStatus.self) private var setup
    @Environment(HistoryStore.self) private var history
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var tryArea = TryAreaModel()
    @State private var stats = HomeView.currentStats()
    @State private var keySheet: APIKeySheetItem?
    @State private var showKeyboardSetup = false
    @State private var showMicDenied = false
    /// 轉錄 (file transcription). DEBUG `-ScriberScreen transcribe|transcript` opens it on launch.
    @State private var showTranscribe = DebugLaunch.screen == "transcribe" || DebugLaunch.screen == "transcript"

    var body: some View {
        NavigationStack {
            List {
                setupSection

                Section {
                    SavedTimeCard(stats: stats)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    Button {
                        showTranscribe = true
                    } label: {
                        TranscribeEntryRow()
                    }
                }

                if let trial = tryArea.trials.first {
                    Section {
                        TrialCard(trial: trial, onRetry: retryAction(for: trial)) {
                            withAnimation(.snappy) { tryArea.clear() }
                        }
                    }
                }
            }
            .animation(.snappy, value: tryArea.trials.first?.id)
            .navigationTitle("Scriber")
            .navigationBarTitleDisplayMode(.inline)
            .bottomBar { micBar }
            .apiKeySheet(item: $keySheet)
            .navigationDestination(isPresented: $showKeyboardSetup) { KeyboardSetupView() }
            .navigationDestination(isPresented: $showTranscribe) { TranscribeView() }
            .alert("麥克風權限已關閉", isPresented: $showMicDenied) {
                Button("打開設定") { openURL(SystemSettings.appSettingsURL) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("到「設定」打開 Scriber 的麥克風，才能用說的輸入。")
            }
            .onAppear(perform: refreshStats)
            .onChange(of: engine.phase) { _, phase in
                tryArea.engineDidChange(phase: phase, engine: engine)
                if phase == .done { refreshStats() }
            }
            .onChange(of: engine.lastErrorMessage) { _, message in
                tryArea.engineDidReportError(message, engine: engine)
            }
            // Dictations from the keyboard (either process) land in history: count them too.
            .onChange(of: history.items.first?.id) { _, _ in refreshStats() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshStats() }
            }
        }
    }

    // MARK: Stats

    private static func currentStats() -> UsageStats {
        var stats = UsageStats.load()
        if DebugLaunch.demoData, stats.dictations == 0 {
            stats.dictations = 86
            stats.characters = 12_340
            stats.speakingSeconds = 2_460
        }
        return stats
    }

    private func refreshStats() {
        let latest = Self.currentStats()
        guard latest != stats else { return }
        withAnimation(.snappy) { stats = latest }
    }

    // MARK: Setup

    private struct SetupItem: Identifiable {
        enum Action { case requestMic, openSettings, key(APIKeyKind), keyboard }
        let id: String
        let symbol: String
        let title: String
        let action: Action
    }

    private var setupItems: [SetupItem] {
        if DebugLaunch.demoReady { return [] } // store screenshots (DEBUG only)
        var items: [SetupItem] = []
        switch engine.micPermission {
        case .denied:
            items.append(SetupItem(id: "mic", symbol: "mic.slash.fill", title: String(localized: "打開麥克風權限"),
                                   action: .openSettings))
        case .undetermined:
            items.append(SetupItem(id: "mic", symbol: "mic.fill", title: String(localized: "允許使用麥克風"),
                                   action: .requestMic))
        case .granted:
            break
        }
        if let missing = settings.missingSTTKey {
            let title: String
            if missing == .custom {
                title = String(localized: "完成自訂引擎設定")
            } else if settings.hasAnySTTKey {
                title = String(localized: "\(sttShortName) 需要 \(missing.vendor) 的 key")
            } else {
                title = String(localized: "設定語音辨識的 API key")
            }
            items.append(SetupItem(id: "stt", symbol: "key.fill", title: title, action: .key(missing)))
        }
        if let missing = settings.missingPolishKey {
            items.append(SetupItem(id: "polish", symbol: "wand.and.sparkles",
                                   title: String(localized: "AI 潤飾需要 \(missing.vendor) 的 key"), action: .key(missing)))
        }
        if !setup.isKeyboardAdded {
            items.append(SetupItem(id: "keyboard", symbol: "keyboard.fill", title: String(localized: "加入 Scriber 鍵盤"),
                                   action: .keyboard))
        }
        return items
    }

    @ViewBuilder
    private var setupSection: some View {
        let items = setupItems
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    Button {
                        perform(item.action)
                    } label: {
                        SetupRow(symbol: item.symbol, title: item.title)
                    }
                }
            } header: {
                Text("還差一步")
            }
        }
    }

    private func perform(_ action: SetupItem.Action) {
        switch action {
        case .requestMic:
            Task { _ = await engine.requestMicPermission() }
        case .openSettings:
            openURL(SystemSettings.appSettingsURL)
        case .key(let kind):
            keySheet = APIKeySheetItem(kind: kind)
        case .keyboard:
            showKeyboardSetup = true
        }
    }

    // MARK: Try it

    private func retryAction(for trial: Trial) -> (() -> Void)? {
        guard trial.id == tryArea.trials.first?.id, engine.canRetry, tryArea.state == .idle,
              case .failure = trial.outcome else { return nil }
        return { tryArea.retry(engine: engine) }
    }

    private var micBar: some View {
        VStack(spacing: 12) {
            engineMenu

            HStack(spacing: 0) {
                ZStack {
                    if tryArea.state == .recording {
                        GlyphButton(symbol: "xmark", accessibilityLabel: "取消錄音") {
                            tryArea.cancel(engine: engine)
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)

                MicPill(visual: micVisual, action: micTapped)

                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
            }
            .animation(.snappy, value: tryArea.state)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var micVisual: MicPill.Visual {
        switch tryArea.state {
        case .idle: .idle
        case .recording: .recording
        case .processing: .processing
        }
    }

    private func micTapped() {
        if tryArea.state == .idle, !canRecord() { return }
        tryArea.toggle(engine: engine, settings: settings)
    }

    /// Checks permission and keys before recording; routes the user to the fix if something is missing.
    private func canRecord() -> Bool {
        switch engine.micPermission {
        case .granted:
            break
        case .undetermined:
            Task { _ = await engine.requestMicPermission() }
            return false
        case .denied:
            Haptics.warning()
            showMicDenied = true
            return false
        }
        if let missing = settings.missingSTTKey {
            Haptics.warning()
            keySheet = APIKeySheetItem(kind: missing)
            return false
        }
        return true
    }

    // MARK: Engine switch

    private var sttShortName: String {
        settings.sttProvider == .custom ? settings.customEngineName : settings.sttProvider.shortName
    }

    private var menuSTTKinds: [STTProviderKind] {
        STTProviderKind.builtIn + (settings.isCustomEngineConfigured ? [.custom] : [])
    }

    private var engineMenu: some View {
        Menu {
            Section("語音辨識引擎") {
                ForEach(menuSTTKinds) { kind in
                    Button {
                        selectSTT(kind)
                    } label: {
                        menuLabel(kind == .custom ? settings.customEngineName : kind.displayName,
                                  isOn: settings.sttProvider == kind)
                    }
                }
            }
            Section("AI 潤飾") {
                ForEach(PolishProviderKind.allCases) { kind in
                    Button {
                        selectPolish(kind)
                    } label: {
                        menuLabel(kind.displayName, isOn: settings.polishProvider == kind)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: "\(sttShortName)・\(settings.polishProvider.shortName)")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlass(interactive: true, in: Capsule())
        }
        .menuOrder(.fixed)
        .disabled(tryArea.state != .idle)
        .opacity(tryArea.state == .idle ? 1 : 0.5)
        .accessibilityLabel("辨識引擎與 AI 潤飾")
        .accessibilityValue(Text(verbatim: "\(sttShortName)・\(settings.polishProvider.shortName)"))
    }

    @ViewBuilder
    private func menuLabel(_ title: String, isOn: Bool) -> some View {
        if isOn {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func selectSTT(_ kind: STTProviderKind) {
        settings.sttProvider = kind
        Haptics.tap()
        if !settings.isReady(kind) { keySheet = APIKeySheetItem(kind: kind.requiredKey) }
    }

    private func selectPolish(_ kind: PolishProviderKind) {
        settings.polishProvider = kind
        Haptics.tap()
        if let key = kind.requiredKey, !settings.hasKey(key) { keySheet = APIKeySheetItem(kind: key) }
    }
}

/// A setup step on Home: terracotta icon tile, short title, chevron.
private struct SetupRow: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(Color.primary)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}
