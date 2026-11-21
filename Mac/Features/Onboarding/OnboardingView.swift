import SwiftUI
import ScriberCore
import ScriberShared

/// First run, built to get the user dictating within a minute, with the heavy permission last and
/// optional:
///
/// 1. 歡迎 — what Scriber does.
/// 2. 麥克風 — one normal system prompt; moves on by itself once allowed.
/// 3. 語音辨識 — pick a service and paste its key (same rows as 設定).
/// 4. 試一次 — dictate into a field here with the key combination (⌥Space by default), which works
///    without any permission; the result lands in the field (and on the clipboard for ⌘V elsewhere).
/// 5. 自動貼上（選用）— the Accessibility explanation and request (`AutoPasteSetupView`); 以後再說
///    finishes, and the same screen is reachable later from 首頁 and 設定.
///
/// Return triggers the step's main action, Esc goes back. Permission states refresh every second.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, microphone, apiKey, tryIt, autoPaste
    }

    static let size = CGSize(width: 640, height: 620)

    var onFinish: () -> Void

    @Environment(EngineStatus.self) private var status
    @Environment(MacSettings.self) private var settings
    @State private var step: Step
    @State private var forward = true
    @State private var tryText = ""
    @State private var autoPasteRequested = false
    @State private var micRequested = false

    init(initialStep: Step = .welcome, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(for: step)
                    .id(step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(minWidth: 480, idealWidth: Self.size.width, maxWidth: .infinity,
               minHeight: 420, idealHeight: Self.size.height, maxHeight: .infinity)
        .background(alignment: .topLeading) {
            // Esc: back one step.
            Button("上一步", action: back)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .task {
            while !Task.isCancelled {
                status.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onChange(of: status.micPermission) { _, permission in
            // Allowed through our button: move on by itself.
            guard step == .microphone, micRequested, permission == .granted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if step == .microphone { next() }
            }
        }
    }

    // MARK: Navigation

    private var transition: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(to target: Step) {
        forward = target.rawValue > step.rawValue
        withAnimation(.smooth(duration: 0.35)) { step = target }
        DiagLog.log("app", "onboarding step=\(target.rawValue)")
    }

    private func next() {
        if let target = Step(rawValue: step.rawValue + 1) { go(to: target) } else { finish() }
    }

    private func back() {
        if let target = Step(rawValue: step.rawValue - 1) { go(to: target) }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        DiagLog.log("app", "onboarding finished ax=\(status.accessibilityTrusted) mic=\(status.micPermission.rawValue) "
                    + "sttReady=\(settings.isSTTReady)")
        onFinish()
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            PageDots(count: Step.allCases.count, current: step.rawValue)
            HStack {
                if step != .welcome {
                    Button("上一步", action: back)
                        .quietAction()
                }
                Spacer()
                trailingButton
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch step {
        case .welcome:
            Button("開始設定", action: next)
                .prominentAction()
                .keyboardShortcut(.defaultAction)
        case .microphone:
            continueOrSkip(done: status.micPermission == .granted)
        case .apiKey:
            continueOrSkip(done: settings.isSTTReady)
        case .tryIt:
            Button("繼續", action: next)
                .prominentAction()
                .keyboardShortcut(.defaultAction)
        case .autoPaste:
            if status.accessibilityTrusted {
                Button("完成", action: finish)
                    .prominentAction()
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("以後再說", action: finish)
                    .quietAction()
            }
        }
    }

    /// Done: the prominent default 繼續. Not yet: a quiet 略過, so the step's own action stays
    /// the one prominent button (and owns Return).
    @ViewBuilder
    private func continueOrSkip(done: Bool) -> some View {
        if done {
            Button("繼續", action: next)
                .prominentAction()
                .keyboardShortcut(.defaultAction)
        } else {
            Button("略過", action: next)
                .quietAction()
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func page(for step: Step) -> some View {
        switch step {
        case .welcome: welcomePage
        case .microphone: microphonePage
        case .apiKey: apiKeyPage
        case .tryIt: tryPage
        case .autoPaste: AutoPasteSetupView(requested: $autoPasteRequested)
        }
    }

    private var welcomePage: some View {
        OnboardingStepPage(title: "歡迎使用 Scriber") {
            MicDiscArt(size: 148)
        } subtitle: {
            Text("在任何 App 按下快捷鍵說話，\n整理好的繁體中文就出現在游標處。")
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "waveform", text: "說完自動去贅字、加標點")
                FeatureRow(symbol: "character.bubble", text: "道地的繁體中文，中英夾雜也行")
                FeatureRow(symbol: "key", text: "用你自己的 API key，聲音不經過我們")
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 22)
            .frame(maxWidth: 380, alignment: .leading)
            .card(radius: 16)
        }
    }

    private var microphonePage: some View {
        OnboardingStepPage(title: "允許使用麥克風",
                           why: "Scriber 把你說的話錄下來，送到你選的語音辨識服務轉成文字。沒按快捷鍵時不會碰麥克風，錄完的音檔辨識完就刪。") {
            SpotIllustration(symbol: "mic.fill", accent: "wave.3.right", size: 96)
        } subtitle: {
            Text("只在你按下快捷鍵時錄音。")
        } content: {
            switch status.micPermission {
            case .granted:
                DoneChip(text: "已允許")
            case .notDetermined:
                Button {
                    micRequested = true
                    Task { await status.requestMicrophone() }
                } label: {
                    Label("允許麥克風", systemImage: "mic")
                }
                .prominentAction()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            case .denied, .restricted:
                VStack(spacing: 12) {
                    Button("打開系統設定") { status.openMicrophoneSettings() }
                        .prominentAction()
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    Text("麥克風權限被關掉了，在清單裡打開 Scriber")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var apiKeyPage: some View {
        OnboardingStepPage(title: "選擇語音辨識服務",
                           why: "Scriber 沒有自己的伺服器，聲音直接送到你選的服務，費用由服務商向你收取。Scribe v3 最準；Groq 最快也最便宜，同一把 key 還能用 AI 潤飾和翻譯。之後可以在「設定」更換。") {
            SpotIllustration(symbol: "key.fill", size: 96)
        } subtitle: {
            Text("你說的話會直接送到你選的服務辨識。")
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(STTProviderKind.builtIn.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Divider().padding(.leading, 38) }
                    ProviderRow(title: kind.rowTitle, tag: kind.tag, isSelected: settings.sttProvider == kind,
                                keyKind: kind.requiredKey) {
                        settings.sttProvider = kind
                        return !settings.isReady(kind)
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 10)
                }
            }
            .padding(6)
            .frame(maxWidth: 440)
            .card(radius: 16)
        }
    }

    private var tryPage: some View {
        OnboardingStepPage(title: "試一次") {
            SpotIllustration(symbol: "text.bubble.fill", size: 96)
        } subtitle: {
            HotkeyHint(active: status.hotkey.active, mode: settings.hotkey.mode, large: true)
        } content: {
            TryArea(text: $tryText)
                .frame(maxWidth: 460)
        }
    }
}

// MARK: - Scaffold

/// Art, title, one line, an optional 「為什麼？」, then the step's controls — centred vertically in
/// the space above the footer, and scrolling instead of clipping when a step is taller.
struct OnboardingStepPage<Art: View, Subtitle: View, Content: View>: View {
    let title: String
    var why: String?
    @ViewBuilder var art: Art
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var content: Content

    init(title: String, why: String? = nil, @ViewBuilder art: () -> Art, @ViewBuilder subtitle: () -> Subtitle,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.why = why
        self.art = art()
        self.subtitle = subtitle()
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    art
                        .padding(.bottom, 22)
                    Text(title)
                        .font(.system(size: 26, weight: .bold))
                        .multilineTextAlignment(.center)
                    subtitle
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    if let why {
                        InfoButton(why, label: "為什麼？")
                            .font(.callout)
                            .padding(.top, 8)
                    }
                    content
                        .padding(.top, 26)
                }
                .padding(.horizontal, 48)
                .padding(.top, 36)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Step progress: the current step is a wide terracotta capsule, done steps are tinted.
struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Theme.accent : index < current ? Theme.accent.opacity(0.4) : Color.primary.opacity(0.16))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .animation(.smooth(duration: 0.3), value: current)
        .accessibilityElement()
        .accessibilityLabel("第 \(current + 1) 步，共 \(count) 步")
    }
}

private struct FeatureRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
            Spacer(minLength: 0)
        }
    }
}

