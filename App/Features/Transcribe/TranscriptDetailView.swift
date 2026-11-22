import SwiftUI
import UIKit
import ScriberCore
import ScriberShared

/// One saved transcript: details, the text (selectable), and 拷貝 / 分享 (.txt, .md, .srt) at the
/// bottom. The "…" menu shows or hides timestamps and speakers, renames and deletes.
struct TranscriptDetailView: View {
    let id: UUID
    let store: TranscriptStore
    let queue: TranscriptionQueue

    @Environment(\.dismiss) private var dismiss
    @State private var record: TranscriptRecord?
    @State private var style = TranscriptExport.Style(timestamps: true, speakers: false)
    @State private var files: [TranscriptExport.Format: URL] = [:]
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let record {
                content(record)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(record?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("顯示時間戳", isOn: $style.timestamps)
                    if record?.hasSpeakers == true {
                        Toggle("顯示說話者", isOn: $style.speakers)
                    }
                    Divider()
                    Button("重新命名", systemImage: "pencil") {
                        renameText = record?.title ?? ""
                        renaming = true
                    }
                    Button("刪除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .onAppear(perform: load)
        .onChange(of: store.items) { _, _ in load() }
        .onChange(of: style) { _, _ in writeFiles() }
        .alert("重新命名", isPresented: $renaming) {
            TextField("名稱", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("儲存") { store.rename(id: id, to: renameText) }
        }
        .confirmationDialog("要刪除這份逐字稿嗎？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                store.remove(ids: [id])
                Haptics.tap()
                dismiss()
            }
        }
    }

    private func content(_ record: TranscriptRecord) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(meta(record))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if record.missingCount > 0 { missingNotice(record) }
                ForEach(Array(record.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    ParagraphView(paragraph: paragraph, style: style, longForm: record.duration >= 3600)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .bottomBar {
            HStack(spacing: 12) {
                CopyButton(text: TranscriptExport.plainText(record.paragraphs, style: style, duration: record.duration))
                    .secondaryActionStyle()
                Menu {
                    ForEach(TranscriptExport.Format.allCases) { format in
                        if let url = files[format] {
                            ShareLink(item: url) { Text(format.displayName) }
                        }
                    }
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .primaryActionStyle()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private func missingNotice(_ record: TranscriptRecord) -> some View {
        let job = queue.job(forTranscript: record.id)
        let canRetry = job.map { $0.phase == .done && !$0.failedSegments.isEmpty } ?? false
        return HStack(alignment: .firstTextBaseline) {
            Label(job?.isActive == true ? "正在重試沒有成功的段落…" : "\(record.missingCount) 段沒有轉錄成功",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
            Spacer(minLength: 8)
            if canRetry, let job {
                Button("重試") { queue.retryFailed(job) }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .card(padding: 14, cornerRadius: 16)
    }

    private func meta(_ record: TranscriptRecord) -> String {
        [record.date.formatted(date: .abbreviated, time: .shortened), TranscriptTime.duration(record.duration),
         record.engine.shortName, "\(record.characterCount) 字"].joined(separator: "・")
    }

    private func load() {
        let latest = store.record(id: id)
        guard latest != record else { return }
        if record == nil, let latest { style = TranscriptExport.style(for: latest) }
        record = latest
        writeFiles()
    }

    /// Share sheets need files: one per format, named after the transcript.
    private func writeFiles() {
        guard let record else { return }
        var out: [TranscriptExport.Format: URL] = [:]
        for format in TranscriptExport.Format.allCases {
            if let url = try? TranscriptExport.temporaryFile(record, as: format, style: style) { out[format] = url }
        }
        files = out
    }
}

/// A paragraph: quiet timestamp, bold speaker, selectable text.
private struct ParagraphView: View {
    let paragraph: TranscriptParagraph
    let style: TranscriptExport.Style
    let longForm: Bool

    var body: some View {
        if paragraph.isMissing {
            Text("（\(range)\(TranscriptExport.missingText)）")
                .italic()
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if (style.timestamps && paragraph.start != nil) || (style.speakers && paragraph.speaker != nil) {
                    HStack(spacing: 8) {
                        if style.timestamps, let start = paragraph.start {
                            Text(TranscriptTime.label(start, longForm: longForm))
                                .font(.footnote.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if style.speakers, let speaker = paragraph.speaker {
                            Text("說話者 \(speaker)")
                                .font(.footnote.weight(.semibold))
                        }
                    }
                }
                Text(paragraph.text)
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var range: String {
        guard let start = paragraph.start, let end = paragraph.end else { return "" }
        return "\(TranscriptTime.label(start, longForm: longForm))–\(TranscriptTime.label(end, longForm: longForm)) "
    }
}
