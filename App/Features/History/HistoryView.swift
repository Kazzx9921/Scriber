import SwiftUI
import UIKit
import ScriberCore
import ScriberShared

struct HistoryView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(SettingsModel.self) private var settings

    @State private var search = ""
    @State private var confirmClear = false
    @State private var debugDetail = DebugLaunch.screen == "historyDetail"

    private struct DayGroup: Identifiable {
        let day: Date
        var items: [HistoryItem]
        var id: Date { day }
    }

    private var filtered: [HistoryItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history.items }
        return history.items.filter {
            $0.finalText.localizedCaseInsensitiveContains(query) || $0.rawTranscript.localizedCaseInsensitiveContains(query)
        }
    }

    /// Newest first, grouped by calendar day.
    private var groups: [DayGroup] {
        let calendar = Calendar.current
        var result: [DayGroup] = []
        for item in filtered.sorted(by: { $0.date > $1.date }) {
            let day = calendar.startOfDay(for: item.date)
            if result.last?.day == day {
                result[result.count - 1].items.append(item)
            } else {
                result.append(DayGroup(day: day, items: [item]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if history.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("歷史紀錄")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $debugDetail) {
                if let item = history.items.first { HistoryDetailView(item: item) }
            }
            .toolbar {
                if !history.items.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            confirmClear = true
                        } label: {
                            Label("清除全部", systemImage: "trash")
                        }
                    }
                }
            }
            .confirmationDialog("要清除所有歷史紀錄嗎？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除 \(history.items.count) 筆紀錄", role: .destructive) {
                    withAnimation { history.clear() }
                    Haptics.tap()
                }
            } message: {
                Text("這個動作無法復原。")
            }
        }
    }

    private var list: some View {
        List {
            if !settings.saveHistory {
                Section {
                    HStack {
                        Label("已暫停儲存", systemImage: "pause.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢復") { settings.saveHistory = true }
                            .buttonStyle(.borderless)
                    }
                    .font(.subheadline)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        NavigationLink {
                            HistoryDetailView(item: item)
                        } label: {
                            HistoryRow(item: item)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                withAnimation { history.remove(ids: [item.id]) }
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                copy(item.finalText)
                            } label: {
                                Label("拷貝", systemImage: "doc.on.doc")
                            }
                            .tint(.accentColor)
                        }
                        .contextMenu {
                            Button {
                                copy(item.finalText)
                            } label: {
                                Label("拷貝", systemImage: "doc.on.doc")
                            }
                            Button(role: .destructive) {
                                withAnimation { history.remove(ids: [item.id]) }
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(dayTitle(group.day))
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋紀錄")
        .overlay {
            if groups.isEmpty, !search.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if settings.saveHistory {
                EmptyStateView(symbol: "clock.fill", title: "還沒有紀錄", message: "說過的話會留在這裡，只存在這支手機。")
            } else {
                EmptyStateView(symbol: "pause.fill", title: "已暫停儲存歷史紀錄") {
                    Button {
                        settings.saveHistory = true
                        Haptics.tap()
                    } label: {
                        FullWidthLabel("恢復儲存")
                    }
                    .primaryActionStyle()
                }
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "今天") }
        if calendar.isDateInYesterday(day) { return String(localized: "昨天") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? day.formatted(.dateTime.month().day().weekday(.wide))
            : day.formatted(.dateTime.year().month().day())
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        Haptics.success()
    }
}

private struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.finalText)
                .font(.body)
                .lineLimit(3)
            HStack(spacing: 6) {
                Text(item.date, format: .dateTime.hour().minute())
                if item.mode != .dictate {
                    Text("·")
                    Text("\(Image(systemName: item.mode.symbol)) \(item.mode.displayName)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
