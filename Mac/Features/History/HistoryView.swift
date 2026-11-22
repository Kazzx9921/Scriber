import AppKit
import SwiftUI
import ScriberCore
import ScriberShared

/// 歷史: newest first, grouped by day, with search. Rows look like 首頁's recent transcripts:
/// click to copy, hover for copy and a menu (raw transcript, delete). Clear all from the "…" menu.
struct HistoryView: View {
    let store: HistoryStore

    @Environment(MacSettings.self) private var settings
    @State private var search = ""
    @State private var confirmClear = false
    @State private var copiedID: UUID?

    static let info = "最多保留 \(HistoryStore.capacity) 筆，只存在這台 Mac。按右鍵可以拷貝原始逐字稿。"

    private var items: [HistoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.items }
        return store.items.filter { $0.finalText.localizedCaseInsensitiveContains(query) }
    }

    /// Items grouped by calendar day, newest day first.
    private var days: [(title: String, items: [HistoryItem])] {
        let calendar = Calendar.current
        var groups: [(Date, [HistoryItem])] = []
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if let last = groups.last, last.0 == day {
                groups[groups.count - 1].1.append(item)
            } else {
                groups.append((day, [item]))
            }
        }
        return groups.map { (Self.dayTitle($0.0), $0.1) }
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            if store.items.isEmpty {
                PageHeader(title: "歷史", info: Self.info)
                if settings.saveHistory {
                    EmptyStateView(symbol: "clock.fill", title: "還沒有紀錄", message: "說過的話會留在這裡，只存在這台 Mac。")
                } else {
                    EmptyStateView(symbol: "pause.fill", title: "已暫停儲存歷史紀錄") {
                        Button("恢復儲存") { settings.saveHistory = true }
                            .prominentAction()
                    }
                }
            } else {
                PageHeader(title: "歷史", subtitle: "\(store.items.count) 筆", info: Self.info) {
                    HStack(spacing: 8) {
                        SearchField(text: $search, width: 200)
                        Menu {
                            Button("清除全部…", role: .destructive) { confirmClear = true }
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
                if !settings.saveHistory {
                    ProblemRow(symbol: "pause.circle.fill", text: "已暫停儲存新的紀錄", actionTitle: "恢復") {
                        settings.saveHistory = true
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .card(radius: 12)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
                }
                if items.isEmpty {
                    ContentUnavailableView.search(text: search)
                        .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
        }
        .onAppear { store.reload() }
        .confirmationDialog("清除 \(store.items.count) 筆紀錄？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                store.clear()
                DiagLog.log("app", "history cleared")
            }
        } message: {
            Text("這個動作無法復原。")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(days, id: \.title) { day in
                    Section {
                        ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 12) }
                            TranscriptRow(item: item, copied: copiedID == item.id, timeText: TimeLabel.clock(item.date),
                                          lineLimit: 3,
                                          onCopy: { copy(item.finalText, id: item.id) },
                                          onCopyRaw: { copy(item.rawTranscript, id: item.id) },
                                          onDelete: { store.remove(ids: [item.id]) })
                        }
                    } header: {
                        Text(day.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func copy(_ text: String, id: UUID) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        withAnimation(.snappy) { copiedID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedID == id { withAnimation(.snappy) { copiedID = nil } }
        }
    }

    static func dayTitle(_ day: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "昨天"
        }
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = parts.weekday.map { "（\(weekdays[($0 - 1) % 7])）" } ?? ""
        let sameYear = calendar.component(.year, from: now) == parts.year
        let date = "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日\(weekday)"
        return sameYear ? date : "\(parts.year ?? 0) 年 \(date)"
    }
}
