#if DEBUG
import Foundation
import ScriberCore

/// DEBUG-only display state for screenshots of 轉錄 (`-ScriberDemo YES`, with
/// `-ScriberScreen transcribe` or `transcript`). A temporary store and frozen jobs: nothing is
/// decoded, uploaded or saved to the real data.
@MainActor
final class TranscribeDemo {
    static let shared = TranscribeDemo()

    let store: TranscriptStore
    let queue: TranscriptionQueue

    private init() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScriberDemoTranscripts-\(UUID().uuidString)")
        store = TranscriptStore(directory: folder)
        let paragraphs: [TranscriptParagraph] = [
            .init(start: 3, end: 20, speaker: 1, text: "大家好，今天的週會我們先看上週的進度。設計團隊已經把新版首頁的插圖做完了，接下來要請工程這邊排時間串接。"),
            .init(start: 21.6, end: 33, speaker: 2, text: "好的，我們這週會先把 Claude Code 的設定檔整理好，然後把專案部署到 Railway 上面，預計星期四可以給大家測試。"),
            .init(start: 34.4, end: 41, speaker: 1, text: "那資料庫的部分呢？上次提到要搬到 Supabase，現在進行到哪裡了？"),
            .init(start: 42.5, end: 54, speaker: 2, text: "資料表的結構已經建好了，剩下的是把舊的資料匯進去。我估計大概還需要兩天，因為有一些欄位的格式要轉換。"),
            .init(start: 55.8, end: 66, speaker: 1, text: "了解。另外行銷那邊想要在下個月初上線，所以我們最晚月底前要完成所有的測試，大家有沒有問題？"),
            .init(start: 67.4, end: 76, speaker: 2, text: "時間上應該來得及，不過我建議先做一次內部測試，把常見的問題找出來，再請朋友幫忙試用。"),
        ]
        let now = Date()
        store.save(TranscriptRecord(title: "產品週會 11-20", date: now.addingTimeInterval(-2 * 3600), duration: 3753,
                                    engine: .elevenLabsScribe, options: TranscriptionOptions(timestamps: true, speakers: true),
                                    granularity: .word, hasSpeakers: true, paragraphs: paragraphs,
                                    cues: [TranscriptCue(start: 3, end: 6, text: "大家好")], sourceExtension: "m4a"))
        store.save(TranscriptRecord(title: "客戶訪談：王小姐", date: now.addingTimeInterval(-27 * 3600), duration: 38 * 60,
                                    engine: .groqWhisperLarge, options: .init(), granularity: .segment, hasSpeakers: false,
                                    paragraphs: paragraphs.map { var p = $0; p.speaker = nil; return p }, cues: [],
                                    sourceExtension: "mp3"))
        let environment = TranscriptionEnvironment.preview(store: store)
        queue = TranscriptionQueue(previewJobs: [
            .preview(title: "董事會錄音", sourceExtension: "m4a", phase: .transcribing, duration: 2 * 3600 + 5 * 60,
                     segmentsDone: 9, segmentsTotal: 26, fraction: 0.35, paragraphs: Array(paragraphs.prefix(4)),
                     startedAt: now.addingTimeInterval(-140), estimatedRemaining: 330, environment: environment),
            .preview(title: "Podcast EP13", sourceExtension: "mp3", phase: .waiting, duration: 5420, environment: environment),
        ], environment: environment)
    }
}
#endif
