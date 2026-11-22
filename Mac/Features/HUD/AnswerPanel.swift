import AppKit
import SwiftUI
import ScriberShared

/// 回答 (docs/PRD-模式.md §4, §7.7): a mode's result shown in a floating panel instead of being typed.
/// Same dark glass and white text as the HUD pill, just above where the pill sits. Showing it never
/// activates Scriber or takes keyboard focus; clicking into it (to select text) makes it the key
/// window without activating the app. Closes with its button or Esc; stays until then (the next
/// answer replaces it). The whole reply is shown at once (no streaming).
@MainActor
@Observable
final class AnswerModel {
    var answer = ""
    /// What the user said (the raw transcript), one or two lines above the answer.
    var question: String?
    var title = ""
    var symbol = "bubble.left.and.text.bubble.right"
    /// The copy button shows a checkmark for a moment.
    var copied = false
    /// Height of the scrolling answer area (`AnswerLayout.bodyHeight`).
    var bodyHeight: CGFloat = 60

    @ObservationIgnored var onCopy: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
}

/// Sizes: the panel has a fixed width; the answer area grows with the text up to a limit, then scrolls.
enum AnswerLayout {
    static let width: CGFloat = 520
    static let padding: CGFloat = 16
    /// Transparent room around the glass for its shadow.
    static let margin: CGFloat = 14
    static let fontSize: CGFloat = 14
    static let lineSpacing: CGFloat = 4
    static let minBodyHeight: CGFloat = 22
    static let maxBodyHeight: CGFloat = 340

    static var textWidth: CGFloat { width - padding * 2 }
    static let headerHeight: CGFloat = 26
    static let spacing: CGFloat = 10
    static let questionFontSize: CGFloat = 12

    /// The panel (glass plus the shadow margin) for an answer area of `bodyHeight`.
    static func panelSize(bodyHeight: CGFloat, question: String?) -> CGSize {
        var height = padding * 2 + headerHeight + spacing + bodyHeight
        if let question, !question.isEmpty {
            height += spacing + questionHeight(question)
        }
        return CGSize(width: width + margin * 2, height: ceil(height) + margin * 2)
    }

    /// One or two lines of the question.
    static func questionHeight(_ question: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: questionFontSize)
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let bounds = NSAttributedString(string: question, attributes: [.font: font])
            .boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(max(ceil(bounds.height), line), line * 2)
    }

    /// The answer's laid-out height at `textWidth`, clamped (a little slack so the last line is never cut).
    static func bodyHeight(for text: String, maxHeight: CGFloat = maxBodyHeight) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraph,
        ])
        let bounds = attributed.boundingRect(with: CGSize(width: textWidth - 2, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(max(ceil(bounds.height) + 4, minBodyHeight), maxHeight)
    }
}

struct AnswerPanelView: View {
    let model: AnswerModel

    var body: some View {
        VStack(alignment: .leading, spacing: AnswerLayout.spacing) {
            header
            if let question = model.question, !question.isEmpty {
                Text(question)
                    .font(.system(size: AnswerLayout.questionFontSize))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("你問的：\(question)")
            }
            ScrollView {
                Text(model.answer)
                    .font(.system(size: AnswerLayout.fontSize))
                    .lineSpacing(AnswerLayout.lineSpacing)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: model.bodyHeight)
        }
        .padding(AnswerLayout.padding)
        .frame(width: AnswerLayout.width)
        .modifier(PillBackground(cornerRadius: 18))
        .padding(AnswerLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onExitCommand { model.onClose?() }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: model.symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                model.onCopy?()
            } label: {
                Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help(model.copied ? "已複製" : "複製")
            .accessibilityLabel(model.copied ? "已複製" : "複製回答")
            Button {
                model.onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("關閉（esc）")
            .accessibilityLabel("關閉")
        }
        .foregroundStyle(.white.opacity(0.82))
        .frame(height: AnswerLayout.headerHeight)
    }
}

/// Floats above other windows on every Space; never activates Scriber. It can become key only when
/// clicked (to select and copy text), never by being shown.
final class AnswerPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Shows and hides the answer panel.
@MainActor
final class AnswerPanelController {
    private let model = AnswerModel()
    private var panel: AnswerPanel?
    private var escapeMonitor: Any?
    private var copiedWork: DispatchWorkItem?
    /// Above the HUD pill (which sits 36 pt over the bottom of the visible frame, 44 pt tall).
    private static let bottomOffset: CGFloat = 36 + 44 + 10

    var isVisible: Bool { panel?.isVisible == true }

    /// `copy`: puts the answer on the clipboard (the controller's plain copy).
    func show(answer: String, question: String?, title: String, symbol: String, copy: @escaping (String) -> Void) {
        model.answer = answer
        model.question = question
        model.title = title
        model.symbol = symbol
        model.copied = false
        copiedWork?.cancel()
        model.onCopy = { [weak self] in
            guard let self else { return }
            copy(self.model.answer)
            self.flashCopied()
        }
        model.onClose = { [weak self] in self?.close() }

        let panel = panel ?? makePanel()
        let screen = FocusInfo.activeScreen()
        let available = (screen?.visibleFrame.height ?? 800) - Self.bottomOffset - 120
        model.bodyHeight = AnswerLayout.bodyHeight(for: answer, maxHeight: min(AnswerLayout.maxBodyHeight, max(120, available * 0.6)))
        let size = AnswerLayout.panelSize(bodyHeight: model.bodyHeight, question: question)
        var origin = NSPoint(x: -size.width / 2, y: 0)
        if let visible = screen?.visibleFrame {
            origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + Self.bottomOffset - AnswerLayout.margin)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        // Never makeKey / activate: the user's app keeps keyboard focus.
        panel.orderFrontRegardless()
        installEscapeMonitor()
    }

    func close() {
        copiedWork?.cancel()
        removeEscapeMonitor()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        DiagLog.log("engine", "answer panel closed")
    }

    private func flashCopied() {
        model.copied = true
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.model.copied = false }
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> AnswerPanel {
        let panel = AnswerPanel()
        let host = FirstMouseHostingView(rootView: AnswerPanelView(model: model))
        // The panel is sized by `AnswerLayout.panelSize`; SwiftUI must not resize it.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.onEscape = { [weak self] in self?.close() }
        self.panel = panel
        return panel
    }

    /// Esc while another app has focus: a passive global monitor (the key still reaches that app).
    /// Needs Accessibility to see keys; without it the close button does it.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == KeyCodes.escape else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
