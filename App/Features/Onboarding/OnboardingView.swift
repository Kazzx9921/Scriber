import SwiftUI
import ScriberShared

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, microphone, apiKey, keyboard, tryIt
    }

    @Environment(SettingsModel.self) private var settings
    @State private var step: Step
    @State private var movingForward = true

    init(initialStep: Int = 0) {
        _step = State(initialValue: Step(rawValue: initialStep) ?? .welcome)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                page(for: step)
                    .id(step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: Navigation

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: movingForward ? .trailing : .leading),
            removal: .move(edge: movingForward ? .leading : .trailing)
        )
        .combined(with: .opacity)
    }

    private func go(to target: Step) {
        movingForward = target.rawValue > step.rawValue
        withAnimation(.smooth(duration: 0.35)) { step = target }
    }

    private func next() {
        if let target = Step(rawValue: step.rawValue + 1) { go(to: target) } else { finish() }
    }

    private func finish() {
        Haptics.success()
        withAnimation(.smooth) { settings.hasCompletedOnboarding = true }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                if let target = Step(rawValue: step.rawValue - 1) { go(to: target) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .opacity(step == .welcome ? 0 : 1)
            .disabled(step == .welcome)
            .accessibilityLabel("上一步")

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color(.systemFill))
                        .frame(height: 4)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: step)
            .accessibilityElement()
            .accessibilityLabel("第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步")

            // Balances the back button so the bar stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func page(for step: Step) -> some View {
        switch step {
        case .welcome: WelcomePage(onContinue: next)
        case .microphone: MicrophonePage(onContinue: next)
        case .apiKey: APIKeyPage(onContinue: next)
        case .keyboard: KeyboardPage(onContinue: next)
        case .tryIt: TryItPage(onFinish: finish)
        }
    }
}

// MARK: - Page scaffold

/// Illustration, title and one short line on top, page content in the middle, actions pinned to
/// the bottom. Longer explanations sit behind an optional "為什麼？".
private struct OnboardingPage<Content: View, Actions: View>: View {
    let symbol: String
    var accent: String?
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    var info: LocalizedStringKey?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SpotIllustration(symbol: symbol, accent: accent, size: 104)
                    .padding(.top, 28)
                    .padding(.bottom, 14)
                Text(title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let info {
                    InfoButton(info, label: "為什麼？")
                        .font(.footnote)
                }
                content
                    .padding(.top, 14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 4) { actions }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(Color(.systemBackground))
        }
    }
}

/// Grouped card on the plain onboarding background.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemBackground)))
    }
}

