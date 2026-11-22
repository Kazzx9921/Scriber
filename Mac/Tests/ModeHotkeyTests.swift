import XCTest
import ScriberCore
import ScriberShared

/// Modes' hotkeys (docs/PRD-模式.md §7.3, M2): routing on both listeners, the same behaviour as the
/// pre-modes 說話改字 / 翻譯 variants for everyone who has not touched the modes, conflicts in plain
/// words, and the request a press produces.
final class ModeHotkeyTests: XCTestCase {
    private let prompts = PromptLibrary.builtIns
    private let rightOptionDown = ModifierBits.option | ModifierBits.rightOption
    private let shiftDown = ModifierBits.shift | ModifierBits.leftShift
    private let controlDown = ModifierBits.control | ModifierBits.leftControl
    private let commandDown = ModifierBits.command | ModifierBits.leftCommand
    private let keyM: UInt16 = 0x2E
    private let ctrlOptM = KeyCombo(keyCode: 0x2E, modifiers: [.control, .option], keyLabel: "M")
    private let customID = "custom.meeting"

    private var defaults: ModeDefaults {
        ModeDefaults(sttProvider: .elevenLabsScribe, polishProvider: .off, forceTraditional: true,
                     spaceBetweenCJKAndLatin: true, translateTarget: "English")
    }

    /// The shipped modes after the M1 migration of these 說話改字 / 翻譯 modifiers.
    private func migrated(edit: VariantModifier, translate: VariantModifier) -> [DictationModeConfig] {
        DictationModeConfig.builtIns.map { mode in
            var mode = mode
            if mode.id == BuiltInModeID.rewrite.rawValue { mode.trigger.hotkey = .withMainTrigger(edit.rawValue) }
            if mode.id == BuiltInModeID.translate.rawValue { mode.trigger.hotkey = .withMainTrigger(translate.rawValue) }
            return mode
        }
    }

    private func makeRoutes(_ config: HotkeyConfig, _ modes: [DictationModeConfig], ax: Bool) -> HotkeyRoutes {
        HotkeyRoutes.build(config: config, candidates: ModeHotkeyCandidate.list(modes: modes, prompts: prompts),
                           accessibilityTrusted: ax)
    }

    private func custom(_ hotkey: ModeHotkey?, id: String? = nil, name: String = "會議筆記",
                        prompt: BuiltInPromptID = .meeting, enabled: Bool = true) -> DictationModeConfig {
        DictationModeConfig(id: id ?? customID, name: name, icon: "person.2", isEnabled: enabled,
                            trigger: ModeTrigger(hotkey: hotkey),
                            ai: ModeAI(enabled: .custom(true), promptID: prompt.rawValue))
    }

    private static let allFamilySets: [Set<ModifierFamily>] = {
        let all = ModifierFamily.allCases
        return (0..<(1 << all.count)).map { mask in Set(all.indices.filter { mask & (1 << $0) != 0 }.map { all[$0] }) }
    }()

    // MARK: Same as before modes

