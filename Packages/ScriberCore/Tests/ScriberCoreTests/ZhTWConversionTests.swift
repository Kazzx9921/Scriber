import XCTest
@testable import ScriberCore

final class ZhTWConversionTests: XCTestCase {
    // MARK: - Equivalence with OpenCC s2twp

    func testExactS2TWPMatchesOpenCCGolden() {
        var mismatches: [String] = []
        for pair in ZhTWGoldenData.s2twp where ZhTW.openCCS2TWP(pair.input) != pair.output {
            mismatches.append("\(pair.input)\n  expected \(pair.output)\n  got      \(ZhTW.openCCS2TWP(pair.input))")
        }
        XCTAssertGreaterThan(ZhTWGoldenData.s2twp.count, 300)
        XCTAssertEqual(mismatches.count, 0, mismatches.prefix(5).joined(separator: "\n"))
    }

    /// Golden inputs are Simplified or script-neutral, so the public converter must equal s2twp,
    /// except where s2twp is not idempotent on its own output and the result is settled further.
    func testToTraditionalTaiwanMatchesGoldenForSimplifiedInput() {
        for pair in ZhTWGoldenData.s2twp {
            let output = ZhTW.toTraditionalTaiwan(pair.input)
            if ZhTW.openCCS2TWP(pair.output) == pair.output {
                XCTAssertEqual(output, pair.output, "input: \(pair.input)")
            }
            XCTAssertFalse(ZhTW.containsSimplified(output), "leak in: \(output)")
        }
    }

    func testCommonOneToManyTraps() {
        // Expected values are what `opencc -c s2twp` (1.4.2) outputs.
        let cases: [(String, String)] = [
            ("头发", "頭髮"), ("发现", "發現"), ("理发", "理髮"), ("出发", "出發"),
            ("皇后", "皇后"), ("后来", "後來"), ("后面", "後面"),
            ("干净", "乾淨"), ("干部", "幹部"), ("干燥", "乾燥"), ("干涉", "干涉"),
            ("里面", "裡面"), ("这里", "這裡"), ("公里", "公里"),
            ("面条", "麵條"), ("面子", "面子"), ("牛肉面", "牛肉麵"),
            ("一只猫", "一隻貓"), ("只是", "只是"),
            ("台湾", "臺灣"), ("台风", "颱風"), ("台灯", "檯燈"),
            ("周末", "週末"), ("周围", "周圍"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ZhTW.toTraditionalTaiwan(input), expected, input)
            XCTAssertEqual(ZhTW.openCCS2TWP(input), expected, input)
        }
    }

    func testTaiwanPhrases() {
        let cases: [(String, String)] = [
            ("软件", "軟體"), ("视频", "影片"), ("网络", "網路"), ("信息", "資訊"),
            ("鼠标", "滑鼠"), ("内存", "記憶體"), ("硬盘", "硬碟"), ("服务器", "伺服器"),
            ("程序", "程式"), ("默认", "預設"), ("U盘", "隨身碟"),
            ("这个软件很好用，推荐给你。", "這個軟體很好用，推薦給你。"),
            ("今天网络好慢，视频一直卡住。", "今天網路好慢，影片一直卡住。"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ZhTW.toTraditionalTaiwan(input), expected, input)
        }
    }

    // MARK: - Traditional input is left alone

    func testTraditionalTextIsUnchanged() {
        // Each of these is rewritten by plain s2twp (shown in the comment), which would corrupt it.
        let traditional = [
            "這份文件很重要，請先看過。",     // s2twp: 文件 → 檔案
            "這會干擾我們的工作。",            // s2twp: 干擾 → 幹擾
            "他去過美國的馬里蘭州。",          // s2twp: 馬里蘭 → 馬裡蘭
            "滑鼠的游標不見了。",              // s2twp: 游標 → 遊標
            "這個數字是對的。",                // s2twp: 數字 → 數位
            "我們在台灣用軟體寫程式。",        // s2twp: 台灣 → 臺灣
            "為什麼你在床裡面睡著？",
            "他的頭髮很長，後來剪短了。",
        ]
        for text in traditional {
            XCTAssertEqual(ZhTW.toTraditionalTaiwan(text), text)
            XCTAssertFalse(ZhTW.containsSimplified(text), text)
        }
        XCTAssertNotEqual(ZhTW.openCCS2TWP("這份文件很重要，請先看過。"), "這份文件很重要，請先看過。")
    }