private struct LaterButton: View {
    let action: () -> Void
    var body: some View {
        Button("稍後再設定", action: action)
            .font(.body)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}

// MARK: - 1. Welcome

private struct WelcomePage: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingPage(symbol: "mic.fill", accent: "wave.3.right", title: "Scriber",
                       message: "在任何 App 用說的打字。") {
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "mic", title: "點一下麥克風就能說")
                FeatureRow(symbol: "wand.and.sparkles", title: "自動去贅字、加標點")
                FeatureRow(symbol: "character.bubble", title: "道地的繁體中文，中英夾雜也行")
                FeatureRow(symbol: "lock.shield", title: "用你自己的 API key")
            }
            .padding(.horizontal, 8)
        } actions: {
            Button(action: onContinue) { FullWidthLabel("開始設定") }
                .primaryActionStyle()
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 2. Microphone

private struct MicrophonePage: View {
    let onContinue: () -> Void
    @Environment(DictationEngine.self) private var engine
    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false

    var body: some View {
        OnboardingPage(symbol: "mic.fill", title: "允許使用麥克風",
                       message: "只用來聽你說話。",
                       info: "錄音只會送到你選的辨識服務，辨識完就刪掉，不會給開發者或其他人。") {
            switch engine.micPermission {
            case .granted:
                Label("已允許", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            case .denied:
                Label("麥克風權限已關閉", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            case .undetermined:
                EmptyView()
            }
        } actions: {
            switch engine.micPermission {
            case .undetermined:
                Button {
                    isRequesting = true
                    Task {
                        let granted = await engine.requestMicPermission()
                        isRequesting = false
                        if granted { onContinue() }
                    }
                } label: {
                    FullWidthLabel("允許麥克風")
                }
                .primaryActionStyle()
                .disabled(isRequesting)
                LaterButton(action: onContinue)
            case .granted:
                Button(action: onContinue) { FullWidthLabel("繼續") }
                    .primaryActionStyle()
            case .denied:
                Button { openURL(SystemSettings.appSettingsURL) } label: { FullWidthLabel("打開設定") }
                    .primaryActionStyle()
                LaterButton(action: onContinue)
            }
        }
        .onAppear { engine.refreshMicPermission() }
    }
}

// MARK: - 3. API key

private struct APIKeyPage: View {
    let onContinue: () -> Void
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        OnboardingPage(symbol: "key.fill", title: "填入 API key",
                       message: "至少需要一組。",
                       info: "Scriber 沒有自己的伺服器，會用你的 key 直接連到辨識服務，費用由服務商向你收取。想用 Claude Haiku 潤飾或自訂引擎，之後可以在「設定」裡加。") {
            VStack(spacing: 12) {
                InlineKeyCard(kind: .elevenLabs, tag: "最準")
                InlineKeyCard(kind: .groq, tag: "最快、最便宜")
            }
        } actions: {
            Button(action: onContinue) { FullWidthLabel("繼續") }
                .primaryActionStyle()
                .disabled(!settings.hasAnySTTKey)
            LaterButton(action: onContinue)
        }
    }
}

/// Compact key entry for onboarding: paste, save (which also checks the key), status, link.
private struct InlineKeyCard: View {
    let kind: APIKeyKind
    let tag: LocalizedStringKey

    @Environment(SettingsModel.self) private var settings
    @State private var draft = ""
    @State private var check: KeyCheck = .idle
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Text(kind.vendor).font(.headline)
                Text(tag)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                Spacer()
                StatusBadge(isOn: settings.hasKey(kind))
                    .font(.subheadline)
            }

            HStack(spacing: 10) {
                SecureField(settings.hasKey(kind) ? "貼上新的 key 來取代" : "貼上 API key", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.tertiarySystemBackground)))
                Button("儲存", action: save)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(trimmed.isEmpty || check == .checking)
            }

            HStack {
                if let url = kind.consoleURL {
                    Link(destination: url) {
                        Label("取得 \(kind.vendor) key", systemImage: "arrow.up.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .font(.subheadline)
                }
                Spacer()
                checkStatus
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var checkStatus: some View {
        switch check {
        case .idle: EmptyView()
        case .checking: ProgressView()
        case .valid: Text("可以使用").foregroundStyle(.green)
        case .invalid(let message): Text(message).foregroundStyle(.red).lineLimit(2).multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        let value = trimmed
        guard !value.isEmpty else { return }
        settings.saveKey(value, for: kind)
        settings.adoptEngineIfNeeded(afterSaving: kind)
        draft = ""
        focused = false
        check = .checking
        Task {
            let message = await settings.validate(kind, draft: value)
            check = message.map(KeyCheck.invalid) ?? .valid
            if message == nil { Haptics.success() } else { Haptics.error() }
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

// MARK: - 4. Keyboard

private struct KeyboardPage: View {
    let onContinue: () -> Void
    @Environment(SetupStatus.self) private var setup
    @Environment(\.openURL) private var openURL

    var body: some View {
        OnboardingPage(symbol: "keyboard.fill", title: "加入 Scriber 鍵盤",
                       message: "在任何 App 都能切換過去用說的。",
                       info: KeyboardSetupCopy.fullAccessBody) {
            Card {
                KeyboardDetectedRow(isAdded: setup.isKeyboardAdded)
                    .font(.headline)
                Divider()
                ForEach(Array(KeyboardSetupCopy.steps.enumerated()), id: \.offset) { index, step in
                    NumberedStep(number: index + 1, text: step)
                }
            }
        } actions: {
            if setup.isKeyboardAdded {
                Button(action: onContinue) { FullWidthLabel("繼續") }
                    .primaryActionStyle()
            } else {
                Button { openURL(SystemSettings.appSettingsURL) } label: { FullWidthLabel("打開設定") }
                    .primaryActionStyle()
                LaterButton(action: onContinue)
            }
        }
        .onAppear { setup.refresh() }
    }
}

// MARK: - 5. Try it

private struct TryItPage: View {
    let onFinish: () -> Void
    @Environment(SetupStatus.self) private var setup
    @Environment(DictationEngine.self) private var engine
    @Environment(SettingsModel.self) private var settings
    @State private var text = ""
    @FocusState private var focused: Bool

    private var flowNote: LocalizedStringKey {
        if engine.effectiveStandbyMode == .off {
            return "在其他 App 按麥克風時，每次都會先跳到 Scriber 開始錄音，點左上角的「◀︎」回去後繼續說。"
        }
        return "在其他 App 第一次按麥克風時，會先跳到 Scriber 開始錄音，點左上角的「◀︎」回去後繼續說。之後 \(settings.standbyMinutes) 分鐘內再按，就能直接說，不用跳過去。"
    }

    var body: some View {
        OnboardingPage(symbol: "text.bubble.fill", title: "試試看",
                       message: setup.isKeyboardAdded
                       ? "點輸入框，按住 \(Image(systemName: "globe")) 切換到 Scriber，點麥克風說話。"
                       : "加入鍵盤後就能在這裡試，也可以在首頁直接說說看。",
                       info: flowNote) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("說點什麼…", text: $text, axis: .vertical)
                    .lineLimit(5...10)
                    .focused($focused)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
                    .onAppear {
                        #if DEBUG
                        // `-ScriberAutoFocus YES`: bring the keyboard up without a tap (simulator checks).
                        if UserDefaults.standard.bool(forKey: "ScriberAutoFocus") { focused = true }
                        #endif
                    }
            }
        } actions: {
            Button(action: onFinish) { FullWidthLabel("完成") }
                .primaryActionStyle()
        }
    }
}
