import AppKit
import SwiftUI
import ScriberCore
import ScriberShared

/// One saved transcript inside the 轉錄 page: back, title and details, 拷貝 / 匯出 and a "…" menu
/// (show timestamps / speakers, rename, delete); the text in a selectable, scrollable view.
struct TranscriptDetailView: View {
    let id: UUID
    let store: TranscriptStore
    let queue: TranscriptionQueue
    let onBack: () -> Void

    @State private var record: TranscriptRecord?
    @State private var style = TranscriptExport.Style(timestamps: true, speakers: false)
    @State private var copied = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            if let record {
                header(record)
                if record.missingCount > 0 { missingNotice(record) }
                TranscriptTextView(paragraphs: record.paragraphs, style: style, longForm: record.duration >= 3600)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: load)
        .onChange(of: store.items) { _, _ in load() }
        .alert("重新命名", isPresented: $renaming) {
            TextField("名稱", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("儲存") { store.rename(id: id, to: renameText) }
        }
        .confirmationDialog("刪除這份逐字稿？", isPresented: $confirmDelete) {
            Button("刪除", role: .destructive) {
                store.remove(ids: [id])
                DiagLog.log("transcribe", "transcript deleted")
                onBack()
            }
        } message: {
            Text("這個動作無法復原。")
        }
    }

    private func load() {
        let latest = store.record(id: id)
        if latest != record {
            if record == nil, let latest { style = TranscriptExport.style(for: latest) }
            record = latest
        }
    }

    // MARK: Header

    private func header(_ record: TranscriptRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .keyboardShortcut("[", modifiers: .command)
            .help("回到轉錄（⌘[）")
            .accessibilityLabel("回到轉錄")
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture(count: 2) { startRename(record) }
                Text(meta(record))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button {
                    TranscriptActions.copy(record, style: style)
                    withAnimation(.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.snappy) { copied = false } }
                } label: {
                    Label(copied ? "已拷貝" : "拷貝", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .quietAction()
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("拷貝全文（⇧⌘C）")
                Menu {
                    ForEach(TranscriptExport.Format.allCases) { format in
                        if format != .srt || record.canExportSRT {
                            Button(format.displayName) { TranscriptActions.export(record, as: format, style: style) }
                        }
                    }
                    if !record.canExportSRT {
                        Text("這個引擎沒有時間資訊，無法匯出字幕")
                    }
                } label: {
                    Label("匯出", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.button)
                .quietAction()
                .fixedSize()
                Menu {
                    Toggle("顯示時間戳", isOn: $style.timestamps)
                    if record.hasSpeakers {
                        Toggle("顯示說話者", isOn: $style.speakers)
                    }
                    Divider()
                    Button("重新命名…") { startRename(record) }
                    Button("刪除…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, MainLayout.topInset - 4)
        .padding(.bottom, 12)
    }

    private func missingNotice(_ record: TranscriptRecord) -> some View {
        let job = queue.job(forTranscript: record.id)
        let canRetry = job.map { $0.phase == .done && !$0.failedSegments.isEmpty } ?? false
        let retrying = job.map { $0.isActive } ?? false
        return Group {
            if retrying {
                ProblemRow(symbol: "arrow.clockwise", text: "正在重試沒有成功的段落…")
            } else {
                ProblemRow(symbol: "exclamationmark.triangle.fill", text: "\(record.missingCount) 段沒有轉錄成功",
                           actionTitle: canRetry ? "重試失敗的段落" : nil,
                           action: canRetry ? { if let job { queue.retryFailed(job) } } : nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .card(radius: 12)
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    private func meta(_ record: TranscriptRecord) -> String {
        var parts = [TranscriptListRow.date(record.date), TranscriptTime.duration(record.duration), record.engine.rowTitle]
        parts.append("\(record.characterCount) 字")
        return parts.joined(separator: "・")
    }

    private func startRename(_ record: TranscriptRecord) {
        renameText = record.title
        renaming = true
    }
}

/// Read-only, selectable text for long transcripts (an `NSTextView`: fast with hours of text and
/// selection runs across paragraphs). Timestamps and speaker labels are drawn quieter than the text.
struct TranscriptTextView: NSViewRepresentable {
    let paragraphs: [TranscriptParagraph]
    let style: TranscriptExport.Style
    let longForm: Bool

    final class Coordinator {
        var rendered: (paragraphs: [TranscriptParagraph], style: TranscriptExport.Style)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.isRichText = true
            textView.textContainerInset = NSSize(width: 24, height: 6)
            textView.textContainer?.lineFragmentPadding = 4
            textView.setAccessibilityLabel("逐字稿")
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if let rendered = context.coordinator.rendered, rendered.paragraphs == paragraphs, rendered.style == style { return }
        context.coordinator.rendered = (paragraphs, style)
        textView.textStorage?.setAttributedString(Self.attributed(paragraphs, style: style, longForm: longForm))
    }

    static func attributed(_ paragraphs: [TranscriptParagraph], style: TranscriptExport.Style, longForm: Bool) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 15)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        paragraphStyle.paragraphSpacing = 16
        let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle]
        let quiet: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraphStyle,
        ]
        let speaker: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle,
        ]
        let out = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n", attributes: base)) }
            if paragraph.isMissing {
                var text = TranscriptExport.missingText
                if let start = paragraph.start, let end = paragraph.end {
                    text = "\(TranscriptTime.label(start, longForm: longForm))–\(TranscriptTime.label(end, longForm: longForm)) " + text
                }
                var attributes = quiet
                attributes[.font] = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
                out.append(NSAttributedString(string: "（\(text)）", attributes: attributes))
                continue
            }
            if style.timestamps, let start = paragraph.start {
                out.append(NSAttributedString(string: "[\(TranscriptTime.label(start, longForm: longForm))]  ", attributes: quiet))
            }
            if style.speakers, let label = paragraph.speaker {
                out.append(NSAttributedString(string: "說話者 \(label)：", attributes: speaker))
            }
            out.append(NSAttributedString(string: paragraph.text, attributes: base))
        }
        return out
    }
}
