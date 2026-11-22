import SwiftUI
import ScriberCore
import ScriberShared

/// 設定 (main window): hotkey and automatic paste first (what decides how dictation feels), then
/// engines and AI polish as Wi-Fi-style rows with their keys on the same row, translation, output,
/// general, permissions, and a short 進階 section at the end. Short labels only; explanations
/// sit behind "?".
///
/// Controls are the standard, neutral ones (pop-ups, a segmented control, bordered buttons);
/// terracotta is only for "on" states and the one primary action of a screen. No tint is applied
/// to the page, so pop-ups and buttons keep the system look.
struct SettingsView: View {
    @Environment(MacSettings.self) private var settings
    @Environment(EngineStatus.self) private var status

    @State private var launchAtLogin = false
    @State private var launchProblem: String?
    @State private var showDiagnostics = false
    @State private var confirmOnboarding = false

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            PageHeader(title: "設定")
            Form {
                // MARK: Hotkey
                Section {
                    HotkeySettingsView()
                } header: {
                    SectionHeader("快捷鍵") {
                        InfoItem(title: "組合鍵", text: "例如 ⌥ Space。不需要任何權限，隨時可用，說完按 ⌘V 貼上。")
                        InfoItem(title: "單鍵", text: "單獨按一下某個鍵，例如右邊的 ⌥、左邊的 ⌃、Fn 或 F5。需要開啟自動貼上；開啟後會自動改用單鍵。")
                        InfoItem(title: "模式", text: "每個模式可以有自己的快捷鍵，在「模式」裡設定。例如先選取文字，按住 ⇧ 再按快捷鍵，用說的改寫選取的文字。")
                        InfoText("錄音時按 esc 取消。")
                    }
                }

                // MARK: Automatic paste
                Section {
                    AutoPasteRow()
                } header: {
                    SectionHeader("自動貼上", info: AutoPasteSetupView.why)
                }

                // MARK: Speech engine
                Section {
                    ForEach(STTProviderKind.builtIn) { kind in
                        ProviderRow(title: kind.rowTitle, tag: kind.tag, isSelected: settings.sttProvider == kind,
                                    keyKind: kind.requiredKey) {
                            settings.sttProvider = kind
                            return !settings.isReady(kind)
                        }
                        if kind == .elevenLabsScribe, settings.sttProvider == .elevenLabsScribe {
                            RealtimeToggleRow()
                        }
                    }
                    CustomEngineRow()
                } header: {
                    SectionHeader("語音辨識") {
                        InfoText("把聲音轉成文字的服務，可以隨時切換。這裡是預設值，模式可以各自改。")
                        ForEach(STTProviderKind.allCases) { kind in
                            InfoItem(title: kind == .custom ? "自訂" : kind.rowTitle, text: kind.tradeoff)
                        }
                    }
                }

                // MARK: Polish
                Section {
                    ForEach(PolishProviderKind.allCases) { kind in
                        ProviderRow(title: kind.displayName, tag: kind.tag, isSelected: settings.polishProvider == kind,
                                    keyKind: kind.requiredKey) {
                            settings.polishProvider = kind
                            return kind.requiredKey.map { !settings.hasKey($0) } ?? false
                        }
                    }
                } header: {
                    SectionHeader("AI 潤飾") {
                        InfoText("去掉口誤和贅字、改口只留最後的說法、整理標點和段落，不改你的意思。")
                        InfoText("「聽寫」模式跟著這裡。翻譯、改寫等模式不用開這個：只要有 Groq 或 Anthropic 的 key 就能用。")
                        ForEach(PolishProviderKind.allCases) { kind in
                            InfoItem(title: kind.displayName, text: kind.detail)
                        }
                    }
                }

                // MARK: Translation
                Section {
                    Picker("翻譯成", selection: $settings.translateLanguageID) {
                        ForEach(TranslateLanguage.all) { language in
                            Text(language.displayName).tag(language.id)
                        }
                    }
                    ForEach(0..<3, id: \.self) { index in
                        Picker("常用語言 \(index + 1)", selection: quickLanguage(at: index)) {
                            ForEach(TranslateLanguage.all) { language in
                                Text(language.displayName).tag(language.id)
                            }
                        }
                    }
                } header: {
                    SectionHeader("翻譯", info: "「翻譯」模式預設翻成這個語言。選單列可以切到翻譯模式，並在三個常用語言之間切換。")
                }

                // MARK: Output
                Section {
                    Toggle("一律輸出繁體中文", isOn: $settings.forceTraditional)
                    Toggle("中英文之間加空格", isOn: $settings.spaceBetweenCJKAndLatin)
                } header: {
                    SectionHeader("輸出", info: "加空格：「我用 Mac 打字」。不加：「我用Mac打字」。這裡是預設值，模式可以各自改。")
                }

                // MARK: Punctuation
                Section {
                    Picker("標點", selection: $settings.punctuationRule) {
                        ForEach(PunctuationRule.allCases) { rule in
                            Text(rule.displayName).tag(rule)
                        }
                    }
                    if settings.punctuationRule != .keep {
                        Picker("套用範圍", selection: $settings.punctuationLimit) {
                            ForEach(AppSettings.punctuationLimitChoices, id: \.self) { limit in
                                Text(PunctuationRule.limitName(limit)).tag(limit)
                            }
                        }
                    }
                } header: {
                    SectionHeader("標點符號", info: PunctuationRule.explanation)
                }

                // MARK: Audio (microphone, cues, mute / pause media while recording)
                AudioSettingsSection(model: status.isLive ? .shared : AudioSettingsModel(sample: .init()))

                // MARK: General
                Section {
                    Toggle("儲存歷史紀錄", isOn: $settings.saveHistory)
                    Toggle("登入時自動開啟", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, wanted in
                            guard status.isLive, wanted != LaunchAtLogin.isEnabled else { return }
                            DiagLog.log("app", "settings launchAtLogin wanted=\(wanted)")
                            launchProblem = LaunchAtLogin.set(wanted)
                            launchAtLogin = LaunchAtLogin.isEnabled || LaunchAtLogin.requiresApproval
                        }
                    if status.isLive, LaunchAtLogin.requiresApproval {
                        ProblemRow(symbol: "exclamationmark.circle.fill", text: "要在系統設定允許", actionTitle: "打開") {
                            LaunchAtLogin.openSystemSettings()
                        }
                    } else if let launchProblem {
                        ProblemRow(symbol: "exclamationmark.circle.fill", text: launchProblem)
                    }
                } header: {
                    Text("一般")
                }

                // MARK: Permissions
                Section {
                    PermissionRows()
                } header: {
                    SectionHeader("權限") {
                        InfoItem(title: "麥克風", text: "錄下你說的話。只在按下快捷鍵之後才會錄音。")
                        InfoItem(title: "輔助使用", text: "自動貼上、單鍵快捷鍵和說話改字會用到。沒有也能用組合鍵聽寫，結果放在剪貼簿。")
                    }
                }

                // MARK: Advanced
                Section {
                    HStack {
                        Toggle("貼上後還原剪貼簿", isOn: $settings.restoreClipboard)
                        InfoButton("Scriber 用剪貼簿把文字貼上，貼完再放回你原本複製的內容。macOS 可能會問是否允許 Scriber 讀取剪貼簿，選「允許」。關掉的話，說完的文字會留在剪貼簿裡。")
                    }
                    LabeledContent("診斷紀錄") {
                        Button("打開…") { showDiagnostics = true }
                    }
                    LabeledContent("首次設定") {
                        Button("重新進行…") { confirmOnboarding = true }
                    }
                    LabeledContent("原始碼") {
                        Link(destination: AppLinks.repository) {
                            HStack(spacing: 4) {
                                Text("GitHub")
                                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                            }
                        }
                        .help(AppLinks.repository.absoluteString)
                    }
                    LabeledContent("版本") {
                        HStack(spacing: 4) {
                            Text(versionText).foregroundStyle(.secondary)
                            InfoButton("Scriber 沒有自己的伺服器。聲音直接從這台 Mac 送到你選的服務。歷史紀錄和字典只存在這台 Mac。")
                        }
                    }
                } header: {
                    Text("進階")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            settings.refreshKeys()
            if status.isLive { launchAtLogin = LaunchAtLogin.isEnabled }
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView { showDiagnostics = false }
                .environment(settings)
        }
        .confirmationDialog("要重新進行首次設定嗎？", isPresented: $confirmOnboarding) {
            Button("重新開始") { WindowManager.shared.showOnboarding() }
        } message: {
            Text("你的 key、字典和設定都會保留。")
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version)（\(build)）"
    }

