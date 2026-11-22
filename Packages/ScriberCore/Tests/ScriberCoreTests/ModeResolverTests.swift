import XCTest
@testable import ScriberCore
import ScriberShared

/// `ModeResolver`: "follow default" vs override for every field, and the AI / provider rules.
final class ModeResolverTests: XCTestCase {

    private func defaults(polish: PolishProviderKind = .off) -> ModeDefaults {
        var d = ModeDefaults(sttProvider: .elevenLabsScribe, polishProvider: polish, forceTraditional: true,
                             spaceBetweenCJKAndLatin: true, translateTarget: "Korean")
        d.punctuationRule = .spaces
        d.punctuationLimit = 30
        d.realtimeEnabled = true
        d.polishTimeout = 3
        return d
    }

    private func resolve(_ mode: DictationModeConfig, polish: PolishProviderKind = .off,
                         prompts: [PromptTemplate] = PromptLibrary.builtIns) -> ResolvedModeConfig {
        ModeResolver.resolve(mode, prompts: prompts, defaults: defaults(polish: polish))
    }

    func testFollowDefaultTakesEveryGlobalSetting() {
        let r = resolve(DictationModeConfig(name: "全部跟隨"))
        XCTAssertEqual(r.sttProvider, .elevenLabsScribe)
        XCTAssertEqual(r.languageCode, "zh")
        XCTAssertTrue(r.realtimeEnabled)
        XCTAssertTrue(r.forceTraditional)
        XCTAssertTrue(r.spaceBetweenCJKAndLatin)
        XCTAssertEqual(r.punctuationRule, .spaces)
        XCTAssertEqual(r.punctuationLimit, 30)
        XCTAssertEqual(r.translateTarget, "Korean")
        XCTAssertEqual(r.polishTimeout, 3)
        XCTAssertNil(r.llm, "AI follows the global switch, which is off")
        XCTAssertEqual(r.task, .dictation)
        XCTAssertEqual(r.context, .none)
        XCTAssertEqual(r.output, .paste)
        XCTAssertEqual(r.autoSend, .none)
    }

    func testOverridesWin() {
        var mode = DictationModeConfig(name: "全部覆寫")
        mode.recognition = ModeRecognition(engine: .custom(.groqWhisperLarge), language: .custom("en"), realtime: .custom(false))
        mode.textFormat = ModeTextFormat(forceTraditional: .custom(false), spaceBetweenCJKAndLatin: .custom(false),
                                         punctuationRule: .custom(.keep), punctuationLimit: .custom(-5))
        mode.ai = ModeAI(enabled: .custom(true), provider: .custom(.anthropic), model: "some-model",
                         promptID: BuiltInPromptID.translate.rawValue, translateLanguageID: .custom("ja"))
        mode.output = .copyOnly
        mode.autoSend = .returnKey
        let r = resolve(mode, polish: .groq)
        XCTAssertEqual(r.sttProvider, .groqWhisperLarge)
        XCTAssertEqual(r.languageCode, "en")
        XCTAssertFalse(r.realtimeEnabled)
        XCTAssertFalse(r.forceTraditional)
        XCTAssertFalse(r.spaceBetweenCJKAndLatin)
        XCTAssertEqual(r.punctuationRule, .keep)
        XCTAssertEqual(r.punctuationLimit, 0, "clamped like the setting")
        XCTAssertEqual(r.translateTarget, "Japanese")
        XCTAssertEqual(r.task, .translate)
        XCTAssertEqual(r.llm?.candidates, [.anthropic, .groq], "the mode's provider first, then any other key")
        XCTAssertEqual(r.llm?.required, true)
        XCTAssertEqual(r.llm?.model, "some-model")
        XCTAssertEqual(r.output, .copyOnly)
        XCTAssertEqual(r.autoSend, .returnKey)

        var auto = DictationModeConfig(name: "自動語言")
        auto.recognition.language = .custom(ModeRecognition.automatic)
        XCTAssertNil(resolve(auto).languageCode, "auto → let the engine detect")
    }

