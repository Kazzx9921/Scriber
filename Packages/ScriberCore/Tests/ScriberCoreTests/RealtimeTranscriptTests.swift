import XCTest
@testable import ScriberCore

/// Transcript assembly from partial / committed sequences, the commit planner, and the live text.
final class RealtimeTranscriptTests: XCTestCase {
    // MARK: Assembly

    func testPartialsReplaceAndCommitsAppend() {
        var t = RealtimeTranscript()
        t.applyPartial("我今天")
        t.applyPartial("我今天用 Claude")
        XCTAssertEqual(t.displayText, "我今天用 Claude")
        XCTAssertEqual(t.finalText, "", "partials are never final")
        t.applyCommitted("我今天用 Claude Code。")
        XCTAssertEqual(t.partial, "")
        t.applyPartial("第二段")
        XCTAssertEqual(t.displayText, "我今天用 Claude Code。第二段")
        t.applyCommitted("第二段測試。")
        XCTAssertEqual(t.finalText, "我今天用 Claude Code。第二段測試。")
        XCTAssertEqual(t.commitCount, 2)
    }

    /// The order seen live: a partial for the segment being committed arrives after our commit and
    /// before its committed_transcript, partials can shrink, and the committed text can differ from
    /// the last partial (三点 → 3点). Only committed text is final; nothing is duplicated.
    func testCapturedSequence() {
        var t = RealtimeTranscript()
        for p in ["是。", "我今天", "我今天用佔位。", "我今天用佔位", "我今天用佔位文字三点", "我今天用佔位", "我今天用佔位文字三点在台北。"] {
            t.applyPartial(p)
        }
        // commit sent here; one more partial of the same segment, then the commit lands
        t.applyPartial("我今天用佔位文字三点在台北。")
        t.applyCommitted("我今天用佔位文字3点在台北。")
        XCTAssertEqual(t.displayText, "我今天用佔位文字3点在台北。")
        t.applyPartial("第二段")
        t.applyCommitted("")
        XCTAssertEqual(t.finalText, "我今天用佔位文字3点在台北。", "an empty commit adds nothing")
        XCTAssertEqual(t.commitCount, 2)
        XCTAssertEqual(t.segments.count, 1)
    }

    func testJoinRules() {
        XCTAssertEqual(RealtimeTranscript.join(["中文。", "下一段"]), "中文。下一段")
        XCTAssertEqual(RealtimeTranscript.join(["Hello world.", "Next one"]), "Hello world. Next one")
        XCTAssertEqual(RealtimeTranscript.join(["用 Claude", "Code"]), "用 Claude Code")
        XCTAssertEqual(RealtimeTranscript.join(["中文", "English"]), "中文English", "ZhTW.normalize spaces CJK–Latin later")
        XCTAssertEqual(RealtimeTranscript.join(["English", "中文"]), "English中文")
        XCTAssertEqual(RealtimeTranscript.join(["", "a", ""]), "a")
        XCTAssertEqual(RealtimeTranscript.join(["結束，", "OK"]), "結束，OK")
    }

    // MARK: Commit planner

    private let second = RealtimeSTTWire.bytesPerSecond

    func testPeriodicCommitWaitsForAPauseAfterTwentySeconds() {
        var planner = RealtimeCommitPlanner()
        let chunk = second / 5
        for _ in 0..<99 { XCTAssertFalse(planner.didSend(bytes: chunk, level: 0.6)) } // 19.8 s of speech
        XCTAssertFalse(planner.didSend(bytes: chunk, level: 0.6), "20 s but still speaking")
        XCTAssertFalse(planner.didSend(bytes: chunk, level: 0.5))
        XCTAssertTrue(planner.didSend(bytes: chunk, level: 0.1), "first pause after 20 s")
        planner.didCommit()
        XCTAssertEqual(planner.uncommittedBytes, 0)
    }

    func testCommitIsForcedAtThirtySeconds() {
        var planner = RealtimeCommitPlanner()
        let chunk = second / 5
        var committedAt: Int?
        for i in 1...200 where planner.didSend(bytes: chunk, level: 0.7) {
            committedAt = i
            break
        }
        XCTAssertEqual(committedAt, 150, "30 s at 0.2 s per chunk, well before the server's ~36 s auto-commit")
    }

    func testSilenceAloneIsNeverCommittedEarly() {
        var planner = RealtimeCommitPlanner()
        for _ in 0..<120 { XCTAssertFalse(planner.didSend(bytes: second / 5, level: 0.02)) } // 24 s of silence
    }

