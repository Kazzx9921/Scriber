import AppKit
import SwiftUI
import ScriberCore
import ScriberShared

/// Lifetime numbers for the hero (from `UsageStats`, or fixed sample numbers in renders).
struct HomeStats: Equatable {
    var dictations: Int
    var characters: Int
    var speakingSeconds: Double
    var secondsSaved: Double

    init(_ stats: UsageStats) {
        dictations = stats.dictations
        characters = stats.characters
        speakingSeconds = stats.speakingSeconds
        secondsSaved = stats.secondsSaved
    }

    init(dictations: Int, characters: Int, speakingSeconds: Double) {
        self.dictations = dictations
        self.characters = characters
        self.speakingSeconds = speakingSeconds
        secondsSaved = max(0, Double(characters) / UsageStats.typingCharactersPerMinute * 60 - speakingSeconds)
    }

    /// How many times faster than typing (nil until there is enough to say).
    var speedup: Double? {
        guard speakingSeconds >= 5, characters > 0 else { return nil }
        let typing = Double(characters) / UsageStats.typingCharactersPerMinute * 60
        let ratio = typing / speakingSeconds
        return ratio >= 1.2 ? ratio : nil
    }
}

/// 首頁: a greeting with the hotkey, anything still missing from setup, the time-saved hero and
/// the recent transcripts. Fills the window at any size; content caps at a readable width.
struct HomeView: View {
    let history: HistoryStore
    let loadStats: @MainActor () -> HomeStats

    @Environment(EngineStatus.self) private var status
    @Environment(MacSettings.self) private var settings
    @Environment(MainNavigation.self) private var navigation

    @State private var stats: HomeStats?
    @State private var keySheet: KeySheetItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                greeting
                SetupList(keySheet: $keySheet)
                SavedTimeHero(stats: stats ?? loadStats(), active: status.hotkey.active, mode: settings.hotkey.mode)
                RecentTranscripts(history: history)
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, MainLayout.topInset)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear(perform: refreshStats)
        .onChange(of: status.latestResult?.id) { _, _ in refreshStats() }
        .sheet(item: $keySheet) { item in
            KeyEntrySheet(kind: item.kind) { keySheet = nil }
                .environment(settings)
        }
    }

    private func refreshStats() {
        history.reload()
        let latest = loadStats()
        guard latest != stats else { return }
        withAnimation(.snappy) { stats = latest }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.greeting(for: Date()))
                .font(.system(size: 26, weight: .bold))
            HotkeyHint(active: status.hotkey.active, mode: settings.hotkey.mode)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    static func greeting(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<11: return "早安"
        case 11..<18: return "午安"
        default: return "晚安"
        }
    }
}

// MARK: - 還差一步

/// What is still missing, each a row that fixes it. Required steps first; the optional automatic
/// paste comes last and is worded as an upgrade, not a problem.
private struct SetupList: View {
    @Binding var keySheet: KeySheetItem?
    @Environment(EngineStatus.self) private var status
    @Environment(MacSettings.self) private var settings
    @Environment(MainNavigation.self) private var navigation

    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        var detail: String?
        var optional = false
        let action: () -> Void
    }

    private var items: [Item] {
        var items: [Item] = []
        switch status.micPermission {
        case .notDetermined:
            items.append(Item(id: "mic", symbol: "mic.fill", title: "允許使用麥克風") {
                Task { await status.requestMicrophone() }
            })
        case .denied, .restricted:
            items.append(Item(id: "mic", symbol: "mic.slash.fill", title: "打開麥克風權限", detail: "在系統設定裡打開 Scriber") {
                status.openMicrophoneSettings()
            })
        case .granted:
            break
        }
        if !settings.isSTTReady {
            let kind = settings.sttProvider.requiredKey
            let title = kind == .custom ? "完成自訂引擎設定" : "填入語音辨識的 API key"
            items.append(Item(id: "stt", symbol: "key.fill", title: title) {
                keySheet = KeySheetItem(kind: kind)
            })
        }
        if case .unavailable(.comboTaken(let conflict)) = status.hotkey.active {
            items.append(Item(id: "combo", symbol: "command", title: "換一組快捷鍵",
                              detail: "\(settings.hotkey.combo.displayName) \(conflict.label)") {
                navigation.section = .settings
            })
        }
        if status.needsRelaunch {
            items.append(Item(id: "relaunch", symbol: "arrow.clockwise", title: "重新開啟 Scriber",
                              detail: "讓單鍵快捷鍵生效") {
                status.relaunch()
            })
        }
        if let missing = settings.missingPolishKey {
            items.append(Item(id: "polish", symbol: "wand.and.sparkles", title: "AI 潤飾需要 \(settings.vendor(missing)) 的 key") {
                keySheet = KeySheetItem(kind: missing)
            })
        }
        if !status.accessibilityTrusted {
            items.append(Item(id: "autopaste", symbol: "text.cursor", title: "開啟自動貼上",
                              detail: "說完直接出現在游標處", optional: true) {
                WindowManager.shared.showAutoPaste()
            })
        }
        return items
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(items.allSatisfy(\.optional) ? "可以更順手" : "還差一步")
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 52) }
                        Button(action: item.action) {
                            SetupRow(symbol: item.symbol, title: item.title, detail: item.detail, optional: item.optional)
                        }
                        .buttonStyle(RowButtonStyle(verticalPadding: 8, horizontalPadding: 10, cornerRadius: 10))
                    }
                }
                .padding(4)
                .card()
            }
        }
    }
}

private struct SetupRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var optional = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(optional ? Theme.accentText : .white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(optional ? Theme.accent.opacity(0.16) : Theme.accent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if optional {
                Text("選用")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