    func testAIRules() {
        let dictate = DictationModeConfig.builtIn(.dictate)
        XCTAssertNil(resolve(dictate, polish: .off).llm, "聽寫 + 潤飾 off → rule-based")
        let polishedDictate = resolve(dictate, polish: .anthropic).llm
        XCTAssertEqual(polishedDictate?.candidates, [.anthropic], "聽寫 + 潤飾 on → only that provider, as before")
        XCTAssertEqual(polishedDictate?.required, false, "a missing key falls back to rule-based cleanup")

        let polish = DictationModeConfig.builtIn(.polish)
        XCTAssertEqual(resolve(polish, polish: .off).llm?.candidates, [.groq, .anthropic], "explicitly on → any key")
        XCTAssertEqual(resolve(polish, polish: .anthropic).llm?.candidates, [.anthropic, .groq])
        XCTAssertEqual(resolve(polish).llm?.required, true)
        XCTAssertEqual(resolve(polish).task, .dictation)

        for builtIn in [BuiltInModeID.translate, .rewrite, .assistant] {
            var mode = DictationModeConfig.builtIn(builtIn)
            mode.ai.enabled = .custom(false)
            let r = resolve(mode, polish: .off)
            XCTAssertNotNil(r.llm, "\(builtIn): these prompts always need the LLM")
            XCTAssertEqual(r.llm?.candidates, [.groq, .anthropic], "\(builtIn): same rule as translate before modes")
            XCTAssertEqual(r.llm?.required, true)
        }
        XCTAssertEqual(resolve(.builtIn(.translate), polish: .anthropic).llm?.candidates, [.anthropic, .groq])

        var off = DictationModeConfig.builtIn(.email)
        off.ai.enabled = .custom(false)
        XCTAssertNil(resolve(off, polish: .groq).llm, "explicitly off beats the global switch")
        XCTAssertEqual(resolve(off, polish: .groq).task, .dictation)

        var offProvider = DictationModeConfig.builtIn(.polish)
        offProvider.ai.provider = .custom(.off)
        XCTAssertEqual(resolve(offProvider, polish: .anthropic).llm?.candidates, [.anthropic, .groq], "provider .off = follow default")
    }

    func testPromptSelectionAndFallback() {
        let mine = PromptTemplate(id: "mine", name: "我的", kind: .assistant, body: "x")
        var mode = DictationModeConfig(name: "用我的")
        mode.ai = ModeAI(enabled: .custom(true), promptID: "mine")
        let prompts = PromptLibrary.builtIns + [mine]
        XCTAssertEqual(resolve(mode, prompts: prompts).llm?.prompt.id, "mine")
        XCTAssertEqual(resolve(mode, prompts: prompts).task, .assistant)
        XCTAssertEqual(resolve(mode, prompts: prompts).polishTimeout, ModeResolver.assistantTimeout, "answers get longer")
        XCTAssertFalse(resolve(mode, prompts: prompts).llm!.prompt.isPristineBuiltIn)

        // Deleted prompt: a user mode falls back to 預設, a shipped mode to its own prompt.
        XCTAssertEqual(resolve(mode, prompts: PromptLibrary.builtIns).llm?.prompt.id, BuiltInPromptID.standard.rawValue)
        var translate = DictationModeConfig.builtIn(.translate)
        translate.ai.promptID = "gone"
        XCTAssertEqual(resolve(translate).llm?.prompt.id, BuiltInPromptID.translate.rawValue)
        XCTAssertEqual(resolve(translate).task, .translate)
        // An edited shipped prompt is used as edited.
        var edited = PromptLibrary.builtIn(.email)
        edited.body = "改過"
        let r = resolve(.builtIn(.email), prompts: PromptLibrary.builtIns.map { $0.id == edited.id ? edited : $0 })
        XCTAssertEqual(r.llm?.prompt.body, "改過")
        XCTAssertFalse(r.llm!.prompt.isPristineBuiltIn)
    }

    func testRequestLevelRules() {
        let modes = DictationModeConfig.builtIns
        let d = defaults(polish: .groq)
        let rewrite = ModeResolver.resolve(DictationRequest(mode: .edit, selectedText: "原文"), modes: modes,
                                           prompts: PromptLibrary.builtIns, defaults: d)
        XCTAssertEqual(rewrite.task, .rewrite)
        XCTAssertEqual(rewrite.output, .replaceSelection)
        XCTAssertTrue(rewrite.context.selectedText)
        XCTAssertEqual(rewrite.legacyMode, .edit)

        // 改寫 with nothing selected: the default mode runs (聽寫, polished with the global provider).
        let noSelection = ModeResolver.resolve(DictationRequest(mode: .edit, selectedText: " \n"), modes: modes,
                                               prompts: PromptLibrary.builtIns, defaults: d)
        XCTAssertEqual(noSelection.modeID, BuiltInModeID.dictate.rawValue)
        XCTAssertEqual(noSelection.requestedModeID, BuiltInModeID.rewrite.rawValue)
        XCTAssertEqual(noSelection.task, .dictation)
        XCTAssertEqual(noSelection.output, .paste)
        XCTAssertEqual(noSelection.llm?.candidates, [.groq])
        XCTAssertEqual(noSelection.legacyMode, .dictate)

        // A default mode that is itself a rewrite cannot loop: shipped 聽寫 settings run.
        var weird = modes
        weird[weird.firstIndex { $0.id == BuiltInModeID.rewrite.rawValue }!].isDefault = true
        weird[0].isDefault = false
        let loop = ModeResolver.resolve(DictationRequest(), modes: weird, prompts: PromptLibrary.builtIns, defaults: d)
        XCTAssertEqual(loop.modeID, BuiltInModeID.dictate.rawValue)
        XCTAssertEqual(loop.task, .dictation)

        // replaceSelection on another mode without a selection pastes.
        var mine = DictationModeConfig(name: "取代")
        mine.output = .replaceSelection
        let pasted = ModeResolver.resolve(DictationRequest(modeID: mine.id), modes: modes + [mine],
                                          prompts: PromptLibrary.builtIns, defaults: d)
        XCTAssertEqual(pasted.output, .paste)
    }