    /// Every trigger × combination × 說話改字 / 翻譯 modifier × permission: the modes route exactly
    /// what `HotkeyConfig.variant(for:)` and `HotkeySelection.comboBindings` did.
    func testMigratedModesRouteExactlyLikeThePreModesVariants() throws {
        let triggers: [TriggerKey] = [.rightOption, .rightControl, .rightCommand, .fn,
                                      try XCTUnwrap(TriggerKey.from(keyCode: KeyCodes.leftShift)),
                                      try XCTUnwrap(TriggerKey.from(keyCode: KeyCodes.functionKeys[4]))]
        let combos = [KeyCombo.optionSpace, KeyCombo(keyCode: KeyCodes.space, modifiers: [.control, .option], keyLabel: "Space"),
                      KeyCombo(keyCode: 0x02, modifiers: [.command, .shift], keyLabel: "D")]
        var checked = 0
        for trigger in triggers {
            for combo in combos {
                for edit in VariantModifier.allCases {
                    for translate in VariantModifier.allCases {
                        let config = HotkeyConfig(trigger: trigger, combo: combo, mode: .toggle,
                                                  editModifier: edit, translateModifier: translate)
                        let modes = migrated(edit: edit, translate: translate)
                        for ax in [false, true] {
                            let routes = makeRoutes(config, modes, ax: ax)
                            for extras in Self.allFamilySets {
                                XCTAssertEqual(routes.variant(for: extras), config.variant(for: extras),
                                               "\(config.logDescription) ax=\(ax) extras=\(extras)")
                            }
                            XCTAssertEqual(routes.comboBindings(base: combo),
                                           HotkeySelection.comboBindings(for: config, includeEdit: ax),
                                           "\(config.logDescription) ax=\(ax)")
                            XCTAssertTrue(routes.combinations.isEmpty)
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 6 * 3 * 5 * 5 * 2)
    }

    func testStateMachineWithRoutesStillSendsEditAndTranslate() {
        let config = HotkeyConfig()
        var m = HotkeyStateMachine(config: config)
        m.routes = makeRoutes(config, migrated(edit: .shift, translate: .control), ax: true)
        XCTAssertEqual(tap(&m, extra: shiftDown, at: 0), [.tap(.edit)])
        XCTAssertEqual(tap(&m, extra: controlDown, at: 1), [.tap(.translate)])
        XCTAssertEqual(tap(&m, extra: 0, at: 2), [.tap(.dictate)])
        XCTAssertEqual(tap(&m, extra: commandDown, at: 3), [])
    }

    func testMirroredSettingsFields() {
        XCTAssertTrue(HotkeyRoutes.legacyModifiers(in: migrated(edit: .shift, translate: .control)) == (.shift, .control))
        XCTAssertTrue(HotkeyRoutes.legacyModifiers(in: migrated(edit: .none, translate: .option)) == (.none, .option))
        var modes = migrated(edit: .shift, translate: .control)
        modes[3].isEnabled = false // 改寫 off: an older build must not fire it either
        modes[2].trigger.hotkey = ModeShortcut.combination(ctrlOptM).modeHotkey
        XCTAssertTrue(HotkeyRoutes.legacyModifiers(in: modes) == (.none, .none))
    }

    // MARK: A mode of the user's, triggered by its own hotkey

    /// The completion check of M2: a new mode with ⌃⌥M starts a recording in that mode, with or
    /// without Accessibility, and the request it produces runs that mode.
    func testCustomModeWithItsOwnCombinationProducesItsRequest() throws {
        let modes = migrated(edit: .shift, translate: .control) + [custom(ModeShortcut.combination(ctrlOptM).modeHotkey)]
        for ax in [false, true] {
            let routes = makeRoutes(HotkeyConfig(), modes, ax: ax)
            XCTAssertEqual(routes.combinations, [ModeComboBinding(modeID: customID, combo: ctrlOptM, variant: .mode(customID))])
            XCTAssertNil(routes.problems[customID])
        }
        let start = try XCTUnwrap(DictationStart.plan(.mode(customID), translateLocked: false, modes: modes,
                                                      prompts: prompts, defaults: defaults))
        XCTAssertEqual(start.modeID, customID)
        XCTAssertEqual(start.icon, "person.2")
        XCTAssertTrue(start.showsMark)
        XCTAssertTrue(start.requiresLLM)
        XCTAssertFalse(start.needsSelection)
        let request = start.request(id: "r1")
        XCTAssertEqual(request.modeID, customID)
        XCTAssertEqual(request.mode, .dictate)
        let resolved = ModeResolver.resolve(request, modes: modes, prompts: prompts, defaults: defaults)
        XCTAssertEqual(resolved.modeID, customID)
        XCTAssertEqual(resolved.llm?.prompt.id, BuiltInPromptID.meeting.rawValue)
    }

    func testCustomModeWithAModifierWorksOnBothListeners() throws {
        let modes = migrated(edit: .shift, translate: .control) + [custom(.withMainTrigger("command"))]
        let config = HotkeyConfig()
        // Event tap (Accessibility): hold ⌘ and tap right ⌥.
        var m = HotkeyStateMachine(config: config)
        m.routes = makeRoutes(config, modes, ax: true)
        XCTAssertEqual(tap(&m, extra: commandDown, at: 0), [.tap(.mode(customID))])
        // Hold mode: the same press begins and ends a hold.
        var hold = HotkeyStateMachine(config: HotkeyConfig(mode: .hold))
        hold.routes = makeRoutes(HotkeyConfig(mode: .hold), modes, ax: true)
        var events: [HotkeyEvent] = []
        for (time, input) in [(0.0, HotkeyInput.flagsChanged(keyCode: KeyCodes.rightOption, flags: rightOptionDown | commandDown)),
                              (0.25, .tick), (1.0, .flagsChanged(keyCode: KeyCodes.rightOption, flags: commandDown))] {
            if let event = hold.handle(input, at: time).event { events.append(event) }
        }
        XCTAssertEqual(events, [.holdBegan(.mode(customID)), .holdEnded])
        // Key combination (no Accessibility): ⌥⌘Space.
        let bindings = makeRoutes(config, modes, ax: false).comboBindings(base: config.combo)
        XCTAssertTrue(bindings.contains(ComboBinding(combo: KeyCombo.optionSpace.adding(.command), variant: .mode(customID))))
        let start = try XCTUnwrap(DictationStart.plan(.mode(customID), translateLocked: false, modes: modes,
                                                      prompts: prompts, defaults: defaults))
        XCTAssertEqual(start.request().modeID, customID)
    }

    func testDisabledModeHasNoHotkey() {
        let modes = migrated(edit: .shift, translate: .control)
            + [custom(ModeShortcut.combination(ctrlOptM).modeHotkey, enabled: false)]
        let routes = makeRoutes(HotkeyConfig(), modes, ax: true)
        XCTAssertTrue(routes.combinations.isEmpty)
        XCTAssertNil(routes.problems[customID])
    }

    func testRewritePromptNeedsAccessibilityOnTheCombinationPath() {
        let mine = custom(.withMainTrigger("command"), prompt: .rewrite)
        let modes = migrated(edit: .shift, translate: .control) + [mine]
        let without = makeRoutes(HotkeyConfig(), modes, ax: false)
        XCTAssertEqual(without.problems[customID], .needsAccessibility)
        XCTAssertFalse(without.withCombo.contains { $0.variant == .mode(customID) })
        let with = makeRoutes(HotkeyConfig(), modes, ax: true)
        XCTAssertNil(with.problems[customID])
        XCTAssertEqual(with.variant(for: [.command]), .mode(customID))
    }

    // MARK: Conflicts

    func testSameModifierAsAnotherModeKeepsTheFirst() {
        let modes = migrated(edit: .shift, translate: .control) + [custom(.withMainTrigger("shift"))]
        let routes = makeRoutes(HotkeyConfig(), modes, ax: true)
        XCTAssertEqual(routes.problems[customID], .sameAsMode("改寫"))
        XCTAssertEqual(routes.variant(for: [.shift]), .edit)
        XCTAssertEqual(routes.problems[customID]?.message, "跟「改寫」重複")
        // 改寫 wins over 翻譯 whatever the list order (the pre-modes rule).
        let both = makeRoutes(HotkeyConfig(), migrated(edit: .shift, translate: .shift), ax: true)
        XCTAssertEqual(both.problems[BuiltInModeID.translate.rawValue], .sameAsMode("改寫"))
    }

    func testSameCombinationAsAnotherMode() {
        let modes = [custom(ModeShortcut.combination(ctrlOptM).modeHotkey),
                     custom(ModeShortcut.combination(KeyCombo(keyCode: 0x2E, modifiers: [.option, .control], keyLabel: "m")).modeHotkey,
                            id: "custom.second", name: "第二個")]
        let routes = makeRoutes(HotkeyConfig(), DictationModeConfig.builtIns + modes, ax: false)
        XCTAssertEqual(routes.combinations.map(\.modeID), [customID])
        XCTAssertEqual(routes.problems["custom.second"], .sameAsMode("會議筆記"))
    }

    func testCombinationClashesWithTheMainHotkey() throws {
        let main = custom(ModeShortcut.combination(.optionSpace).modeHotkey)
        XCTAssertEqual(makeRoutes(HotkeyConfig(), [main], ax: true).problems[customID], .sameAsMainHotkey)
        // ⌥⇧Space is the main combination + 改寫's ⇧.
        let variant = custom(ModeShortcut.combination(KeyCombo.optionSpace.adding(.shift)).modeHotkey)
        XCTAssertEqual(makeRoutes(HotkeyConfig(), migrated(edit: .shift, translate: .control) + [variant], ax: true)
                        .problems[customID], .sameAsMode("改寫"))
        // F5 alone while F5 is the single key.
        var f5Config = HotkeyConfig()
        f5Config.trigger = try XCTUnwrap(TriggerKey.from(keyCode: KeyCodes.functionKeys[4]))
        let f5 = custom(ModeShortcut.combination(KeyCombo(keyCode: KeyCodes.functionKeys[4], modifiers: [], keyLabel: "F5")).modeHotkey)
        XCTAssertEqual(makeRoutes(f5Config, [f5], ax: true).problems[customID], .sameAsMainHotkey)
        // F6 alone is fine.
        let f6 = custom(ModeShortcut.combination(KeyCombo(keyCode: KeyCodes.functionKeys[5], modifiers: [], keyLabel: "F6")).modeHotkey)
        XCTAssertNil(makeRoutes(f5Config, [f6], ax: true).problems[customID])
    }

    func testModifierOfTheTriggerOrTheCombination() {
        // ⌥ held with right ⌥ cannot be told apart (event tap).
        let option = custom(.withMainTrigger("option"))
        XCTAssertEqual(makeRoutes(HotkeyConfig(), [option], ax: true).problems[customID], .sameKindAsTrigger)
        // ⌥ added to ⌥Space is still ⌥Space (key combination path).
        XCTAssertEqual(makeRoutes(HotkeyConfig(), [option], ax: false).problems[customID], .alreadyInCombo("⌥"))
        XCTAssertEqual(ModeHotkeyProblem.alreadyInCombo("⌥").message, "組合鍵已經有 ⌥，不能用")
    }

    func testCombinationsTheSystemOrTypingUse() {
        func problem(_ code: UInt16, _ modifiers: Set<ModifierFamily>) -> ModeHotkeyProblem? {
            ModeComboRules.problem(for: KeyCombo(keyCode: code, modifiers: modifiers, keyLabel: "x"))
        }
        XCTAssertEqual(problem(0x08, [.command]), .common)                  // ⌘C
        XCTAssertEqual(problem(0x06, [.command, .shift]), .common)          // ⇧⌘Z
        XCTAssertEqual(problem(0x0E, [.option]), .common)                   // ⌥E types é
        XCTAssertEqual(problem(0x00, [.control]), .common)                  // ⌃A
        XCTAssertEqual(problem(KeyCodes.space, [.control]), .system)        // input sources
        XCTAssertEqual(problem(KeyCodes.space, [.control, .command]), .system) // emoji
        XCTAssertEqual(problem(0x0C, [.control, .command]), .system)        // lock screen
        XCTAssertEqual(problem(KeyCodes.escape, [.control, .option]), .invalid)
        XCTAssertNil(problem(0x2E, [.control, .option]))                    // ⌃⌥M
        XCTAssertNil(problem(0x2E, [.control, .shift]))                     // ⌃⇧M
        XCTAssertNil(problem(KeyCodes.functionKeys[5], []))                 // F6
        let routes = makeRoutes(HotkeyConfig(), [custom(ModeShortcut.combination(KeyCombo(keyCode: 0x08, modifiers: [.command],
                                                                                        keyLabel: "C")).modeHotkey)], ax: true)
        XCTAssertEqual(routes.problems[customID], .common)
        XCTAssertTrue(routes.combinations.isEmpty)
    }

    // MARK: What a press starts

    func testPlainHotkeySendsThePreModesRequests() throws {
        let modes = DictationModeConfig.builtIns
        let dictate = try XCTUnwrap(DictationStart.plan(.dictate, translateLocked: false, modes: modes, prompts: prompts,
                                                        defaults: defaults))
        XCTAssertEqual(dictate.modeID, BuiltInModeID.dictate.rawValue)
        XCTAssertEqual(dictate.legacyMode, .dictate)
        XCTAssertNil(dictate.requestModeID)
        XCTAssertFalse(dictate.showsMark)
        XCTAssertFalse(dictate.requiresLLM)

        let locked = try XCTUnwrap(DictationStart.plan(.dictate, translateLocked: true, modes: modes, prompts: prompts,
                                                       defaults: defaults))
        XCTAssertEqual(locked.legacyMode, .translate)
        XCTAssertNil(locked.requestModeID)
        XCTAssertEqual(locked.badge, "EN")

        let edit = try XCTUnwrap(DictationStart.plan(.edit, translateLocked: false, modes: modes, prompts: prompts,
                                                     defaults: defaults))
        XCTAssertEqual(edit.legacyMode, .edit)
        XCTAssertNil(edit.requestModeID)
        XCTAssertTrue(edit.needsSelection)
        XCTAssertTrue(edit.requiresLLM)

        let translate = try XCTUnwrap(DictationStart.plan(.translate, translateLocked: false, modes: modes, prompts: prompts,
                                                          defaults: defaults))
        XCTAssertEqual(translate.legacyMode, .translate)
        XCTAssertNil(translate.requestModeID)
        XCTAssertEqual(translate.icon, "translate")
    }

    func testDefaultModeOfTheUsersChoice() throws {
        var modes = DictationModeConfig.builtIns
        for index in modes.indices { modes[index].isDefault = modes[index].id == BuiltInModeID.email.rawValue }
        let start = try XCTUnwrap(DictationStart.plan(.dictate, translateLocked: false, modes: modes, prompts: prompts,
                                                      defaults: defaults))
        XCTAssertEqual(start.modeID, BuiltInModeID.email.rawValue)
        XCTAssertTrue(start.requiresLLM)
        XCTAssertTrue(start.showsMark)
        // DictationRequest() already means the default mode.
        XCTAssertNil(start.requestModeID)
        XCTAssertEqual(ModeResolver.resolve(start.request(), modes: modes, prompts: prompts, defaults: defaults).modeID,
                       BuiltInModeID.email.rawValue)
    }

    func testModesWithTranslateOrRewritePromptsCarryTheirID() throws {
        let translateMine = custom(nil, prompt: .translate)
        let start = try XCTUnwrap(DictationStart.plan(.mode(customID), translateLocked: false,
                                                      modes: DictationModeConfig.builtIns + [translateMine],
                                                      prompts: prompts, defaults: defaults))
        XCTAssertEqual(start.legacyMode, .translate)
        XCTAssertEqual(start.requestModeID, customID)
        let rewriteMine = custom(nil, prompt: .rewrite)
        let rewrite = try XCTUnwrap(DictationStart.plan(.mode(customID), translateLocked: false,
                                                        modes: DictationModeConfig.builtIns + [rewriteMine],
                                                        prompts: prompts, defaults: defaults))
        XCTAssertTrue(rewrite.needsSelection)
        XCTAssertEqual(rewrite.legacyMode, .edit)
        XCTAssertEqual(rewrite.requestModeID, customID)
    }

    func testModeOwnEngineIsWhatTheControllerChecks() throws {
        var mine = custom(nil)
        mine.recognition.engine = .custom(.groqWhisperTurbo)
        let start = try XCTUnwrap(DictationStart.plan(.mode(customID), translateLocked: false,
                                                      modes: DictationModeConfig.builtIns + [mine],
                                                      prompts: prompts, defaults: defaults))
        XCTAssertEqual(start.resolved.sttProvider, .groqWhisperTurbo)
    }

    func testDeletedModeStartsNothing() {
        XCTAssertNil(DictationStart.plan(.mode("gone"), translateLocked: false, modes: DictationModeConfig.builtIns,
                                         prompts: prompts, defaults: defaults))
    }

    func testShortcutRoundTrip() throws {
        let combo = ModeShortcut.combination(ctrlOptM)
        XCTAssertEqual(ModeShortcut(combo.modeHotkey), combo)
        XCTAssertEqual(combo.modeHotkey.modifiers, ["control", "option"])
        let held = ModeShortcut.withTrigger([.shift])
        XCTAssertEqual(ModeShortcut(held.modeHotkey), held)
        XCTAssertEqual(held.modeHotkey, ModeHotkey.withMainTrigger("shift"))
        XCTAssertNil(ModeShortcut(ModeHotkey(kind: .withMainTrigger, modifiers: ["hyper"])))
        XCTAssertNil(ModeShortcut(ModeHotkey(kind: .combination, modifiers: ["control"])))
        XCTAssertEqual(held.keycaps(mainHotkey: ["右 ⌥"]), ["⇧", "右 ⌥"])
        XCTAssertEqual(combo.keycaps(mainHotkey: []), ["⌃", "⌥", "M"])
    }

    func testVariantLogNamesHaveNoNames() {
        XCTAssertEqual(HotkeyVariant.forMode(BuiltInModeID.rewrite.rawValue), .edit)
        XCTAssertEqual(HotkeyVariant.forMode(BuiltInModeID.translate.rawValue), .translate)
        XCTAssertEqual(HotkeyVariant.forMode(customID).logName, "mode:\(customID)")
        XCTAssertEqual(ModeHotkeyProblem.sameAsMode("會議筆記").logName, "sameAsMode")
    }

    // MARK: Helpers

    private func tap(_ m: inout HotkeyStateMachine, extra: UInt64, at t: TimeInterval) -> [HotkeyEvent] {
        [m.handle(.flagsChanged(keyCode: KeyCodes.rightOption, flags: rightOptionDown | extra), at: t).event,
         m.handle(.flagsChanged(keyCode: KeyCodes.rightOption, flags: extra), at: t + 0.1).event].compactMap { $0 }
    }
}