/// "已允許" with a green check.
struct DoneChip: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(.green)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.green.opacity(0.12)))
    }
}

// MARK: - 試一次

/// A field to dictate into. With the key combination (no Accessibility) the result is filled in
/// here directly — elsewhere it goes to the clipboard for ⌘V; with automatic paste it arrives by
/// paste like in any other app. Shows recording / processing live, and fixes for what is missing.
struct TryArea: View {
    @Binding var text: String

    @Environment(EngineStatus.self) private var status
    @Environment(MacSettings.self) private var settings
    @State private var appearedAt = Date()
    @State private var succeeded = false
    @State private var showRecorder = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                if text.isEmpty {
                    Text("說完的文字會出現在這裡")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 128)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: focused ? 1.5 : 1)
            )
            statusLine
                .font(.callout)
                .frame(minHeight: 24)
        }
        .onAppear {
            appearedAt = Date()
            focused = true
        }
        .onChange(of: status.latestResult) { _, result in
            guard let result, result.date >= appearedAt else { return }
            succeeded = true
            // Without Accessibility nothing is pasted: put the text here ourselves.
            if !status.accessibilityTrusted {
                text += (text.isEmpty ? "" : "\n") + result.text
            }
        }
    }

    /// The quiet link, unless the hotkey is the single key or a problem row already offers 換一組.
    private var showsChangeLink: Bool {
        switch status.hotkey.active {
        case .single: false
        case .unavailable(.comboTaken): status.phase != .idle || status.micPermission != .granted || !settings.isSTTReady
        default: true
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            if status.phase == .recording {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("聆聽中…")
            } else if status.phase == .processing {
                ProgressView().controlSize(.small)
                Text("整理中…")
            } else if status.micPermission != .granted {
                ProblemRow(symbol: "mic.slash", text: "還沒允許麥克風",
                           actionTitle: status.micPermission == .notDetermined ? "允許" : "打開系統設定") {
                    if status.micPermission == .notDetermined {
                        Task { await status.requestMicrophone() }
                    } else {
                        status.openMicrophoneSettings()
                    }
                }
            } else if !settings.isSTTReady {
                ProblemRow(symbol: "key", text: "還沒有語音辨識的 API key，回上一步填入")
            } else if case .unavailable(.comboTaken(let conflict)) = status.hotkey.active {
                ProblemRow(symbol: "exclamationmark.triangle", text: "\(settings.hotkey.combo.displayName) \(conflict.label)",
                           actionTitle: "換一組") { showRecorder = true }
            } else if succeeded {
                Label("成功了", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fontWeight(.semibold)
                if !status.accessibilityTrusted {
                    Text("在其他 App 說完，按 ⌘V 貼上").foregroundStyle(.secondary)
                }
            } else if status.accessibilityTrusted {
                Label("說完會自動貼上", systemImage: "text.cursor").foregroundStyle(.secondary)
            } else {
                Label("在其他 App 說完，按 ⌘V 貼上", systemImage: "doc.on.clipboard").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsChangeLink {
                Button("換快捷鍵") { showRecorder = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accentText)
            }
        }
        .popover(isPresented: $showRecorder, arrowEdge: .bottom) {
            ComboRecorderPopover()
                .environment(settings)
                .environment(status)
        }
    }
}