    func testContextFlagsOnlyWhenTheAIRuns() {
        var mode = DictationModeConfig(name: "情境")
        mode.context = ModeContextFlags(selectedText: true, clipboard: true, appName: true)
        XCTAssertEqual(resolve(mode, polish: .off).context, .none, "nothing is sent when no AI runs")
        XCTAssertEqual(resolve(mode, polish: .groq).context, mode.context)
        var rewrite = DictationModeConfig.builtIn(.rewrite)
        rewrite.context.selectedText = false
        XCTAssertTrue(resolve(rewrite).context.selectedText, "a rewrite always gets its selection")
    }

    func testTaskRulesMatchThePreModesPipeline() {
        func config(_ task: PromptKind, target: String = "English") -> ResolvedModeConfig {
            var r = resolve(.builtIn(.dictate))
            r.task = task
            r.translateTarget = target
            return r
        }
        XCTAssertTrue(config(.dictation).skipsLLMForShortTranscripts)
        XCTAssertFalse(config(.translate).skipsLLMForShortTranscripts)
        XCTAssertTrue(config(.dictation).fallsBackToRuleBasedCleanup)
        for task in [PromptKind.translate, .rewrite, .assistant] {
            XCTAssertFalse(config(task).fallsBackToRuleBasedCleanup, "\(task)")
        }
        XCTAssertTrue(config(.dictation).appliesPunctuationRule)
        XCTAssertTrue(config(.translate).appliesPunctuationRule)
        XCTAssertFalse(config(.rewrite).appliesPunctuationRule)
        XCTAssertFalse(config(.translate, target: "English").convertsToTraditional)
        XCTAssertTrue(config(.translate, target: "Traditional Chinese (Taiwan)").convertsToTraditional)
        XCTAssertTrue(config(.rewrite).convertsToTraditional)
        XCTAssertTrue(config(.assistant).convertsToTraditional)
    }

    // MARK: 自動套用的 App (M3)

    func testAutoApplyCandidatesInListOrderEnabledOnly() {
        var modes = DictationModeConfig.builtIns
        let notes = DictationModeConfig(id: "user.notes", name: "筆記", trigger: ModeTrigger(appBundleIDs: ["com.apple.Notes", "com.apple.mail"]))
        let off = DictationModeConfig(id: "user.off", name: "停用的", isEnabled: false, trigger: ModeTrigger(appBundleIDs: ["com.apple.mail"]))
        modes += [notes, off]
        // Email is earlier in the list than the user's mode; the disabled one never matches.
        XCTAssertEqual(ModeResolver.autoApplyCandidates(for: "com.apple.mail", in: modes).map(\.id),
                       [BuiltInModeID.email.rawValue, "user.notes"])
        XCTAssertEqual(ModeResolver.autoApplyCandidates(for: "COM.APPLE.NOTES", in: modes).map(\.id), ["user.notes"])
        XCTAssertEqual(ModeResolver.autoApplyCandidates(for: "com.apple.Safari", in: modes), [])
        XCTAssertEqual(ModeResolver.autoApplyCandidates(for: nil, in: modes), [])
        XCTAssertEqual(ModeResolver.autoApplyCandidates(for: "  ", in: modes), [])
        // Reordered: the user's mode now comes first.
        let reordered = [notes] + DictationModeConfig.builtIns
        XCTAssertEqual(ModeResolver.autoApplyCandidates(for: "com.apple.mail", in: reordered).first?.id, "user.notes")
        // Email switched off: only the user's mode is left.
        modes = modes.map { mode in
            var mode = mode
            if mode.id == BuiltInModeID.email.rawValue { mode.isEnabled = false }
            return mode
        }
        XCTAssertEqual(ModeResolver.autoApplyCandidates(for: "com.apple.mail", in: modes).map(\.id), ["user.notes"])
    }

    func testContextLimitsMatchThePromptBuilder() {
        XCTAssertEqual(ModeContextLimit.characters, PolishPrompt.contextCharacterLimit)
        XCTAssertEqual(ModeContextLimit.appName, PolishPrompt.appNameLimit)
    }
}