    private func quickLanguage(at index: Int) -> Binding<String> {
        Binding(
            get: {
                let ids = settings.translateQuickLanguageIDs
                return ids.indices.contains(index) ? ids[index] : ""
            },
            set: { settings.setQuickLanguage($0, at: index) }
        )
    }
}

/// 自動貼上: a quiet status, and a button only when there is something to do.
private struct AutoPasteRow: View {
    @Environment(EngineStatus.self) private var status

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                StatusBadge(isOn: status.accessibilityTrusted, onText: "已開啟", offText: "未開啟")
                if status.needsRelaunch {
                    Button("重新開啟 Scriber") { status.relaunch() }
                        .buttonStyle(.bordered)
                } else if !status.accessibilityTrusted {
                    Button("開啟…") { WindowManager.shared.showAutoPaste() }
                        .buttonStyle(.bordered)
                }
            }
        } label: {
            RowTitle("說完直接貼到游標處",
                     caption: status.needsRelaunch ? "單鍵快捷鍵還沒生效" : status.accessibilityTrusted ? nil : "現在要自己按 ⌘V",
                     captionIsProblem: status.needsRelaunch)
        }
    }
}

/// 即時顯示文字 under Scribe v3 (the only engine with a real-time model).
struct RealtimeToggleRow: View {
    @Environment(MacSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Toggle(isOn: $settings.realtimeEnabled) {
            HStack(spacing: 4) {
                Text("即時顯示文字")
                InfoButton {
                    InfoText("邊說邊顯示辨識出的文字。")
                    InfoText("會改用 ElevenLabs 的即時模型，計價跟一般辨識略有不同。")
                }
            }
        }
        .padding(.leading, 26)
    }
}

/// Microphone and Accessibility: a quiet status and, only when something needs doing, the one
/// button that does it. Secure input shows as a short line under 輔助使用.
struct PermissionRows: View {
    @Environment(EngineStatus.self) private var status

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                switch status.micPermission {
                case .granted:
                    StatusBadge(isOn: true, onText: "已允許")
                case .notDetermined:
                    StatusBadge(isOn: false, offText: "還沒問過")
                    Button("允許") {
                        Task { await status.requestMicrophone() }
                    }
                    .buttonStyle(.bordered)
                case .denied, .restricted:
                    StatusBadge(isOn: false, offText: "未允許", attention: true)
                    Button("打開系統設定") { status.openMicrophoneSettings() }
                        .buttonStyle(.bordered)
                }
            }
        } label: {
            RowTitle("麥克風")
        }

        LabeledContent {
            StatusBadge(isOn: status.accessibilityTrusted, onText: "已允許", offText: "未允許")
        } label: {
            RowTitle("輔助使用",
                     caption: status.secureInputOwner.map { "\($0.isEmpty ? "某個 App" : $0)正在使用安全輸入，快捷鍵暫停" },
                     captionIsProblem: status.secureInputOwner != nil)
        }
    }
}
