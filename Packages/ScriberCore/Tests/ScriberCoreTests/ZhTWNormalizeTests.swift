import XCTest
@testable import ScriberCore

final class ZhTWNormalizeTests: XCTestCase {
    private func spaced(_ text: String) -> String { ZhTW.normalize(text, spaceBetweenCJKAndLatin: true) }
    private func tight(_ text: String) -> String { ZhTW.normalize(text, spaceBetweenCJKAndLatin: false) }

    func testPunctuationNextToCJK() {
        XCTAssertEqual(spaced("你好,我是阿高."), "你好，我是阿高。")
        XCTAssertEqual(spaced("真的嗎?太好了!"), "真的嗎？太好了！")
        XCTAssertEqual(spaced("注意:明天下雨;記得帶傘"), "注意：明天下雨；記得帶傘")
        XCTAssertEqual(spaced("真的嗎?!"), "真的嗎？！")
        XCTAssertEqual(spaced("你好 , 世界 ."), "你好，世界。")
        XCTAssertEqual(spaced("Hello, 你好"), "Hello，你好")
        XCTAssertEqual(spaced("Note: 這個很重要"), "Note：這個很重要")
    }

    func testSentenceEndingWithLatinWord() {
        XCTAssertEqual(spaced("我今天用了 Claude Code."), "我今天用了 Claude Code。")
        XCTAssertEqual(spaced("這是什麼 API?"), "這是什麼 API？")
        XCTAssertEqual(spaced("我用 Claude Code. 然後去吃飯"), "我用 Claude Code。然後去吃飯")
        XCTAssertEqual(spaced("版本是 v2.3.1."), "版本是 v2.3.1。")
        // Not a Chinese sentence end.
        XCTAssertEqual(spaced("他是 Mr. Smith"), "他是 Mr. Smith")
        XCTAssertEqual(spaced("我在學 Node.js 和 Vue.js"), "我在學 Node.js 和 Vue.js")
    }

    func testParentheses() {
        XCTAssertEqual(spaced("我們需要(一)預算,(二)人力"), "我們需要（一）預算，（二）人力")
        XCTAssertEqual(spaced("Claude(克勞德)"), "Claude（克勞德）")
        XCTAssertEqual(spaced("我(I)覺得"), "我（I）覺得")
        // Code-like call or an English aside stays half-width.
        XCTAssertEqual(spaced("呼叫foo(bar)之後"), "呼叫 foo(bar) 之後")
        XCTAssertEqual(spaced("Claude(Anthropic)的模型"), "Claude(Anthropic) 的模型")
        XCTAssertEqual(spaced("這個 API (application programming interface) 很好用"),
                       "這個 API (application programming interface) 很好用")
        XCTAssertEqual(spaced("(API),我們"), "（API），我們")
    }

    func testThingsThatMustNotBeTouched() {
        XCTAssertEqual(spaced("圓周率是3.14,會議10:30開始"), "圓周率是 3.14，會議 10:30 開始")
        XCTAssertEqual(spaced("價格是1,299元"), "價格是 1,299 元")
        XCTAssertEqual(spaced("然後...我們就走了"), "然後...我們就走了")
        XCTAssertEqual(spaced("等一下..."), "等一下...")
        XCTAssertEqual(spaced("打開config.json這個檔案"), "打開 config.json 這個檔案")
        XCTAssertEqual(spaced("版本v2.3.1已經發布"), "版本 v2.3.1 已經發布")
        XCTAssertEqual(spaced("網址是https://example.com/path?q=1,你看"), "網址是 https://example.com/path?q=1，你看")
        XCTAssertEqual(spaced("看 https://zh.wikipedia.org/wiki/Foo_(bar)."), "看 https://zh.wikipedia.org/wiki/Foo_(bar)。")
        XCTAssertEqual(spaced("到www.example.com:8080/a?b=c看看"), "到 www.example.com:8080/a?b=c 看看")
        XCTAssertEqual(spaced("聯絡我test@example.com,謝謝"), "聯絡我 test@example.com，謝謝")
        XCTAssertEqual(spaced("寄到 first.last+tag@mail.example.co.uk."), "寄到 first.last+tag@mail.example.co.uk。")
    }

    func testPureLatinIsUnchanged() {
        let english = "Hello, world. How are you? Fine: thanks; (really)! See https://example.com, ok."
        XCTAssertEqual(spaced(english), english)
        XCTAssertEqual(tight(english), english)
        XCTAssertEqual(spaced("3.14 10:30 1,000 v1.2.3 a.b.c foo(bar) x;y"), "3.14 10:30 1,000 v1.2.3 a.b.c foo(bar) x;y")
    }

