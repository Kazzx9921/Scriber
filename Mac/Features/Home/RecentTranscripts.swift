import AppKit
import SwiftUI
import ScriberCore
import ScriberShared

/// 最近: the latest transcripts from `HistoryStore`. Click a row to copy it; hover shows copy and
/// a menu (copy the raw transcript, delete).
struct RecentTranscripts: View {
    let history: HistoryStore
    static let limit = 15

    @Environment(MacSettings.self) private var settings
    @Environment(MainNavigation.self) private var navigation
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近").font(.title3.weight(.bold))
                Spacer()
                if !history.items.isEmpty {
                    Button {
                        navigation.section = .history
                    } label: {
                        HStack(spacing: 3) {
                            Text("全部紀錄")
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accentText)
                }
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let items = Array(history.items.prefix(Self.limit))
        if items.isEmpty {
            placeholder
        } else {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 58) }
                    TranscriptRow(item: item, copied: copiedID == item.id,
                                  onCopy: { copy(item.finalText, id: item.id) },
                                  onCopyRaw: { copy(item.rawTranscript, id: item.id) },
                                  onDelete: { history.remove(ids: [item.id]) })
                }
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        HStack(spacing: 12) {
            Image(systemName: settings.saveHistory ? "text.bubble" : "pause.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(settings.saveHistory ? "說過的話會出現在這裡，點一下就能拷貝" : "沒有儲存歷史紀錄")
                .foregroundStyle(.secondary)
            Spacer()
            if !settings.saveHistory {
                Button("開始儲存") { settings.saveHistory = true }
                    .quietAction()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
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
}

/// One transcript: mode mark, when, two lines of text; hover actions on the right.
struct TranscriptRow: View {
    let item: HistoryItem
    let copied: Bool
    /// Defaults to a relative label ("5 分鐘前").
    var timeText: String?
    var lineLimit = 2
    let onCopy: () -> Void
    let onCopyRaw: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.mode.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent.opacity(0.13)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if copied {
                        Label("已拷貝", systemImage: "checkmark")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    } else {
                        Text(timeText ?? TimeLabel.relative(item.date))
                        if item.mode != .dictate {
                            Text(item.mode.displayName)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Text(item.finalText)
                    .lineLimit(lineLimit)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            actions
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.045 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { menuItems }
        .help("點一下拷貝")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "拷貝", onCopy)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(IconButtonStyle())
            .help("拷貝")
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("拷貝", action: onCopy)
        Button("拷貝原始逐字稿", action: onCopyRaw)
        Divider()
        Button("刪除", role: .destructive, action: onDelete)
    }
}

/// Short zh-Hant time labels: 剛剛, 5 分鐘前, 今天 14:32, 昨天 09:10, 11/20 18:05.
enum TimeLabel {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "剛剛" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分鐘前" }
        let calendar = Calendar.current
        let time = clock(date)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(time)"
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let sameYear = calendar.component(.year, from: now) == parts.year
        let day = "\(parts.month ?? 0)/\(parts.day ?? 0)"
        return sameYear ? "\(day) \(time)" : "\(parts.year ?? 0)/\(day)"
    }

    static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
