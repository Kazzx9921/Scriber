import AppKit
import SwiftUI
import XCTest
import ScriberCore
import ScriberShared

/// 轉錄 page renders: empty, drop target, running queue, problems, the transcript reader, small window.
@MainActor
final class TranscribeSnapshotTests: XCTestCase {
    private let mainSize = CGSize(width: WindowManager.mainDefaultSize.width, height: WindowManager.mainDefaultSize.height)
    private let mainSmall = CGSize(width: WindowManager.mainMinimumSize.width, height: WindowManager.mainMinimumSize.height)

    // MARK: Sample data

    private func store(_ records: [TranscriptRecord]) -> TranscriptStore {
        let store = TranscriptStore(directory: Sample.folder.appendingPathComponent("transcripts-\(UUID().uuidString)"))
        for record in records { store.save(record) }
        return store
    }

    private static let meeting: [TranscriptParagraph] = [
        TranscriptParagraph(start: 3, end: 20, speaker: 1, text: "大家好，今天的週會我們先看上週的進度。設計團隊已經把新版首頁的插圖做完了，接下來要請工程這邊排時間串接。"),
        TranscriptParagraph(start: 21.6, end: 33, speaker: 2, text: "好的，我們這週會先把 Claude Code 的設定檔整理好，然後把專案部署到 Railway 上面，預計星期四可以給大家測試。"),
        TranscriptParagraph(start: 34.4, end: 41, speaker: 1, text: "那資料庫的部分呢？上次提到要搬到 Supabase，現在進行到哪裡了？"),
        TranscriptParagraph(start: 42.5, end: 54, speaker: 2, text: "資料表的結構已經建好了，剩下的是把舊的資料匯進去。我估計大概還需要兩天，因為有一些欄位的格式要轉換。"),
        TranscriptParagraph(start: 300, end: 600, text: "", isMissing: true),
        TranscriptParagraph(start: 601.2, end: 640, speaker: 1, text: "了解。另外行銷那邊想要在下個月初上線，所以我們最晚月底前要完成所有的測試，大家有沒有問題？"),
        TranscriptParagraph(start: 641.8, end: 660, speaker: 2, text: "時間上應該來得及，不過我建議先做一次內部測試，把常見的問題找出來，再請朋友幫忙試用。"),
        TranscriptParagraph(start: 662, end: 690, speaker: 1, text: "好，那就這樣決定。最後提醒一下，下週三下午兩點在信義區的辦公室有一場客戶簡報，請大家準時出席。"),
    ]

    private static func record(_ title: String, hoursAgo: Double, duration: TimeInterval, engine: STTProviderKind = .elevenLabsScribe,
                               speakers: Bool = false, paragraphs: [TranscriptParagraph] = meeting, cues: Bool = true) -> TranscriptRecord {
        TranscriptRecord(title: title, date: Date().addingTimeInterval(-hoursAgo * 3600), duration: duration, engine: engine,
                         options: TranscriptionOptions(timestamps: true, speakers: speakers),
                         granularity: cues ? .word : .none, hasSpeakers: speakers,
                         paragraphs: speakers ? paragraphs : paragraphs.map { var p = $0; p.speaker = nil; return p },
                         cues: cues ? [TranscriptCue(start: 3, end: 6, text: "大家好")] : [], sourceExtension: "m4a")
    }

    private var records: [TranscriptRecord] {
        [
            Self.record("產品週會 11-20", hoursAgo: 2, duration: 3753, speakers: true),
            Self.record("客戶訪談：王小姐", hoursAgo: 27, duration: 38 * 60, engine: .groqWhisperLarge,
                        paragraphs: Array(Self.meeting.prefix(4))),
            Self.record("Podcast EP12 設計與工程的距離", hoursAgo: 75, duration: 2 * 3600 + 14 * 60),
            Self.record("線上課程第三講", hoursAgo: 24 * 9, duration: 12 * 60, engine: .custom,
                        paragraphs: Array(Self.meeting.prefix(5)), cues: false),
        ]
    }

    private func queue(_ jobs: (TranscriptionEnvironment) -> [TranscriptionJob], store: TranscriptStore) -> TranscriptionQueue {
        let environment = TranscriptionEnvironment.preview(store: store)
        return TranscriptionQueue(previewJobs: jobs(environment), environment: environment)
    }

    private func runningJobs(_ env: TranscriptionEnvironment, doneID: UUID?) -> [TranscriptionJob] {
        [
            .preview(title: "產品週會錄音", sourceExtension: "m4a", phase: .transcribing, duration: 3753,
                     segmentsDone: 4, segmentsTotal: 13, fraction: 0.31, paragraphs: Array(Self.meeting.prefix(4)),
                     startedAt: Date().addingTimeInterval(-95), estimatedRemaining: 260, environment: env),
            .preview(title: "Podcast EP13", sourceExtension: "mp3", phase: .waiting, duration: 5420, environment: env),
            .preview(title: "簡報錄影", sourceExtension: "mov", phase: .done, duration: 1210, segmentsDone: 5,
                     segmentsTotal: 5, fraction: 1, transcriptID: doneID, environment: env),
        ]
    }

