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

    /// `-ScriberDemoModes YES`: a custom mode that only copies, a custom prompt, and the keyboard
    /// switched to 翻譯 once (so its recents are not empty). Only when there is no custom mode yet.
    static func seedModes(store: ModeStore, prompts: PromptLibrary) {
        #if DEBUG
        guard !store.modes.contains(where: { !$0.isBuiltIn }) else { return }
        let prompt = try? prompts.add(name: "客服回覆", kind: .dictation,
                                      body: "- 語氣客氣、簡短，先道謝再回答。\n- 不加表情符號。")
        store.add(DictationModeConfig(id: "demo.meeting", name: "會議重點", icon: "list.bullet",
                                      ai: ModeAI(enabled: .custom(true), promptID: BuiltInPromptID.bullets.rawValue),
                                      output: .copyOnly))
        store.add(DictationModeConfig(id: "demo.support", name: "客服", icon: "message",
                                      recognition: ModeRecognition(engine: .custom(.groqWhisperTurbo)),
                                      textFormat: ModeTextFormat(spaceBetweenCJKAndLatin: .custom(false),
                                                                 punctuationRule: .custom(.keep)),
                                      ai: ModeAI(enabled: .custom(true), promptID: prompt?.id)))
        try? store.setEnabled(false, id: BuiltInModeID.assistant.rawValue)
        try? prompts.update(PromptTemplate(id: BuiltInPromptID.email.rawValue, name: "Email",
                                           kind: .dictation, body: PromptLibrary.builtIn(.email).body + "\n- 結尾加一句「謝謝」。"))
        store.noteUsed(id: BuiltInModeID.translate.rawValue)
        #endif
    }

    static var trials: [Trial] {
        #if DEBUG
        let now = Date()
        return [
            // Both finalTexts are what the rule-based path (AI 潤飾 off, default settings) really
            // returns for these transcripts; the first one appears in the Home store screenshot.
            Trial(date: now, outcome: .success(PipelineResult(
                rawTranscript: "嗯，那個，我們明天的 demo，呃，改到下午兩點，一樣在三樓會議室。",
                finalText: "我們明天的 demo，改到下午兩點，一樣在三樓會議室",
                sttMillis: 640, polishMillis: 0,
                sttProvider: .elevenLabsScribe, polishProvider: .off))),
            Trial(date: now.addingTimeInterval(-90), outcome: .success(PipelineResult(
                rawTranscript: "嗯，那个，我们明天的demo，呃，改到下午两点，一样在三楼会议室。",
                finalText: "那個，我們明天的 demo，改到下午兩點，一樣在三樓會議室。",
                sttMillis: 310, polishMillis: 0,
                sttProvider: .groqWhisperTurbo, polishProvider: .off))),
        ]
        #else
        return []
        #endif
    }

    #if DEBUG
    private static let dictionaryEntries: [DictionaryEntry] = [
        // Neutral sample terms only: these show up in store screenshots.
        DictionaryEntry(term: "GitHub", soundsLike: ["get hub", "吉特哈布"]),
        DictionaryEntry(term: "Kubernetes", soundsLike: ["酷伯內提斯"]),
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
