import XCTest
@testable import ScriberCore

final class PolishRuleBasedCleanupTests: XCTestCase {

    private func check(_ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(RuleBasedCleanup.clean(input), expected, "input: \(input)", file: file, line: line)
    }

    private func unchanged(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(RuleBasedCleanup.clean(input), input, "should be untouched", file: file, line: line)
    }

    // MARK: Clause-start fillers

    func testLeadingFillers() {
        check("嗯，我覺得這個方案可以。", "我覺得這個方案可以。")
        check("呃我們明天要開會", "我們明天要開會")
        check("嗯嗯嗯，那個，就是說我們要不要改時間？", "就是說我們要不要改時間？")
        check("欸你明天有空嗎？", "你明天有空嗎？")
        check("啊對了，我明天不能去。", "對了，我明天不能去。")
        check("呃… 我想一下", "我想一下")
        check("额，我想想", "我想想")
        check("嗯 OK，就這樣", "OK，就這樣")
    }

    func testFillersAfterCommaOrSentence() {
        check("好的，嗯，那就這樣吧。", "好的，那就這樣吧。")
        check("我覺得，呃，這樣不太好。", "我覺得，這樣不太好。")
        check("我到了。嗯，你在哪？", "我到了。你在哪？")
        check("好的，嗯", "好的")
    }

    func testNageHesitation() {
        check("那個那個，我想問一下你明天有空嗎？", "我想問一下你明天有空嗎？")
        check("那個，你過來一下", "你過來一下")
        unchanged("我要那個，還有這個。")
        unchanged("那個人是誰？")
        unchanged("那個我不知道。")
        unchanged("我要買那個藍色的。")
    }

    func testInterjectionsCarryingToneAreKept() {
        unchanged("嗯？你說什麼？")
        unchanged("啊！我忘了帶鑰匙。")
        unchanged("嗯哼，你說得對。")
        unchanged("啊哈，原來是這樣。")
        unchanged("欸～你好可愛")
        unchanged("额度不夠了。")
        unchanged("額外的費用要另外算。")
    }

    func testSentenceFinalParticlesAreKept() {
        unchanged("好啊")
        unchanged("對啊，就是這樣。")
        unchanged("是喔，那我晚點再去。")
        unchanged("好欸！")
        unchanged("你今天會來嗎？會啊。")
    }

    func testFillerOnlyInputIsReturnedAsIs() {
        check("嗯嗯", "嗯嗯")
        check("嗯", "嗯")
        check("  嗯。 ", "嗯。")
        check("呃", "呃")
        check("um", "um")
    }

    // MARK: Stutters

    func testSingleCharacterStutters() {
        check("我我我覺得不太好", "我覺得不太好")
        check("他他們都到了。", "他們都到了。")
        check("你你你先走", "你先走")
        check("這這個問題很難", "這個問題很難")
        check("我們就就先這樣", "我們就先這樣")
        check("那那個人是誰", "那個人是誰")
        check("我，我，我真的不知道。", "我真的不知道。")
    }

    func testLegitimateReduplicationIsKept() {
        unchanged("謝謝你幫我看看這個。")
        unchanged("我們慢慢來，剛剛那個問題常常發生。")
        unchanged("哈哈哈好好笑")
        unchanged("天天都要運動，媽媽說的。")
        unchanged("等等我，馬上到！")
        unchanged("好好好，我知道了。")
        unchanged("對對對，就是這樣。")
        unchanged("是是是，您說得對。")
        unchanged("沒有沒有，不用客氣。")
        unchanged("不是不是，我不是那個意思。")
        unchanged("研究研究再說。")
        unchanged("你看你看，我就說吧。")
        unchanged("你好你好，請問是王先生嗎？")
        unchanged("的的確確是這樣。")
        unchanged("實實在在的感覺。")
        unchanged("我們要仔仔細細地檢查。")
        unchanged("拜拜，明天見！")
        unchanged("寶寶睡著了。")
        unchanged("偷偷告訴你一件事。")
    }

    func testWordBoundaryLookalikesAreKept() {
        unchanged("現在在做什麼？")
        unchanged("我們需要要求退款。")
        unchanged("開會會晚一點。")
        unchanged("其他他們沒說。")
        unchanged("他彈吉他他很厲害。")
        unchanged("他的成就就是讓大家看見。")
        unchanged("是我，我來處理。")
        unchanged("我想想再跟你說。")
        unchanged("問題存在在系統裡。")
        check("其他他他們沒說", "其他他們沒說")
    }

    // MARK: Repeated words and restarts

    func testRepeatedFillerWords() {
        check("然後然後他就走了", "然後他就走了")
        check("就是就是，我也這麼覺得。", "就是，我也這麼覺得。")
        check("這個這個 bug 很煩", "這個 bug 很煩")
        check("我們我們明天再討論", "我們明天再討論")
        check("所以，所以我才說不要。", "所以我才說不要。")
        check("因為因為因為下雨了", "因為下雨了")
    }

    func testRestartedPhrases() {
        check("我覺得我覺得這樣比較好", "我覺得這樣比較好")
        check("我們明天我們明天要開會。", "我們明天要開會。")
        check("我覺得，我覺得可以。", "我覺得可以。")
        check("我覺得我覺得我覺得不行", "我覺得不行")
        unchanged("他說他說過了。")
        unchanged("謝謝你謝謝你！")
        unchanged("加油加油！")
    }

    // MARK: English and mixed