    func testCJKLatinSpacing() {
        XCTAssertEqual(spaced("我用Claude Code寫iOS 18的app"), "我用 Claude Code 寫 iOS 18 的 app")
        XCTAssertEqual(tight("我用 Claude Code 寫 iOS 18 的 app"), "我用Claude Code寫iOS 18的app")
        XCTAssertEqual(tight("我用Claude Code寫iOS 18的app"), "我用Claude Code寫iOS 18的app")
        XCTAssertEqual(spaced("5G網路和50%的人"), "5G 網路和 50% 的人")
        XCTAssertEqual(spaced("花了$100買#標籤"), "花了 $100 買 #標籤")
        XCTAssertEqual(spaced("這是 Café 的 naïve 設計"), "這是 Café 的 naïve 設計")
        // No space next to full-width punctuation, in either mode.
        XCTAssertEqual(spaced("我用Claude，然後「GitHub」也可以。"), "我用 Claude，然後「GitHub」也可以。")
        XCTAssertEqual(spaced("我用 Claude ， 然後 「 GitHub 」 也可以 。"), "我用 Claude，然後「GitHub」也可以。")
        XCTAssertEqual(tight("我用 Claude ， 然後 「 GitHub 」 也可以 。"), "我用Claude，然後「GitHub」也可以。")
        // Emoji and CJK-CJK spaces are left alone.
        XCTAssertEqual(spaced("好開心😀今天"), "好開心😀今天")
        XCTAssertEqual(spaced("你好 世界"), "你好 世界")
    }

    func testWhitespace() {
        XCTAssertEqual(spaced("  你好    世界  "), "你好 世界")
        XCTAssertEqual(spaced("第一行  \n   第二行\t\t結束 "), "第一行\n第二行 結束")
        XCTAssertEqual(spaced("\n\n第一段\n\n第二段\n\n"), "第一段\n\n第二段")
        XCTAssertEqual(spaced(""), "")
        XCTAssertEqual(spaced("   "), "")
    }

    func testTraditionalCharactersAreNotChanged() {
        let text = "這份文件很重要，我們在台灣用軟體寫程式。"
        XCTAssertEqual(spaced(text), text)
        XCTAssertEqual(tight(text), text)
    }

    func testIdempotentOnExamples() {
        let samples = [
            "你好,我是阿高.", "我用Claude Code寫iOS 18的app", "我用 Claude Code. 然後去吃飯", "(API),我們",
            "Hello,(一)", "他說 what?!", "網址是https://example.com/path?q=1,你看", "呼叫foo(bar)之後",
            "我們需要 (API) 文件", "價格是1,299元...真的嗎?", "Claude(Anthropic)的模型", "第一行  \n   第二行",
            "a,b。c.d!e?f", "（一)二(三）", "...你好...", "1.2.3.4版", "我:)開心", "))((你好",
        ]
        for text in samples {
            for spacing in [true, false] {
                let once = ZhTW.normalize(text, spaceBetweenCJKAndLatin: spacing)
                XCTAssertEqual(ZhTW.normalize(once, spaceBetweenCJKAndLatin: spacing), once, "\(spacing): \(text)")
            }
        }
    }

    /// Random strings from a small alphabet that mixes every character class the rules care about.
    func testIdempotentOnRandomInput() {
        let alphabet = Array("你好世界台灣A b Z 9 0 , . ? ! : ; ( ) 。，「」@ / _ - % $ 😀 \n".unicodeScalars)
            + Array("https://www.".unicodeScalars)
        var rng = SplitMix64(seed: 20261121)
        let iterations = Int(ProcessInfo.processInfo.environment["SCRIBER_FUZZ_ITERATIONS"] ?? "") ?? 3_000
        for _ in 0..<iterations {
            var view = String.UnicodeScalarView()
            for _ in 0..<Int(rng.next() % 30) { view.append(alphabet[Int(rng.next() % UInt64(alphabet.count))]) }
            let text = String(view)
            for spacing in [true, false] {
                let once = ZhTW.normalize(text, spaceBetweenCJKAndLatin: spacing)
                XCTAssertEqual(ZhTW.normalize(once, spaceBetweenCJKAndLatin: spacing), once,
                               "spacing \(spacing), input: \(text.debugDescription)")
            }
        }
    }
}

/// Deterministic PRNG so the random test is reproducible.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
