import SwiftUI
import ScriberCore
import ScriberShared

struct HistoryDetailView: View {
    let item: HistoryItem

    @Environment(HistoryStore.self) private var history
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                Text(item.finalText)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                CopyButton(text: item.finalText)
            } header: {
                Text(item.mode == .translate ? "翻譯結果" : "最終文字")
            }

            Section {
                Text(item.rawTranscript.isEmpty ? "（空白）" : item.rawTranscript)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                CopyButton(text: item.rawTranscript, title: "拷貝原始逐字稿")
            } header: {
                SectionTitle("原始逐字稿", info: "辨識服務回傳、還沒整理過的文字。")
            }

            Section("細節") {
                LabeledContent("時間", value: item.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("模式", value: item.mode.displayName)
                LabeledContent("辨識引擎", value: item.sttProvider.displayName)
                LabeledContent("AI 潤飾", value: item.polishProvider.displayName)
                LabeledContent("處理時間", value: Format.seconds(millis: item.totalMillis))
            }

            Section {
                Button("刪除這筆紀錄", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(item.date.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: item.finalText)
            }
        }
        .confirmationDialog("要刪除這筆紀錄嗎？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                history.remove(ids: [item.id])
                Haptics.tap()
                dismiss()
            }
        }
    }
}
