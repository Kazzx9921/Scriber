import Foundation
import ScriberCore
import ScriberShared

/// Sample content for layout review (DEBUG + `-ScriberDemo YES` only). Never ships as user data.
enum DemoData {
    @MainActor
    static func seed(dictionary: DictionaryStore, history: HistoryStore) {
        #if DEBUG
        if dictionary.entries.isEmpty {
            for entry in dictionaryEntries { dictionary.add(entry) }
        }
        if history.items.isEmpty {
            // Oldest first so a newest-first store ends up in the right order.
            for item in historyItems.sorted(by: { $0.date < $1.date }) { history.add(item) }
        }
        #endif
    }

    static var trials: [Trial] {
        #if DEBUG
        let now = Date()
        return [
            Trial(date: now, outcome: .success(PipelineResult(
                rawTranscript: "嗯那個我明天早上十點要跟 cloud code 的團隊開會 呃 不對 是十一點",
                finalText: "我明天早上 11 點要跟 Claude Code 的團隊開會。",
                sttMillis: 640, polishMillis: 410,
                sttProvider: .elevenLabsScribe, polishProvider: .groq))),
            Trial(date: now.addingTimeInterval(-90), outcome: .success(PipelineResult(
                rawTranscript: "嗯那个我明天早上十点要跟cloud code的团队开会 呃 不对 是十一点",
                finalText: "嗯那個我明天早上十點要跟 cloud code 的團隊開會，呃，不對，是十一點。",
                sttMillis: 310, polishMillis: 0,
                sttProvider: .groqWhisperTurbo, polishProvider: .off))),
        ]
        #else
        return []
        #endif
    }

    #if DEBUG
    private static let dictionaryEntries: [DictionaryEntry] = [
        DictionaryEntry(term: "Claude Code", soundsLike: ["cloud code", "克勞德扣"]),
        DictionaryEntry(term: "科技宅阿高", soundsLike: ["科技摘阿高"]),
        DictionaryEntry(term: "Scriber", soundsLike: ["scraper", "斯克萊伯"]),
        DictionaryEntry(term: "SwiftUI"),
        DictionaryEntry(term: "鹿野", soundsLike: ["路野"]),
    ]

    private static var historyItems: [HistoryItem] {
        let now = Date()
        let day: TimeInterval = 86_400
        return [
            HistoryItem(date: now.addingTimeInterval(-600), mode: .dictate,
                        rawTranscript: "嗯 幫我問他明天有沒有空 那個 下午三點左右",
                        finalText: "幫我問他明天下午三點左右有沒有空。",
                        sttProvider: .elevenLabsScribe, polishProvider: .groq, totalMillis: 1_120),
            HistoryItem(date: now.addingTimeInterval(-3_000), mode: .translate,
                        rawTranscript: "這個 PR 我看過了 沒問題可以 merge",
                        finalText: "I've reviewed this PR. Looks good to merge.",
                        sttProvider: .elevenLabsScribe, polishProvider: .anthropic, totalMillis: 1_480),
            HistoryItem(date: now.addingTimeInterval(-day - 1_800), mode: .dictate,
                        rawTranscript: "今天要做的事 第一 回信 第二 改 deploy 腳本 第三 去郵局",
                        finalText: "今天要做的事：\n1. 回信\n2. 改 deploy 腳本\n3. 去郵局",
                        sttProvider: .groqWhisperLarge, polishProvider: .groq, totalMillis: 890),
            HistoryItem(date: now.addingTimeInterval(-3 * day), mode: .dictate,
                        rawTranscript: "晚餐我想吃鹿野那家的牛肉麵",
                        finalText: "晚餐我想吃鹿野那家的牛肉麵。",
                        sttProvider: .groqWhisperTurbo, polishProvider: .off, totalMillis: 420),
        ]
    }
    #endif
}
