import Foundation
import SwiftUI
import ScriberCore
import ScriberShared

/// Injected state for snapshot renders: detached settings (no Keychain or defaults), a sample
/// engine status (no permissions are asked, no hotkey is registered), and stores on temporary
/// files. Nothing here touches the real app's data.
@MainActor
enum Sample {
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scriber-snapshot-data-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: Settings

    static func settings(keys: Set<APIKeyKind> = [.elevenLabs, .groq], stt: STTProviderKind = .elevenLabsScribe,
                         polish: PolishProviderKind = .off, saveHistory: Bool = true,
                         realtime: Bool = false, hotkey: HotkeyConfig = HotkeyConfig()) -> MacSettings {
        var sample = MacSettings.Sample()
        sample.keys = keys
        sample.sttProvider = stt
        sample.polishProvider = polish
        sample.saveHistory = saveHistory
        sample.realtimeEnabled = realtime
        sample.hotkey = hotkey
        return MacSettings(sample: sample)
    }

    // MARK: Engine status

    static func status(mic: MicPermission = .granted, trusted: Bool = false,
                       hotkey: HotkeyRuntimeState? = nil, phase: EngineStatus.Phase = .idle,
                       secureInputOwner: String? = nil) -> EngineStatus {
        let state = hotkey ?? (trusted
            ? HotkeyRuntimeState(active: .single(.rightOption), combo: .off)
            : HotkeyRuntimeState(active: .combo(.optionSpace), combo: .registered))
        return EngineStatus(sample: mic, accessibilityTrusted: trusted, hotkey: state, phase: phase,
                            secureInputOwner: secureInputOwner)
    }

    static let comboTaken = HotkeyRuntimeState(active: .unavailable(.comboTaken(.otherApp)), combo: .taken(.otherApp))

    // MARK: Stores

    static func history(_ items: [HistoryItem]) -> HistoryStore {
        let store = HistoryStore(fileURL: folder.appendingPathComponent("history-\(UUID().uuidString).json"))
        for item in items { store.add(item) }
        return store
    }

    static func dictionary(_ entries: [DictionaryEntry]) -> DictionaryStore {
        let store = DictionaryStore(fileURL: folder.appendingPathComponent("dictionary-\(UUID().uuidString).json"))
        for entry in entries { store.add(entry) }
        return store
    }

    static var historyItems: [HistoryItem] {
        let now = Date()
        func item(_ minutesAgo: Double, _ text: String, mode: DictationMode = .dictate) -> HistoryItem {
            HistoryItem(date: now.addingTimeInterval(-minutesAgo * 60), mode: mode, rawTranscript: text, finalText: text,
                        sttProvider: .elevenLabsScribe, polishProvider: .off, totalMillis: 900)
        }
        return [
            item(0.5, "幫我把下週二的會議改到下午三點，地點一樣在信義區的辦公室。"),
            item(12, "我覺得首頁的卡片可以再大一點，數字要一眼就看得到，下面再放最近說過的話，點一下就能拷貝。"),
            item(48, "Please send the latest build to the QA team before Friday.", mode: .translate),
            item(130, "這段改成比較正式的語氣，並且把重點整理成三點。", mode: .edit),
            item(190, "晚上記得買牛奶和雞蛋，還有幫媽媽拿包裹。"),
            item(60 * 26, "Claude Code 的設定檔要放在專案根目錄，不然它讀不到。"),
            item(60 * 27, "明天早上九點跟設計團隊開會，討論新版首頁的插圖和顏色，順便確認一下上線時間，還有行銷那邊要的素材。"),
            item(60 * 50, "測試一下，這樣聽得到嗎？"),
        ]
    }

    static var dictionaryEntries: [DictionaryEntry] {
        [
            DictionaryEntry(term: "Claude Code", soundsLike: ["cloud code", "克勞德扣"]),
            DictionaryEntry(term: "Scriber", soundsLike: ["scribe er", "斯克萊伯"]),
            DictionaryEntry(term: "科技宅阿高", soundsLike: ["科技摘阿高"]),
            DictionaryEntry(term: "SwiftUI", soundsLike: ["swift ui", "斯威夫特 UI", "swift you i", "swifty", "swift u i"]),
            DictionaryEntry(term: "Liquid Glass", soundsLike: ["liquid class"]),
            DictionaryEntry(term: "TestFlight", soundsLike: []),
            DictionaryEntry(term: "ElevenLabs", soundsLike: ["11 labs", "eleven lab"]),
        ]
    }

    /// About 200 spoken characters a minute, as people really talk.
    static let stats = HomeStats(dictations: 321, characters: 48_620, speakingSeconds: 4 * 3600 + 3 * 60)
    static let noStats = HomeStats(dictations: 0, characters: 0, speakingSeconds: 0)

    static func sources(history: HistoryStore, dictionary: DictionaryStore? = nil, stats: HomeStats) -> MainDataSources {
        var data = MainDataSources(history: history, dictionary: dictionary ?? Self.dictionary([]), loadStats: { stats })
        // The shipped modes and prompts on temporary files (never the app's own).
        data.modes = ModeStore(fileURL: folder.appendingPathComponent("modes-\(UUID().uuidString).json"))
        data.prompts = PromptLibrary(fileURL: folder.appendingPathComponent("prompts-\(UUID().uuidString).json"))
        return data
    }
}

/// The main window with injected state, at a section.
@MainActor
func mainWindow(_ section: MainSection, settings: MacSettings, status: EngineStatus, data: MainDataSources) -> some View {
    let navigation = MainNavigation()
    navigation.section = section
    return MainWindowView(data: data)
        .environment(navigation)
        .environment(status)
        .environment(settings)
}