    private func problemJobs(_ env: TranscriptionEnvironment) -> [TranscriptionJob] {
        [
            .preview(title: "董事會 2026Q4", sourceExtension: "mp4", phase: .transcribing, duration: 2 * 3600 + 5 * 60,
                     startedAt: Date().addingTimeInterval(-134), singleRequest: true,
                     options: TranscriptionOptions(timestamps: true, speakers: true), environment: env),
            .preview(title: "訪談 B", sourceExtension: "m4a", phase: .done, duration: 1800, segmentsDone: 6, segmentsTotal: 6,
                     fraction: 1,
                     failedSegments: [TranscriptionJob.previewFailure(index: 2, start: 590, end: 893,
                                                                      message: "服務暫時無法使用（503），請稍後再試")],
                     transcriptID: UUID(), environment: env),
            .preview(title: "研討會 Day 2", sourceExtension: "mp3", phase: .paused, duration: 3 * 3600, segmentsDone: 14,
                     segmentsTotal: 36, fraction: 0.39, environment: env),
            .preview(title: "語音備忘錄", sourceExtension: "m4a", phase: .failed("API key 無效或沒有權限，請到設定檢查"),
                     duration: 420, failureKind: .settings, environment: env),
            .preview(title: "無聲螢幕錄影", sourceExtension: "mov", phase: .failed("這個檔案裡沒有聲音"), duration: nil,
                     failureKind: .file, environment: env),
            .preview(title: "長訪談", sourceExtension: "wav", phase: .transcribing, duration: 4000, segmentsDone: 2,
                     segmentsTotal: 14, fraction: 0.14, startedAt: Date().addingTimeInterval(-40), estimatedRemaining: 900,
                     speakersUnavailable: true, engine: .groqWhisperTurbo, environment: env),
        ]
    }

    private func page(_ section: MainSection = .transcribe, settings: MacSettings? = nil,
                      store: TranscriptStore, queue: TranscriptionQueue) -> some View {
        let settings = settings ?? Sample.settings()
        var data = Sample.sources(history: Sample.history([]), stats: Sample.stats)
        data.transcripts = store
        data.transcriptionQueue = queue
        return mainWindow(section, settings: settings, status: Sample.status(trusted: true), data: data)
    }

    // MARK: Renders

    func testTranscribePage() throws {
        let empty = store([])
        try SnapshotRenderer.renderBoth("14-transcribe-1-empty", size: mainSize) {
            page(store: empty, queue: queue({ _ in [] }, store: empty))
        }
        try SnapshotRenderer.renderBoth("14-transcribe-2-drop-target", size: mainSize) {
            TranscribeView(store: empty, queue: queue({ _ in [] }, store: empty), forceDropTarget: true)
                .environment(Sample.settings())
                .frame(width: mainSize.width - 210)
        }
        let filled = store(records)
        let doneID = filled.items.first?.id
        try SnapshotRenderer.renderBoth("14-transcribe-3-running", size: mainSize) {
            page(store: filled, queue: queue({ runningJobs($0, doneID: doneID) }, store: filled))
        }
        try SnapshotRenderer.renderBoth("14-transcribe-4-problems", size: CGSize(width: mainSize.width, height: 1000)) {
            page(settings: Sample.settings(keys: [.groq]), store: filled, queue: queue(problemJobs, store: filled))
        }
        try SnapshotRenderer.renderBoth("14-transcribe-5-list-only", size: mainSize) {
            page(store: filled, queue: queue({ _ in [] }, store: filled))
        }
        try SnapshotRenderer.renderBoth("14-transcribe-6-small", size: mainSmall) {
            page(store: filled, queue: queue({ runningJobs($0, doneID: doneID) }, store: filled))
        }
        try SnapshotRenderer.renderBoth("14-transcribe-7-groq-options", size: mainSize) {
            page(settings: Sample.settings(stt: .groqWhisperTurbo), store: empty, queue: queue({ _ in [] }, store: empty))
        }
    }

    func testTranscriptReader() throws {
        let filled = store(records)
        let meetingID = try XCTUnwrap(filled.items.first?.id)
        let readerSize = CGSize(width: mainSize.width - 210, height: mainSize.height)
        try SnapshotRenderer.renderBoth("15-transcript-1-speakers", size: readerSize) {
            TranscribeView(store: filled, queue: queue({ _ in [] }, store: filled), initiallyOpen: meetingID)
                .environment(Sample.settings())
        }
        let plainID = try XCTUnwrap(filled.items.last?.id)
        try SnapshotRenderer.renderBoth("15-transcript-2-text-only", size: readerSize) {
            TranscribeView(store: filled, queue: queue({ _ in [] }, store: filled), initiallyOpen: plainID)
                .environment(Sample.settings())
        }
        try SnapshotRenderer.renderBoth("15-transcript-3-small", size: CGSize(width: mainSmall.width - 210, height: mainSmall.height)) {
            TranscribeView(store: filled, queue: queue({ _ in [] }, store: filled), initiallyOpen: meetingID)
                .environment(Sample.settings())
        }
    }

    func testTranscribeRowHover() throws {
        let filled = store(records)
        try SnapshotRenderer.renderBoth("14-transcribe-8-row-hover", size: CGSize(width: 700, height: 120), chrome: false) {
            TranscriptListRow(item: filled.items[0], copied: false, onOpen: {}, onCopy: {}, onExport: { _ in },
                              onRename: {}, onDelete: {})
                .environment(\.forcedHover, true)
                .padding(20)
        }
    }

    func testTranscribeSymbolsExist() {
        let names = ["waveform", "film", "doc.text", "square.and.arrow.up", "chevron.left", "exclamationmark", "checkmark",
                     "xmark", "arrow.clockwise", "key.fill", "exclamationmark.triangle.fill"]
        XCTAssertEqual(names.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }, [])
    }
}