    func testEnglishFillers() {
        check("um I think the deploy failed", "I think the deploy failed")
        check("So, um, we should ship it.", "So, we should ship it.")
        check("I think uh we should wait", "I think we should wait")
        check("Uhm, okay", "okay")
        check("I think um.", "I think.")
        unchanged("Uh-huh, sounds good.")
        unchanged("Umbrella and umami are words.")
        unchanged("The UHF band")
    }

    func testEnglishRepeats() {
        check("the the deploy failed", "the deploy failed")
        check("I I don't know", "I don't know")
        check("We need to to fix it.", "We need to fix it.")
        check("The the theory is fine", "The theory is fine")
        unchanged("I know that that is wrong.")
        unchanged("She had had enough.")
        unchanged("What it is is a bug.")
        unchanged("Log in in the settings page.")
        unchanged("It was so so.")
        unchanged("Thank you you're the best.")
    }

    func testMixedChineseEnglish() {
        check("我剛剛 push 了一個 PR，uh，你幫我 review 一下", "我剛剛 push 了一個 PR，你幫我 review 一下")
        check("我覺得 um 這個不錯", "我覺得這個不錯")
        check("嗯，這個 feature 我們下週 deploy", "這個 feature 我們下週 deploy")
        check("那個那個 Claude Code 的設定在哪？", "那個 Claude Code 的設定在哪？")
        unchanged("我剛剛 push 了一個 PR，你幫我 review 一下。")
        unchanged("用 Swift 寫 3 個 App")
        unchanged("網址是 https://example.com/a..b，帳號是 kazen@example.com。")
        unchanged("版本 1.2.3 已經上線。")
    }

    // MARK: Punctuation and whitespace

    func testDoubledPunctuation() {
        check("好。。", "好。")
        check("真的嗎？。", "真的嗎？")
        check("太好了！。", "太好了！")
        check("我們明天見，。", "我們明天見。")
        check("我們明天見，，然後再說", "我們明天見，然後再說")
        check("你好、、我是阿高", "你好、我是阿高")
        check("好。，那就這樣", "好。那就這樣")
        unchanged("等一下……我想想。")
        unchanged("Wait... what?")
        unchanged("真的假的？？")
        unchanged("太扯了吧！！")
    }

    func testWhitespace() {
        check("  我們明天見  ", "我們明天見")
        check("我們明天見 。", "我們明天見。")
        check("第一點\n\n\n\n第二點", "第一點\n\n第二點")
        check("第一行  \n  第二行", "第一行\n第二行")
        check("a\tb", "a b")
        check("", "")
        check("   \n ", "")
        unchanged("Hi John,\nThanks for the update.")
    }

    func testListsAndLinesSurvive() {
        let list = "我要買：\n- 牛奶\n- 雞蛋\n- 吐司"
        unchanged(list)
        check("嗯，第一點是速度\n嗯，第二點是價格", "第一點是速度\n第二點是價格")
    }

    // MARK: Realistic sentences

    func testRealisticDictations() {
        check("嗯那個我想問一下就是我們明天的會議改到幾點",
              "那個我想問一下就是我們明天的會議改到幾點")
        check("呃，幫我問他明天有沒有空", "幫我問他明天有沒有空")
        check("欸，我我我剛剛看到你傳的訊息，然後然後我覺得可以。",
              "我剛剛看到你傳的訊息，然後我覺得可以。")
        check("嗯，這個這個 PR 我看過了，the the CI 有過。",
              "這個 PR 我看過了，the CI 有過。")
        unchanged("幫我問他明天有沒有空")
        unchanged("我晚點打給你，記得先吃飯。")
        unchanged("明天下午三點在 101 見面，不要遲到喔。")
    }

    func testMoreEdgeCases() {
        check("那個那個人是誰", "那個人是誰")
        check("我我們先走了", "我們先走了")
        check("就是說就是說這個不行", "就是說這個不行")
        check("欸欸欸，你看那邊", "你看那邊")
        check("這個這個這個很重要", "這個很重要")
        check("um, um, I think so", "I think so")
        check("啊啊啊啊", "啊啊啊啊")
        unchanged("我嗯覺得可以")          // mid-clause: not sure, leave it
        unchanged("我今天 去公司 開會")    // Whisper-style pause spaces are left alone
        unchanged("So so what?")
        unchanged("1 1 2 3 5 8")
        check("他他", "他")
    }

    func testIdempotent() {
        let inputs = ["嗯，我我我覺得那個那個方案可以。。", "um so the the thing is, uh, fine",
                      "謝謝你幫我看看這個。", "然後然後，嗯，就這樣"]
        for input in inputs {
            let once = RuleBasedCleanup.clean(input)
            XCTAssertEqual(RuleBasedCleanup.clean(once), once, input)
        }
    }

    func testNeverDeletesMeaningfulCharacters() {
        // Every Han character that is not a filler or a collapsed repeat must survive.
        let input = "我覺得這個方案很好，但是預算要再確認一下，你可以幫我問財務嗎？"
        unchanged(input)
        let long = String(repeating: "今天天氣很好，我們去公園散步。", count: 20)
        unchanged(long)
    }

    // MARK: Simplified input (Whisper often answers in Simplified; conversion runs after cleanup)

    func testSimplifiedFillersAreRemoved() {
        check("那个，我想问一下", "我想问一下")
        check("嗯，那个，我们明天开会", "我们明天开会")
        check("然后然后我们就走了", "然后我们就走了")
        check("这个这个方案可以", "这个方案可以")
        check("我们我们明天见", "我们明天见")
    }
}
