import XCTest

/// Which hotkey works given the Accessibility permission and the two listeners' states, which
/// combinations get registered, and the key combination model.
final class HotkeySelectionTests: XCTestCase {
    private let config = HotkeyConfig()

    // MARK: Plan (which listeners run)

    func testWithoutAccessibilityOnlyTheCombinationRuns() {
        let plan = HotkeySelection.plan(accessibilityTrusted: false, tapRunning: false, paused: false)
        XCTAssertEqual(plan, .init(runTap: false, registerCombo: true))
    }

    func testCombinationStaysUntilTheTapIsActuallyRunning() {
        // Just granted: the tap is starting, the combination must keep working meanwhile.
        let starting = HotkeySelection.plan(accessibilityTrusted: true, tapRunning: false, paused: false)
        XCTAssertEqual(starting, .init(runTap: true, registerCombo: true))
        let running = HotkeySelection.plan(accessibilityTrusted: true, tapRunning: true, paused: false)
        XCTAssertEqual(running, .init(runTap: true, registerCombo: false))
    }

    func testRevokedAccessibilityBringsTheCombinationBack() {
        // A tap that is still marked running cannot matter once the permission is gone.
        let plan = HotkeySelection.plan(accessibilityTrusted: false, tapRunning: true, paused: false)
        XCTAssertEqual(plan, .init(runTap: false, registerCombo: true))
    }

    func testPausedReleasesTheCombination() {
        let plan = HotkeySelection.plan(accessibilityTrusted: false, tapRunning: false, paused: true)
        XCTAssertFalse(plan.registerCombo)
    }

    // MARK: Active hotkey (what the UI shows)

    func testNoAccessibilityShowsTheCombination() {
        let active = HotkeySelection.active(config: config, accessibilityTrusted: false, tapRunning: false,
                                            combo: .registered, paused: false)
        XCTAssertEqual(active, .combo(.optionSpace))
        XCTAssertEqual(active.keycaps, ["⌥", "Space"])
    }

    func testRunningTapShowsTheSingleKey() {
        let active = HotkeySelection.active(config: config, accessibilityTrusted: true, tapRunning: true,
                                            combo: .off, paused: false)
        XCTAssertEqual(active, .single(.rightOption))
        XCTAssertEqual(active.keycaps, ["右 ⌥"])
    }

    func testTapStartingOrFailedFallsBackToTheCombination() {
        // Accessibility granted, but the tap is not running (yet, or it could not be created).
        let active = HotkeySelection.active(config: config, accessibilityTrusted: true, tapRunning: false,
                                            combo: .registered, paused: false)
        XCTAssertEqual(active, .combo(.optionSpace))
    }

    func testTakenCombinationIsReportedNotHidden() {
        let active = HotkeySelection.active(config: config, accessibilityTrusted: false, tapRunning: false,
                                            combo: .taken(.otherApp), paused: false)
        XCTAssertEqual(active, .unavailable(.comboTaken(.otherApp)))
        XCTAssertFalse(active.isWorking)
        XCTAssertEqual(active.keycaps, [])
    }

    func testTakenCombinationDoesNotMatterOnceTheSingleKeyRuns() {
        let active = HotkeySelection.active(config: config, accessibilityTrusted: true, tapRunning: true,
                                            combo: .taken(.system), paused: false)
        XCTAssertEqual(active, .single(.rightOption))
    }

    func testPausedAndStarting() {
        XCTAssertEqual(HotkeySelection.active(config: config, accessibilityTrusted: true, tapRunning: true,
                                              combo: .off, paused: true), .unavailable(.paused))
        XCTAssertEqual(HotkeySelection.active(config: config, accessibilityTrusted: false, tapRunning: false,
                                              combo: .off, paused: false), .unavailable(.starting))
    }

    func testActiveFollowsTheConfiguredKeys() {
        var custom = config
        custom.trigger = .rightCommand
        custom.combo = KeyCombo(keyCode: 0x02, modifiers: [.control, .option], keyLabel: "D")
        XCTAssertEqual(HotkeySelection.active(config: custom, accessibilityTrusted: true, tapRunning: true,
                                              combo: .off, paused: false), .single(.rightCommand))
        XCTAssertEqual(HotkeySelection.active(config: custom, accessibilityTrusted: false, tapRunning: false,
                                              combo: .registered, paused: false).keycaps, ["⌃", "⌥", "D"])
    }

    // MARK: Escape

    func testEscapeOnlyWhileRecordingOnTheCombinationPath() {
        let comboPlan = HotkeySelection.plan(accessibilityTrusted: false, tapRunning: false, paused: false)
        let tapPlan = HotkeySelection.plan(accessibilityTrusted: true, tapRunning: true, paused: false)
        XCTAssertTrue(HotkeySelection.wantsEscape(recording: true, plan: comboPlan, combo: .registered))
        XCTAssertFalse(HotkeySelection.wantsEscape(recording: false, plan: comboPlan, combo: .registered))
        XCTAssertFalse(HotkeySelection.wantsEscape(recording: true, plan: tapPlan, combo: .off))
        XCTAssertFalse(HotkeySelection.wantsEscape(recording: true, plan: comboPlan, combo: .taken(.otherApp)))
    }

