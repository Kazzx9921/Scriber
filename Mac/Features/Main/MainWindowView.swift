import SwiftUI
import ScriberCore
import ScriberShared

enum MainSection: String, CaseIterable, Identifiable {
    case home, dictionary, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "首頁"
        case .dictionary: "字典"
        case .history: "歷史"
        case .settings: "設定"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .dictionary: "character.book.closed"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    /// ⌘1 … ⌘4.
    var shortcut: KeyEquivalent {
        switch self {
        case .home: "1"
        case .dictionary: "2"
        case .history: "3"
        case .settings: "4"
        }
    }
}

enum MainLayout {
    /// Where the first content starts, measured from the window's top edge (both columns ignore
    /// the title bar's safe area, whose height differs with and without a toolbar): just under the
    /// traffic lights, the same for the app name in the sidebar and the title of every page.
    static let topInset: CGFloat = 40
}

@MainActor
@Observable
final class MainNavigation {
    var section: MainSection = .home
}

/// Where the main window's pages read their data. The app uses the shared stores; snapshot
/// renders pass stores backed by temporary files and fixed numbers.
struct MainDataSources {
    var history: HistoryStore
    var dictionary: DictionaryStore
    var loadStats: @MainActor () -> HomeStats

    @MainActor static var live: MainDataSources {
        MainDataSources(history: .shared, dictionary: .shared, loadStats: { HomeStats(UsageStats.load()) })
    }
}

/// The main window: a sidebar (首頁 / 字典 / 歷史, 設定 pinned at the bottom) and the page.
/// The title bar is transparent and the sidebar runs under it; there is no toolbar. Both columns
/// start their content `MainLayout.topInset` below the title bar.
struct MainWindowView: View {
    @Environment(MainNavigation.self) private var navigation
    @Environment(EngineStatus.self) private var status
    @Environment(MacSettings.self) private var settings
    var data: MainDataSources = .live

    var body: some View {
        NavigationSplitView {
            MainSidebar(attention: homeNeedsAttention)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch navigation.section {
                case .home: HomeView(history: data.history, loadStats: data.loadStats)
                case .dictionary: DictionaryView(store: data.dictionary)
                case .history: HistoryView(store: data.history)
                case .settings: SettingsView()
                }
            }
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        // No toolbar at all: the title bar keeps its standard height, so the sidebar's first row
        // sits right under the window controls and both columns share the same top inset.
        .toolbar(.hidden, for: .windowToolbar)
    }

    /// Only problems that stop dictation (not the optional automatic paste).
    private var homeNeedsAttention: Bool {
        if status.micPermission == .denied || status.micPermission == .restricted { return true }
        if case .unavailable(.comboTaken) = status.hotkey.active { return true }
        return !settings.isSTTReady
    }
}

struct MainSidebar: View {
    @Environment(MainNavigation.self) private var navigation
    let attention: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            BrandRow()
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            ForEach([MainSection.home, .dictionary, .history]) { section in
                row(section)
            }
            Spacer(minLength: 12)
            row(.settings)
        }
        .padding(.horizontal, 10)
        .padding(.top, MainLayout.topInset)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func row(_ section: MainSection) -> some View {
        SidebarRow(section: section, isSelected: navigation.section == section,
                   showsDot: section == .home && attention) {
            navigation.section = section
        }
    }
}

/// The app's mark and name under the traffic lights.
private struct BrandRow: View {
    var body: some View {
        HStack(spacing: 9) {
            MicDiscArt(size: 26)
            Text("Scriber")
                .font(.system(size: 15, weight: .bold, design: .rounded))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarRow: View {
    let section: MainSection
    let isSelected: Bool
    let showsDot: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .symbolVariant(isSelected ? .fill : .none)
                    .foregroundStyle(isSelected ? Theme.accentText : .secondary)
                    .frame(width: 22)
                Text(section.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if showsDot {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                        .accessibilityLabel("需要處理")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.16) : Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .keyboardShortcut(section.shortcut, modifiers: .command)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("\(section.title)（⌘\(String(section.shortcut.character))）")
    }
}