    func testNonChineseIsUnchanged() {
        let texts = [
            "", " ", "Hello, world! This is plain English.",
            "1234567890 3.14 10:30 v2.3.1 1,299", "😀🎉👍🏽❤️ 👨‍👩‍👧",
            "，。？！：；（）「」『』、……——", "https://example.com/path?q=1&x=2 test@example.com",
            "Ünïcödé façade naïve — Ελληνικά Кириллица", "こんにちは、カタカナ", "한국어 문장",
            "\n\t  \n",
        ]
        for text in texts {
            XCTAssertEqual(ZhTW.toTraditionalTaiwan(text), text)
            XCTAssertEqual(ZhTW.openCCS2TWP(text), text)
        }
    }

    func testLatinDigitsAndEmojiInsideChineseArePreserved() {
        XCTAssertEqual(ZhTW.toTraditionalTaiwan("我用Claude Code写了iOS 18的app😀，版本v2.3.1，耗时3.5秒。"),
                       "我用Claude Code寫了iOS 18的app😀，版本v2.3.1，耗時3.5秒。")
        XCTAssertEqual(ZhTW.toTraditionalTaiwan("帮我把这个PR合并到main分支"), "幫我把這個PR合併到main分支")
    }

    // MARK: - Mixed script

    func testTraditionalWithStraySimplifiedIsRepairedLocally() {
        // Mostly Traditional: only the phrases holding Simplified-only characters are converted,
        // so 文件 (document) survives while 内容 → 內容.
        XCTAssertEqual(ZhTW.toTraditionalTaiwan("這份文件的内容我們已經討論過了。"), "這份文件的內容我們已經討論過了。")
        XCTAssertEqual(ZhTW.toTraditionalTaiwan("這個软件很好用，我們都在用。"), "這個軟體很好用，我們都在用。")
        // Mostly Simplified: plain s2twp.
        XCTAssertEqual(ZhTW.toTraditionalTaiwan("這个问题我们讨论过了"), ZhTW.openCCS2TWP("這个问题我们讨论过了"))
    }

    func testEachSentenceIsJudgedOnItsOwn() {
        // A Traditional sentence followed by a Simplified one (e.g. STT drifting mid-dictation).
        let text = "這份文件很重要。我们明天再讨论这个文件吧！"
        XCTAssertEqual(ZhTW.toTraditionalTaiwan(text), "這份文件很重要。我們明天再討論這個檔案吧！")
    }

    // MARK: - Properties

    func testIdempotent() {
        var samples = ZhTWGoldenData.s2twp.flatMap { [$0.input, $0.output] }
        samples += ["三征七辟", "伙夫", "划着走", "朱干玉戚", "這份文件的内容", "台北", "干嘛", "里", "后"]
        for text in samples {
            let once = ZhTW.toTraditionalTaiwan(text)
            XCTAssertEqual(ZhTW.toTraditionalTaiwan(once), once, "input: \(text)")
        }
    }

    /// Mixed-script text built by splicing Simplified characters back into converted sentences.
    func testMixedScriptNeverLeaksAndIsIdempotent() {
        var mixedCount = 0
        for pair in ZhTWGoldenData.s2twp {
            let simplified = Array(pair.input.unicodeScalars)
            let traditional = Array(pair.output.unicodeScalars)
            guard simplified.count == traditional.count, simplified != traditional else { continue }
            for stride in [2, 3, 5] {
                var view = String.UnicodeScalarView()
                for i in traditional.indices { view.append(i % stride == 0 ? simplified[i] : traditional[i]) }
                let mixed = String(view)
                let once = ZhTW.toTraditionalTaiwan(mixed)
                XCTAssertFalse(ZhTW.containsSimplified(once), "leak: \(mixed) → \(once)")
                XCTAssertEqual(ZhTW.toTraditionalTaiwan(once), once, "not idempotent: \(mixed)")
                mixedCount += 1
            }
        }
        XCTAssertGreaterThan(mixedCount, 500)
    }

    func testContainsSimplified() {
        for text in ["头发", "这个", "我们", "后来", "软件", "iOS 的设置"] {
            XCTAssertTrue(ZhTW.containsSimplified(text), text)
        }
        // Valid in Traditional too (后 干 里 台 只 面 周 于), Taiwan-standard forms (群 秘 床 峰), non-CJK.
        for text in ["頭髮", "皇后", "干涉", "公里", "台北", "只是", "面子", "周圍", "于是", "群組", "秘密",
                     "床", "山峰", "Hello 123 😀", ""] {
            XCTAssertFalse(ZhTW.containsSimplified(text), text)
        }
    }