    // MARK: Bindings

    func testDefaultBindingsWithoutAccessibility() {
        // 說話改字 needs Accessibility to read the selection; translate does not.
        let bindings = HotkeySelection.comboBindings(for: config, includeEdit: false)
        XCTAssertEqual(bindings, [
            ComboBinding(combo: .optionSpace, variant: .dictate),
            ComboBinding(combo: .optionSpace.adding(.control), variant: .translate),
        ])
    }

    func testEditBindingWithAccessibility() {
        let bindings = HotkeySelection.comboBindings(for: config, includeEdit: true)
        XCTAssertEqual(bindings.map(\.variant), [.dictate, .edit, .translate])
        XCTAssertEqual(bindings[1].combo.modifiers, [.option, .shift])
    }

    func testVariantWhoseModifierIsInTheCombinationIsLeftOut() {
        var custom = config
        custom.combo = KeyCombo(keyCode: KeyCodes.space, modifiers: [.control, .option], keyLabel: "Space")
        // Translate uses ⌃, already part of ⌃⌥Space.
        let bindings = HotkeySelection.comboBindings(for: custom, includeEdit: true)
        XCTAssertEqual(bindings.map(\.variant), [.dictate, .edit])
    }

    func testSameModifierForBothVariantsKeepsEdit() {
        var custom = config
        custom.translateModifier = .shift // same as edit
        XCTAssertEqual(HotkeySelection.comboBindings(for: custom, includeEdit: true).map(\.variant), [.dictate, .edit])
        XCTAssertEqual(HotkeySelection.comboBindings(for: custom, includeEdit: false).map(\.variant), [.dictate])
    }

    func testVariantsOff() {
        var custom = config
        custom.editModifier = .none
        custom.translateModifier = .none
        XCTAssertEqual(HotkeySelection.comboBindings(for: custom, includeEdit: true).map(\.variant), [.dictate])
    }

    // MARK: KeyCombo

    func testComboDisplayAndCarbonModifiers() {
        let combo = KeyCombo(keyCode: 0x02, modifiers: [.command, .shift, .option, .control], keyLabel: "D")
        XCTAssertEqual(combo.keycaps, ["⌃", "⌥", "⇧", "⌘", "D"])
        XCTAssertEqual(combo.displayName, "⌃⌥⇧⌘ D")
        XCTAssertEqual(combo.carbonModifiers, 0x1B00)
        XCTAssertEqual(KeyCombo.optionSpace.carbonModifiers, 0x0800)
        XCTAssertEqual(KeyCombo.optionSpace.displayName, "⌥ Space")
    }

    func testComboProblems() {
        XCTAssertNil(KeyCombo.problem(keyCode: KeyCodes.space, modifiers: [.option]))
        XCTAssertNil(KeyCombo.problem(keyCode: 0x02, modifiers: [.control, .shift]))
        XCTAssertEqual(KeyCombo.problem(keyCode: 0x02, modifiers: []), .needsModifier)
        XCTAssertEqual(KeyCombo.problem(keyCode: 0x02, modifiers: [.shift]), .needsModifier)
        XCTAssertEqual(KeyCombo.problem(keyCode: KeyCodes.escape, modifiers: [.option]), .reserved)
        XCTAssertEqual(KeyCombo.problem(keyCode: KeyCodes.rightOption, modifiers: [.option]), .reserved)
        // Function keys work alone.
        XCTAssertNil(KeyCombo.problem(keyCode: KeyCodes.functionKeys[4], modifiers: []))
    }

    func testSpecialKeyLabels() {
        XCTAssertEqual(KeyCombo.specialKeyLabel(for: KeyCodes.space), "Space")
        XCTAssertEqual(KeyCombo.specialKeyLabel(for: KeyCodes.functionKeys[0]), "F1")
        XCTAssertEqual(KeyCombo.specialKeyLabel(for: KeyCodes.functionKeys[19]), "F20")
        XCTAssertEqual(KeyCombo.specialKeyLabel(for: KeyCodes.returnKey), "↩")
        XCTAssertNil(KeyCombo.specialKeyLabel(for: 0x02))
    }

    // MARK: Persistence

    func testOldSavedConfigGetsTheDefaultCombination() throws {
        // Saved by the first version, before the combination existed.
        let json = #"{"trigger":"rightCommand","mode":"hold","editModifier":"shift","translateModifier":"control"}"#
        let decoded = try JSONDecoder().decode(HotkeyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.trigger, .rightCommand)
        XCTAssertEqual(decoded.mode, .hold)
        XCTAssertEqual(decoded.combo, .optionSpace)
    }

    func testCombinationRoundTrips() throws {
        var custom = config
        custom.combo = KeyCombo(keyCode: 0x02, modifiers: [.control, .option], keyLabel: "D")
        let data = try JSONEncoder().encode(custom)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyConfig.self, from: data), custom)
    }
}
