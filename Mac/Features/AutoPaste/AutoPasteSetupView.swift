import SwiftUI
import ScriberShared

/// 開啟自動貼上 (optional, any time): what the Accessibility permission adds, an honest note that
/// macOS will ask several times, one button, then live state until it is on.
///
/// States: offer → waiting (after the button; System Settings is open) → on, or 重新開啟 when the
/// permission is granted but the single-key hotkey could not start. As soon as the permission is
/// on, the hotkey monitor switches to the single key by itself; this screen only reflects it.
/// Used as onboarding's last step and in its own window (from 首頁 and 設定).
struct AutoPasteSetupView: View {
    @Binding var requested: Bool

    @Environment(EngineStatus.self) private var status
    @Environment(MacSettings.self) private var settings

    private enum Phase { case offer, waiting, relaunch, done }

    private var phase: Phase {
        if status.needsRelaunch { return .relaunch }
        if status.accessibilityTrusted { return .done }
        return requested ? .waiting : .offer
    }

    var body: some View {
        OnboardingStepPage(title: title, why: phase == .offer || phase == .waiting ? Self.why : nil) {
            SpotIllustration(symbol: phase == .done ? "checkmark" : "text.cursor", size: 96)
        } subtitle: {
            subtitle
        } content: {
            content
        }
        .animation(.smooth(duration: 0.3), value: phase)
    }

    private var title: String {
        switch phase {
        case .offer, .waiting: "開啟自動貼上"
        case .relaunch: "還差一步"
        case .done: "自動貼上已開啟"
        }
    }

    /// The single key's name, with a space before Latin names ("按一下 F5").
    private var triggerName: String {
        let name = settings.hotkey.trigger.displayName
        return name.first?.isASCII == true ? " \(name)" : name
    }

    static let why = "這需要 macOS 的「輔助使用」權限。Scriber 只用它做兩件事：偵測快捷鍵，以及送出 ⌘V 把文字貼上。不會記錄你打的字；隨時可以在「系統設定 › 隱私權與安全性 › 輔助使用」關掉。"

    @ViewBuilder
    private var subtitle: some View {
        switch phase {
        case .offer:
            Text("現在說完要自己按 ⌘V。開啟後：")
        case .waiting:
            Text("在「系統設定」的清單裡打開 Scriber，\n照 macOS 的提示確認。")
        case .relaunch:
            Text("重新開啟 Scriber，單鍵快捷鍵才會生效。")
        case .done:
            HStack(spacing: 6) {
                Text(settings.hotkey.mode == .toggle ? "現在按" : "現在按住")
                KeycapGroup(keycaps: [settings.hotkey.trigger.shortName], large: true)
                Text("說話，說完直接貼上。")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .offer:
            VStack(spacing: 18) {
                benefits
                note
                Button {
                    requested = true
                    status.requestAccessibility()
                } label: {
                    Text("開啟自動貼上")
                }
                .prominentAction()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        case .waiting:
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("等待你在系統設定中打開…")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .card(radius: 12)
                steps
                Button("打開系統設定") { status.openAccessibilitySettings() }
                    .quietAction()
                    .controlSize(.large)
            }
        case .relaunch:
            Button("重新開啟 Scriber") { status.relaunch() }
                .prominentAction()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .done:
            VStack(alignment: .leading, spacing: 10) {
                DoneLine(text: "說完直接貼到游標處")
                DoneLine(text: "按一下\(triggerName) 就能說")
                DoneLine(text: "可以用說話改字")
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 22)
            .card(radius: 16)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            Benefit(symbol: "text.cursor", title: "自動貼上", detail: "說完直接出現在游標處，不用按 ⌘V")
            Benefit(symbol: "keyboard", title: "單鍵觸發",
                    detail: "按一下\(triggerName) 就能說")
            Benefit(symbol: "wand.and.stars", title: "說話改字", detail: "選取文字，用說的改寫")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: 420, alignment: .leading)
        .card(radius: 16)
    }

    private var note: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("macOS 會打開「系統設定」，請你確認好幾次（包括密碼或 Touch\u{00A0}ID）。這是系統的標準流程。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepLine(number: 1, text: "在「輔助使用」清單找到 Scriber")
            StepLine(number: 2, text: "打開開關，用密碼或 Touch ID 確認")
            StepLine(number: 3, text: "看到其他確認視窗，選「允許」")
        }
        .font(.callout)
        .frame(maxWidth: 360, alignment: .leading)
    }
}

/// 自動貼上 in its own window (from 首頁 and 設定): the same screen with a close button.
struct AutoPasteWindowView: View {
    var onClose: () -> Void
    @Environment(EngineStatus.self) private var status
    @State private var requested: Bool

    static let size = CGSize(width: 620, height: 660)

    init(onClose: @escaping () -> Void, requested: Bool = false) {
        self.onClose = onClose
        _requested = State(initialValue: requested)
    }

    var body: some View {
        VStack(spacing: 0) {
            AutoPasteSetupView(requested: $requested)
            HStack {
                Spacer()
                if status.accessibilityTrusted, !status.needsRelaunch {
                    Button("完成", action: onClose)
                        .prominentAction()
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("以後再說", action: onClose)
                        .quietAction()
                        .keyboardShortcut(.cancelAction)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 480, idealWidth: Self.size.width, maxWidth: .infinity,
               minHeight: 440, idealHeight: Self.size.height, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                status.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

private struct Benefit: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StepLine: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accent.opacity(0.15)))
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct DoneLine: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}