    func testConcurrentUseIsSafe() {
        let inputs = ZhTWGoldenData.s2twp.map(\.input)
        let expected = inputs.map(ZhTW.toTraditionalTaiwan)
        let results = UnsafeMutableBufferPointer<String>.allocate(capacity: inputs.count * 4)
        results.initialize(repeating: "")
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: inputs.count * 4) { i in
            results[i] = ZhTW.toTraditionalTaiwan(inputs[i % inputs.count])
        }
        for i in 0..<(inputs.count * 4) { XCTAssertEqual(results[i], expected[i % inputs.count]) }
    }

    func testLongText() {
        let paragraph = ZhTWGoldenData.s2twp.prefix(40).map(\.input).joined(separator: "\n")
        let long = String(repeating: paragraph + "\n", count: 20)
        let expected = String(repeating: ZhTWGoldenData.s2twp.prefix(40).map(\.output).joined(separator: "\n") + "\n", count: 20)
        XCTAssertEqual(ZhTW.openCCS2TWP(long), expected)
        XCTAssertFalse(ZhTW.containsSimplified(ZhTW.toTraditionalTaiwan(long)))
    }

    // MARK: - Data

    func testBundledDictionaries() throws {
        let converter = try OpenCCS2TWP(bundle: .module)
        XCTAssertEqual(converter.stPhrases.count, 49_238)
        XCTAssertEqual(converter.stPhrasesGenerated.count, 556)
        XCTAssertEqual(converter.stCharacters.count, 4_012)
        XCTAssertEqual(converter.twPhrases.count, 818)
        XCTAssertEqual(converter.twVariantsPhrases.count, 12)
        XCTAssertEqual(converter.twVariants.count, 41)
        XCTAssertEqual(converter.compatibility.count, 1_002)
        XCTAssertEqual(converter.tsCharacters.count, 4_148)
        // The ASCII fast path in ZhTW relies on no key being pure ASCII.
        for dict in [converter.stPhrases, converter.stPhrasesGenerated, converter.stCharacters, converter.twPhrases,
                     converter.twVariantsPhrases, converter.twVariants, converter.compatibility] {
            dict.forEachEntry { key, _ in
                XCTAssertTrue(key.contains { $0 >= 0x80 })
            }
        }
        // Sentence splitting relies on no key or value containing a sentence boundary.
        for dict in [converter.stPhrases, converter.stPhrasesGenerated, converter.stCharacters, converter.twPhrases,
                     converter.twVariantsPhrases, converter.twVariants, converter.compatibility] {
            dict.forEachEntry { key, value in
                XCTAssertFalse(key.contains(where: OpenCCS2TWP.isSentenceBoundary))
                XCTAssertFalse(value.contains(where: OpenCCS2TWP.isSentenceBoundary))
            }
        }
        // Repair mode maps output ranges back to the input, so normalization must be 1:1, and it
        // converts single STCharacters values in place.
        converter.compatibility.forEachEntry { key, value in
            XCTAssertEqual(key.count, 1)
            XCTAssertEqual(value.count, 1)
        }
        converter.stCharacters.forEachEntry { _, value in XCTAssertEqual(value.count, 1) }
        XCTAssertEqual(ZhTW.openCCS2TWP("\u{F900}"), "豈") // U+F900 → U+8C48
        XCTAssertEqual(ZhTW.openCCS2TWP("\u{F900}").unicodeScalars.first?.value, 0x8C48)
        for name in ["LICENSE-OpenCC", "NOTICE"] {
            XCTAssertNotNil(Bundle.module.url(forResource: name, withExtension: "txt",
                                              subdirectory: OpenCCS2TWP.resourceSubdirectory), name)
        }
    }

    func testUnsortedDictionaryIsSortedOnLoad() {
        let text = "# comment\n乙\tB\n甲乙\tAB2\n甲\tA\n甲乙丙\tABC x\n\n"
        let dict = OpenCCDictionary(data: Data(text.utf8))
        XCTAssertEqual(dict.count, 4)
        let input: [UInt32] = "甲乙丙丁".unicodeScalars.map(\.value)
        input.withUnsafeBufferPointer { buffer in
            XCTAssertEqual(dict.longestMatch(in: buffer, from: 0, to: 4)?.length, 3)
            XCTAssertEqual(dict.longestMatch(in: buffer, from: 0, to: 2)?.length, 2)
            XCTAssertEqual(dict.longestMatch(in: buffer, from: 1, to: 4)?.length, 1)
            XCTAssertNil(dict.longestMatch(in: buffer, from: 3, to: 4))
        }
    }
}