    func testFinalAction() {
        var planner = RealtimeCommitPlanner()
        XCTAssertEqual(planner.finalAction(partialIsEmpty: true), .none, "nothing sent since the last commit")

        _ = planner.didSend(bytes: second, level: 0.6)
        XCTAssertEqual(planner.finalAction(partialIsEmpty: false), .commit)

        planner.didCommit()
        _ = planner.didSend(bytes: second / 10, level: 0.6)
        XCTAssertEqual(planner.finalAction(partialIsEmpty: true),
                       .padThenCommit(bytes: RealtimeSTTWire.minimumCommitBytes - second / 10),
                       "the server closes the session on a commit with < 0.3 s of audio")

        planner.didCommit()
        _ = planner.didSend(bytes: second * 2, level: 0.03)
        XCTAssertEqual(planner.finalAction(partialIsEmpty: true), .none,
                       "a silent tail would come back as a hallucinated filler")
        XCTAssertEqual(planner.finalAction(partialIsEmpty: false), .commit, "but not if the server heard something")
    }

    // MARK: Live text

    func testLiveTextIsTraditionalWithTai() {
        let live = RealtimeLiveText(forceTraditional: true)
        XCTAssertTrue(live.apply(.partial("我今天用 Claude Code 写了一个")))
        XCTAssertEqual(live.partial, "我今天用 Claude Code 寫了一個")
        live.apply(.committed("我今天用 Claude Code 写了一个程序，部署到台湾的服务器。"))
        XCTAssertFalse(ZhTW.containsSimplified(live.committed))
        XCTAssertFalse(live.committed.contains("臺"))
        XCTAssertEqual(live.partial, "")
        live.apply(.partial("明天去臺北开会"))
        XCTAssertEqual(live.partial, "明天去台北開會")
        XCTAssertFalse(live.apply(.started), "non-text events change nothing")
    }

    func testLiveTextWithoutConversion() {
        let live = RealtimeLiveText(forceTraditional: false)
        live.apply(.partial("写了一个"))
        XCTAssertEqual(live.partial, "写了一个")
    }

    func testTailKeepsTheEndAndSplitsCommittedFromPartial() {
        let live = RealtimeLiveText(forceTraditional: false)
        live.apply(.committed("Hello world."))
        live.apply(.partial("Next"))
        let tail = live.tail(maxCommittedCharacters: 100)
        XCTAssertEqual(tail.committed, "Hello world.")
        XCTAssertEqual(tail.partial, " Next", "the join's space belongs to the partial part")
    }

    /// Between commits the committed part never changes, whatever the partial does, so the lines on
    /// screen do not re-wrap; it only moves on at segment boundaries.
    func testTailIsStableBetweenCommits() {
        let live = RealtimeLiveText(forceTraditional: false)
        live.apply(.committed("一二三四五六七八九十"))
        live.apply(.committed("甲乙丙丁戊己庚辛"))
        var seen = Set<String>()
        for partial in ["子", "子丑", "子丑寅卯辰巳午未申酉戌亥", "子丑寅"] {
            live.apply(.partial(partial))
            let tail = live.tail(maxCommittedCharacters: 12)
            seen.insert(tail.committed)
            XCTAssertEqual(tail.partial, partial)
        }
        XCTAssertEqual(seen, ["甲乙丙丁戊己庚辛"], "only whole segments that fit the limit")
        live.apply(.committed("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        XCTAssertEqual(live.tail(maxCommittedCharacters: 12).committed, "OPQRSTUVWXYZ",
                       "a segment longer than the limit keeps its fixed-length end")
        XCTAssertEqual(live.tail(maxCommittedCharacters: 12).partial, "")
    }

    /// The conversion runs on every partial on the main thread, so it must stay far below a frame.
    func testLivePreviewIsFastEnoughForEveryPartial() {
        ZhTW.prewarm()
        let partial = String(repeating: "我今天用 Claude Code 写了一个 iOS 的 app，然后把专案部署到 Railway 上面，", count: 5)
        _ = DictationPipeline.livePreview(partial)
        let rounds = 100
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<rounds { _ = DictationPipeline.livePreview(partial) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(rounds)
        print(String(format: "RealtimeLivePreview %d chars: %.3f ms per partial", partial.count, ms))
        XCTAssertLessThan(ms, 8, "debug build; release is several times faster")
    }
}
