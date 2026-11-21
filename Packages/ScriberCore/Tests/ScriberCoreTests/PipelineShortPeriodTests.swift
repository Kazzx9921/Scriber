import XCTest
@testable import ScriberCore
import ScriberShared

final class PunctuationStylerTests: XCTestCase {
    private func apply(_ s: String, _ rule: PunctuationRule, limit: Int = 20) -> String {
        PunctuationStyler.apply(s, rule: rule, limit: limit)
    }

    // MARK: Drop the final full stop

    func testDropFinalPeriodOnShortText() {
        XCTAssertEqual(apply("好。", .dropFinalPeriod), "好")
        XCTAssertEqual(apply("我到了。", .dropFinalPeriod), "我到了")
        XCTAssertEqual(apply("OK thanks.", .dropFinalPeriod), "OK thanks")
        XCTAssertEqual(apply("好，謝謝。", .dropFinalPeriod), "好，謝謝")
        XCTAssertEqual(apply("明天下午三點在信義區的辦公室開會。", .dropFinalPeriod), "明天下午三點在信義區的辦公室開會") // 16 units
    }

    func testLimitIsRespected() {
        let twenty = String(repeating: "字", count: 20) + "。"
        let twentyOne = String(repeating: "字", count: 21) + "。"
        XCTAssertEqual(apply(twenty, .dropFinalPeriod), String(repeating: "字", count: 20))
        XCTAssertEqual(apply(twentyOne, .dropFinalPeriod), twentyOne)
        XCTAssertEqual(apply(twentyOne, .dropFinalPeriod, limit: 0), String(repeating: "字", count: 21), "0 = any length")
        XCTAssertEqual(apply("一二三四五六七八九十一。", .dropFinalPeriod, limit: 10), "一二三四五六七八九十一。")
    }

    func testDropFinalPeriodLeavesOtherEndings() {
        for s in ["真的嗎？", "太好了！", "嗯...", "好吧…", "好", "。", ""] {
            XCTAssertEqual(apply(s, .dropFinalPeriod), s)
        }
    }

    func testKeepDoesNothing() {
        XCTAssertEqual(apply("好，謝謝。", .keep), "好，謝謝。")
    }

    // MARK: Replace with spaces

    func testSpacesReplaceSentencePunctuation() {
        XCTAssertEqual(apply("好，謝謝。", .spaces), "好 謝謝")
        XCTAssertEqual(apply("今天好累，想睡覺。你呢？", .spaces), "今天好累 想睡覺 你呢")
        XCTAssertEqual(apply("蘋果、香蕉；還有橘子！", .spaces), "蘋果 香蕉 還有橘子")
        XCTAssertEqual(apply("OK, see you tomorrow.", .spaces), "OK see you tomorrow")
        XCTAssertEqual(apply("等等……我想一下。", .spaces), "等等 我想一下")
    }

    func testSpacesKeepLineBreaks() {
        XCTAssertEqual(apply("第一行，內容。\n第二行。", .spaces), "第一行 內容\n第二行")
        XCTAssertEqual(apply("買菜：\n蘋果、香蕉。", .spaces), "買菜\n蘋果 香蕉")
    }

    func testTokensKeepTheirDotsColonsAndCommas() {
        XCTAssertEqual(apply("版本是 3.14，下午 10:30 開會。", .spaces), "版本是 3.14 下午 10:30 開會")
        XCTAssertEqual(apply("總共 1,000 元。", .spaces), "總共 1,000 元")
        XCTAssertEqual(apply("寄到 me@example.com，謝謝。", .spaces), "寄到 me@example.com 謝謝")
        XCTAssertEqual(apply("看 https://example.com/a.b 這頁。", .removeAll), "看 https://example.com/a.b 這頁")
    }

    func testQuotesAndBracketsAreKept() {
        XCTAssertEqual(apply("他說「好」，然後走了。", .spaces), "他說「好」 然後走了")
    }

    // MARK: Remove

    func testRemoveAll() {
        XCTAssertEqual(apply("好，謝謝。", .removeAll), "好謝謝")
        XCTAssertEqual(apply("OK, see you tomorrow.", .removeAll), "OK see you tomorrow")
        XCTAssertEqual(apply("真的嗎？太好了！", .removeAll), "真的嗎太好了")
    }

    func testNeverReturnsEmpty() {
        XCTAssertEqual(apply("。", .removeAll), "。")
        XCTAssertEqual(apply("？！", .spaces), "？！")
    }

    func testIdempotent() {
        for rule in PunctuationRule.allCases {
            let once = apply("今天好累，想睡覺。你呢？", rule)
            XCTAssertEqual(apply(once, rule), once)
        }
    }
}
