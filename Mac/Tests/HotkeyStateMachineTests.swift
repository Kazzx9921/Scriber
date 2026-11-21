import XCTest

final class HotkeyStateMachineTests: XCTestCase {
    // Flags as the event tap reports them.
    private let rightOptionDown = ModifierBits.option | ModifierBits.rightOption
    private let leftOptionDown = ModifierBits.option | ModifierBits.leftOption
    private let shiftDown = ModifierBits.shift | ModifierBits.leftShift
    private let controlDown = ModifierBits.control | ModifierBits.leftControl
    private let commandDown = ModifierBits.command | ModifierBits.leftCommand
    private let keyE: UInt16 = 0x0E
    private let keyA: UInt16 = 0x00
    private let leftArrow: UInt16 = 0x7B

    private func machine(_ mode: TriggerMode = .toggle, trigger: TriggerKey = .rightOption) -> HotkeyStateMachine {
        HotkeyStateMachine(config: HotkeyConfig(trigger: trigger, mode: mode))
    }

    /// Feeds inputs at the given times and collects the events.
    private func run(_ m: inout HotkeyStateMachine, _ steps: [(TimeInterval, HotkeyInput)]) -> [HotkeyEvent] {
        steps.compactMap { m.handle($0.1, at: $0.0).event }
    }

    private func pressRightOption(at t: TimeInterval, extra: UInt64 = 0) -> (TimeInterval, HotkeyInput) {
        (t, .flagsChanged(keyCode: KeyCodes.rightOption, flags: rightOptionDown | extra))
    }

    private func releaseRightOption(at t: TimeInterval, extra: UInt64 = 0) -> (TimeInterval, HotkeyInput) {
        (t, .flagsChanged(keyCode: KeyCodes.rightOption, flags: extra))
    }

    // MARK: Toggle mode

    func testCleanTapDictates() {
        var m = machine()
        let events = run(&m, [pressRightOption(at: 0), releaseRightOption(at: 0.15)])
        XCTAssertEqual(events, [.tap(.dictate)])
    }

    func testOptionCombinationIsIgnoredAndNotSwallowed() {
        var m = machine()
        _ = m.handle(pressRightOption(at: 0).1, at: 0)
        let keyOutput = m.handle(.keyDown(keyCode: keyE, isRepeat: false), at: 0.05)
        XCTAssertFalse(keyOutput.swallow)
        XCTAssertNil(keyOutput.event)
        _ = m.handle(.keyUp(keyCode: keyE), at: 0.08)
        let release = m.handle(releaseRightOption(at: 0.1).1, at: 0.1)
        XCTAssertNil(release.event)
        XCTAssertNotNil(release.note)
    }

    func testOptionClickIsIgnored() {
        var m = machine()
        let events = run(&m, [pressRightOption(at: 0), (0.1, .mouseDown), releaseRightOption(at: 0.2)])
        XCTAssertEqual(events, [])
    }

    func testPressWhileAnotherKeyIsHeldIsIgnored() {
        var m = machine()
        let events = run(&m, [(0, .keyDown(keyCode: keyA, isRepeat: false)), pressRightOption(at: 0.05),
                              releaseRightOption(at: 0.1), (0.12, .keyUp(keyCode: keyA))])
        XCTAssertEqual(events, [])
        // Once the key is up, the next press works again.
        XCTAssertEqual(run(&m, [pressRightOption(at: 1), releaseRightOption(at: 1.1)]), [.tap(.dictate)])
    }

    func testMissedKeyUpExpires() {
        var m = machine()
        // A key-down whose key-up the tap never saw must not block the trigger forever.
        _ = m.handle(.keyDown(keyCode: keyA, isRepeat: false), at: 0)
        XCTAssertEqual(run(&m, [pressRightOption(at: 10), releaseRightOption(at: 10.1)]), [.tap(.dictate)])
    }

    func testLongPressDoesNotStartButStops() {
        var m = machine()
        XCTAssertEqual(run(&m, [pressRightOption(at: 0), releaseRightOption(at: 1.5)]), [])
        m.isRecording = true
        XCTAssertEqual(run(&m, [pressRightOption(at: 5), releaseRightOption(at: 7)]), [.tap(.dictate)])
    }

    func testShiftSelectsEditAndControlSelectsTranslate() {
        var m = machine()
        XCTAssertEqual(run(&m, [pressRightOption(at: 0, extra: shiftDown), releaseRightOption(at: 0.1, extra: shiftDown)]),
                       [.tap(.edit)])
        XCTAssertEqual(run(&m, [pressRightOption(at: 1, extra: controlDown), releaseRightOption(at: 1.1, extra: controlDown)]),
                       [.tap(.translate)])
    }

    func testModifierAddedDuringPressCountsAsVariant() {
        var m = machine()
        let events = run(&m, [
            pressRightOption(at: 0),
            (0.05, .flagsChanged(keyCode: KeyCodes.leftShift, flags: rightOptionDown | shiftDown)),
            releaseRightOption(at: 0.1, extra: shiftDown),
        ])
        XCTAssertEqual(events, [.tap(.edit)])
    }

    func testUnmappedModifierCombinationIsIgnored() {
        var m = machine()
        let release = m.handle(pressRightOption(at: 0, extra: commandDown).1, at: 0)
        XCTAssertNil(release.event)
        let output = m.handle(releaseRightOption(at: 0.1, extra: commandDown).1, at: 0.1)
        XCTAssertNil(output.event)
        XCTAssertEqual(output.note, "trigger ignored: with command (no variant)")
    }

    func testLeftOptionAloneDoesNothingAndBothOptionsIsACombination() {
        var m = machine()
        XCTAssertEqual(run(&m, [(0, .flagsChanged(keyCode: KeyCodes.leftOption, flags: leftOptionDown)),
                                (0.1, .flagsChanged(keyCode: KeyCodes.leftOption, flags: 0))]), [])
        let both = run(&m, [
            (1, .flagsChanged(keyCode: KeyCodes.leftOption, flags: leftOptionDown)),
            (1.05, .flagsChanged(keyCode: KeyCodes.rightOption, flags: leftOptionDown | rightOptionDown)),
            (1.1, .flagsChanged(keyCode: KeyCodes.rightOption, flags: leftOptionDown)),
            (1.2, .flagsChanged(keyCode: KeyCodes.leftOption, flags: 0)),
        ])
        XCTAssertEqual(both, [])
    }

    func testKeyboardsWithoutDeviceBitsStillWork() {
        var m = machine()
        let events = run(&m, [
            (0, .flagsChanged(keyCode: KeyCodes.rightOption, flags: ModifierBits.option)),
            (0.1, .flagsChanged(keyCode: KeyCodes.rightOption, flags: 0)),
        ])
        XCTAssertEqual(events, [.tap(.dictate)])
    }

    func testCapsLockDoesNotMatter() {
        var m = machine()
        let caps = ModifierBits.capsLock
        XCTAssertEqual(run(&m, [pressRightOption(at: 0, extra: caps), releaseRightOption(at: 0.1, extra: caps)]),
                       [.tap(.dictate)])
    }

    // MARK: Escape

    func testEscapeCancelsOnlyWhileRecording() {
        var m = machine()
        let idle = m.handle(.keyDown(keyCode: KeyCodes.escape, isRepeat: false), at: 0)
        XCTAssertNil(idle.event)
        XCTAssertFalse(idle.swallow)
        XCTAssertFalse(m.handle(.keyUp(keyCode: KeyCodes.escape), at: 0.05).swallow)

        m.isRecording = true
        let down = m.handle(.keyDown(keyCode: KeyCodes.escape, isRepeat: false), at: 1)
        XCTAssertEqual(down.event, .escape)
        XCTAssertTrue(down.swallow)
        let repeated = m.handle(.keyDown(keyCode: KeyCodes.escape, isRepeat: true), at: 1.3)
        XCTAssertNil(repeated.event)
        XCTAssertTrue(repeated.swallow)
        m.isRecording = false // the owner cancelled
        XCTAssertTrue(m.handle(.keyUp(keyCode: KeyCodes.escape), at: 1.4).swallow)
        XCTAssertFalse(m.handle(.keyUp(keyCode: KeyCodes.escape), at: 1.5).swallow)
    }

    func testOtherKeysAreNeverSwallowedWhileRecording() {
        var m = machine()
        m.isRecording = true
        XCTAssertFalse(m.handle(.keyDown(keyCode: keyA, isRepeat: false), at: 0).swallow)
        XCTAssertFalse(m.handle(.keyUp(keyCode: keyA), at: 0.1).swallow)
        XCTAssertFalse(m.handle(pressRightOption(at: 1).1, at: 1).swallow)
        XCTAssertFalse(m.handle(releaseRightOption(at: 1.1).1, at: 1.1).swallow)
    }

    // MARK: Hold mode

    func testHoldStartsAfterDelayAndEndsOnRelease() {
        var m = machine(.hold)
        let press = m.handle(pressRightOption(at: 0).1, at: 0)
        XCTAssertEqual(press.tickAfter, HotkeyStateMachine.holdArmDelay)
        XCTAssertNil(press.event)
        // An early tick asks to be called again for the rest of the delay.
        let early = m.handle(.tick, at: 0.1)
        XCTAssertNil(early.event)
        XCTAssertEqual(early.tickAfter ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(m.handle(.tick, at: 0.2).event, .holdBegan(.dictate))
        XCTAssertEqual(m.handle(releaseRightOption(at: 3).1, at: 3).event, .holdEnded)
    }

    func testHoldQuickTapDoesNothing() {
        var m = machine(.hold)
        XCTAssertEqual(run(&m, [pressRightOption(at: 0), releaseRightOption(at: 0.1), (0.2, .tick)]), [])
    }

    func testHoldCombinationBeforeArmingNeverStarts() {
        var m = machine(.hold)
        XCTAssertEqual(run(&m, [pressRightOption(at: 0), (0.1, .keyDown(keyCode: keyE, isRepeat: false)),
                                (0.2, .tick), releaseRightOption(at: 0.4)]), [])
    }

    func testHoldCombinationAfterArmingAborts() {
        var m = machine(.hold)
        let events = run(&m, [pressRightOption(at: 0), (0.2, .tick), (0.5, .keyDown(keyCode: leftArrow, isRepeat: false)),
                              releaseRightOption(at: 0.8)])
        XCTAssertEqual(events, [.holdBegan(.dictate), .holdAborted])
    }

    func testHoldWithVariant() {
        var m = machine(.hold)
        let events = run(&m, [pressRightOption(at: 0, extra: controlDown), (0.25, .tick),
                              releaseRightOption(at: 1, extra: controlDown)])
        XCTAssertEqual(events, [.holdBegan(.translate), .holdEnded])
    }

    func testEscapeDuringHoldDoesNotAlsoEnd() {
        var m = machine(.hold)
        XCTAssertEqual(run(&m, [pressRightOption(at: 0), (0.2, .tick)]), [.holdBegan(.dictate)])
        m.isRecording = true
        XCTAssertEqual(m.handle(.keyDown(keyCode: KeyCodes.escape, isRepeat: false), at: 0.5).event, .escape)
        m.isRecording = false
        XCTAssertNil(m.handle(releaseRightOption(at: 0.8).1, at: 0.8).event)
    }

    // MARK: Other triggers, pause

    func testFnTrigger() {
        var m = machine(trigger: .fn)
        let fn = ModifierBits.secondaryFn
        XCTAssertEqual(run(&m, [(0, .flagsChanged(keyCode: KeyCodes.function, flags: fn)),
                                (0.1, .flagsChanged(keyCode: KeyCodes.function, flags: 0))]), [.tap(.dictate)])
        // Arrow keys carry the Fn flag on their key events; they are not the trigger.
        XCTAssertEqual(run(&m, [(1, .keyDown(keyCode: leftArrow, isRepeat: false)), (1.1, .keyUp(keyCode: leftArrow))]), [])
        // The 🌐 key code works too.
        XCTAssertEqual(run(&m, [(2, .flagsChanged(keyCode: KeyCodes.globe, flags: fn)),
                                (2.1, .flagsChanged(keyCode: KeyCodes.globe, flags: 0))]), [.tap(.dictate)])
    }

    func testRightCommandTriggerIgnoresCommandShortcuts() {
        var m = machine(trigger: .rightCommand)
        let rightCommandDown = ModifierBits.command | ModifierBits.rightCommand
        XCTAssertEqual(run(&m, [(0, .flagsChanged(keyCode: KeyCodes.rightCommand, flags: rightCommandDown)),
                                (0.05, .keyDown(keyCode: 0x08, isRepeat: false)), // ⌘C
                                (0.08, .keyUp(keyCode: 0x08)),
                                (0.1, .flagsChanged(keyCode: KeyCodes.rightCommand, flags: 0))]), [])
        XCTAssertEqual(run(&m, [(1, .flagsChanged(keyCode: KeyCodes.rightCommand, flags: rightCommandDown)),
                                (1.1, .flagsChanged(keyCode: KeyCodes.rightCommand, flags: 0))]), [.tap(.dictate)])
    }

    func testPausedIgnoresEverything() {
        var m = machine()
        m.isPaused = true
        XCTAssertEqual(run(&m, [pressRightOption(at: 0), releaseRightOption(at: 0.1)]), [])
        m.isRecording = true
        XCTAssertFalse(m.handle(.keyDown(keyCode: KeyCodes.escape, isRepeat: false), at: 1).swallow)
    }

    // MARK: Any modifier, either side

    func testLeftOptionTriggerAndRightOptionIsNotIt() throws {
        let leftOption = try XCTUnwrap(TriggerKey.from(keyCode: KeyCodes.leftOption))
        var m = machine(trigger: leftOption)
        XCTAssertEqual(run(&m, [(0, .flagsChanged(keyCode: KeyCodes.leftOption, flags: leftOptionDown)),
                                (0.1, .flagsChanged(keyCode: KeyCodes.leftOption, flags: 0))]), [.tap(.dictate)])
        // The right copy is a different key.
        XCTAssertEqual(run(&m, [pressRightOption(at: 1), releaseRightOption(at: 1.1)]), [])
        // ⌥E with the left Option is still just typing.
        XCTAssertEqual(run(&m, [(2, .flagsChanged(keyCode: KeyCodes.leftOption, flags: leftOptionDown)),
                                (2.05, .keyDown(keyCode: keyE, isRepeat: false)), (2.08, .keyUp(keyCode: keyE)),
                                (2.1, .flagsChanged(keyCode: KeyCodes.leftOption, flags: 0))]), [])
    }

    func testShiftTriggerCannotAlsoBeTheEditVariant() throws {
        let rightShift = try XCTUnwrap(TriggerKey.from(keyCode: KeyCodes.rightShift))
        let rightShiftDown = ModifierBits.shift | ModifierBits.rightShift
        var m = machine(trigger: rightShift)
        XCTAssertEqual(run(&m, [(0, .flagsChanged(keyCode: KeyCodes.rightShift, flags: rightShiftDown)),
                                (0.1, .flagsChanged(keyCode: KeyCodes.rightShift, flags: 0))]), [.tap(.dictate)])
        // Shift held while typing a capital letter is not a trigger.
        XCTAssertEqual(run(&m, [(1, .flagsChanged(keyCode: KeyCodes.rightShift, flags: rightShiftDown)),
                                (1.05, .keyDown(keyCode: keyA, isRepeat: false)), (1.08, .keyUp(keyCode: keyA)),
                                (1.1, .flagsChanged(keyCode: KeyCodes.rightShift, flags: 0))]), [])
        XCTAssertNil(m.config.editFamily, "the edit modifier is Shift, the trigger's own family")
    }

    func testLeftCommandTriggerIgnoresShortcuts() throws {
        let leftCommand = try XCTUnwrap(TriggerKey.from(keyCode: KeyCodes.leftCommand))
        let leftCommandDown = ModifierBits.command | ModifierBits.leftCommand
        var m = machine(trigger: leftCommand)
        XCTAssertEqual(run(&m, [(0, .flagsChanged(keyCode: KeyCodes.leftCommand, flags: leftCommandDown)),
                                (0.05, .keyDown(keyCode: 0x08, isRepeat: false)), (0.08, .keyUp(keyCode: 0x08)),
                                (0.1, .flagsChanged(keyCode: KeyCodes.leftCommand, flags: 0))]), [])
        XCTAssertEqual(run(&m, [(1, .flagsChanged(keyCode: KeyCodes.leftCommand, flags: leftCommandDown)),
                                (1.1, .flagsChanged(keyCode: KeyCodes.leftCommand, flags: 0))]), [.tap(.dictate)])
    }

    // MARK: Function keys

    private let f5 = KeyCodes.functionKeys[4]

    private func f5Machine(_ mode: TriggerMode = .toggle) throws -> HotkeyStateMachine {
        machine(mode, trigger: try XCTUnwrap(TriggerKey.from(keyCode: KeyCodes.functionKeys[4])))
    }

    func testFunctionKeyTapIsSwallowedAndDictates() throws {
        var m = try f5Machine()
        let down = m.handle(.keyDown(keyCode: f5, isRepeat: false, flags: ModifierBits.secondaryFn), at: 0)
        XCTAssertTrue(down.swallow, "F5 must not also reach the app")
        XCTAssertNil(down.event)
        XCTAssertTrue(m.handle(.keyDown(keyCode: f5, isRepeat: true), at: 0.05).swallow)
        let up = m.handle(.keyUp(keyCode: f5), at: 0.1)
        XCTAssertTrue(up.swallow)
        XCTAssertEqual(up.event, .tap(.dictate))
    }

    func testFunctionKeyWithVariantModifiers() throws {
        var m = try f5Machine()
        XCTAssertEqual(run(&m, [(0, .keyDown(keyCode: f5, isRepeat: false, flags: shiftDown)), (0.1, .keyUp(keyCode: f5))]),
                       [.tap(.edit)])
        XCTAssertEqual(run(&m, [(1, .keyDown(keyCode: f5, isRepeat: false, flags: controlDown)), (1.1, .keyUp(keyCode: f5))]),
                       [.tap(.translate)])
    }

    func testUnmappedShortcutOnTheFunctionKeyPassesThrough() throws {
        var m = try f5Machine()
        // ⌘F5 (VoiceOver) is not Scriber's: not swallowed, no event.
        let down = m.handle(.keyDown(keyCode: f5, isRepeat: false, flags: commandDown), at: 0)
        XCTAssertFalse(down.swallow)
        let up = m.handle(.keyUp(keyCode: f5), at: 0.1)
        XCTAssertFalse(up.swallow)
        XCTAssertNil(up.event)
    }

    func testFunctionKeyWhileTypingIsNotATrigger() throws {
        var m = try f5Machine()
        _ = m.handle(.keyDown(keyCode: keyA, isRepeat: false), at: 0)
        let down = m.handle(.keyDown(keyCode: f5, isRepeat: false), at: 0.05)
        XCTAssertFalse(down.swallow)
        XCTAssertNil(m.handle(.keyUp(keyCode: f5), at: 0.1).event)
        _ = m.handle(.keyUp(keyCode: keyA), at: 0.12)
        // Another key during the press makes it a combination too.
        XCTAssertEqual(run(&m, [(1, .keyDown(keyCode: f5, isRepeat: false)), (1.05, .keyDown(keyCode: keyE, isRepeat: false)),
                                (1.08, .keyUp(keyCode: keyE)), (1.1, .keyUp(keyCode: f5))]), [])
    }

    func testFunctionKeyHoldMode() throws {
        var m = try f5Machine(.hold)
        let down = m.handle(.keyDown(keyCode: f5, isRepeat: false), at: 0)
        XCTAssertEqual(down.tickAfter, HotkeyStateMachine.holdArmDelay)
        XCTAssertEqual(m.handle(.tick, at: 0.2).event, .holdBegan(.dictate))
        XCTAssertTrue(m.handle(.keyDown(keyCode: f5, isRepeat: true), at: 0.6).swallow)
        let up = m.handle(.keyUp(keyCode: f5), at: 2)
        XCTAssertEqual(up.event, .holdEnded)
        XCTAssertTrue(up.swallow)
    }

    func testFunctionKeyStopsRecordingWithAnyModifiers() throws {
        var m = try f5Machine()
        m.isRecording = true
        XCTAssertEqual(run(&m, [(0, .keyDown(keyCode: f5, isRepeat: false, flags: commandDown)), (3, .keyUp(keyCode: f5))]),
                       [.tap(.dictate)])
    }

    func testOtherFunctionKeysAreUntouched() throws {
        var m = try f5Machine()
        let f6 = KeyCodes.functionKeys[5]
        XCTAssertFalse(m.handle(.keyDown(keyCode: f6, isRepeat: false), at: 0).swallow)
        XCTAssertFalse(m.handle(.keyUp(keyCode: f6), at: 0.1).swallow)
    }

    func testPausedFunctionKeyIsNotSwallowed() throws {
        var m = try f5Machine()
        m.isPaused = true
        XCTAssertFalse(m.handle(.keyDown(keyCode: f5, isRepeat: false), at: 0).swallow)
        XCTAssertFalse(m.handle(.keyUp(keyCode: f5), at: 0.1).swallow)
    }
}

final class HotkeyConfigTests: XCTestCase {
    func testDefaults() {
        let config = HotkeyConfig.default
        XCTAssertEqual(config.trigger, .rightOption)
        XCTAssertEqual(config.mode, .toggle)
        XCTAssertEqual(config.variant(for: []), .dictate)
        XCTAssertEqual(config.variant(for: [.shift]), .edit)
        XCTAssertEqual(config.variant(for: [.control]), .translate)
        XCTAssertNil(config.variant(for: [.shift, .control]))
    }

    func testVariantOnTheTriggersOwnModifierIsUnusable() {
        var config = HotkeyConfig(trigger: .rightControl, mode: .toggle, editModifier: .shift, translateModifier: .control)
        XCTAssertNil(config.translateFamily)
        XCTAssertEqual(config.editFamily, .shift)
        XCTAssertNotNil(config.problem(for: .control))
        XCTAssertNil(config.variant(for: [.control]))
        config.translateModifier = .shift
        XCTAssertEqual(config.variant(for: [.shift]), .edit, "edit wins when both use the same key")
        XCTAssertNotNil(config.problem(for: config.translateModifier))
    }

    func testPersistenceRoundTripAndMissingFields() throws {
        let suite = "com.geekaz.Scriber.mac.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(HotkeyConfig.load(from: defaults), .default)
        let custom = HotkeyConfig(trigger: .fn, mode: .hold, editModifier: .command, translateModifier: .none)
        custom.save(to: defaults)
        XCTAssertEqual(HotkeyConfig.load(from: defaults), custom)

        defaults.set(Data(#"{"trigger":"rightCommand"}"#.utf8), forKey: HotkeyConfig.defaultsKey)
        let partial = HotkeyConfig.load(from: defaults)
        XCTAssertEqual(partial.trigger, .rightCommand)
        XCTAssertEqual(partial.mode, .toggle)
        XCTAssertEqual(partial.editModifier, .shift)

        defaults.set(Data(#"{"trigger":"capsLock","mode":"sideways"}"#.utf8), forKey: HotkeyConfig.defaultsKey)
        XCTAssertEqual(HotkeyConfig.load(from: defaults), .default)
    }

    func testTriggerKeyLookup() {
        XCTAssertEqual(TriggerKey.from(keyCode: KeyCodes.rightOption), .rightOption)
        XCTAssertEqual(TriggerKey.from(keyCode: KeyCodes.globe), .fn)
        XCTAssertEqual(TriggerKey.from(keyCode: KeyCodes.leftOption)?.shortName, "左 ⌥")
        XCTAssertEqual(TriggerKey.from(keyCode: KeyCodes.leftShift)?.displayName, "左邊的 Shift ⇧")
        XCTAssertEqual(TriggerKey.from(keyCode: KeyCodes.functionKeys[11])?.shortName, "F12")
        XCTAssertNil(TriggerKey.from(keyCode: KeyCodes.capsLock))
        XCTAssertNil(TriggerKey.from(keyCode: KeyCodes.space))
        XCTAssertNil(TriggerKey.from(keyCode: 0x00)) // A
    }

    func testTriggerKeyRejections() {
        XCTAssertNil(TriggerKey.rejection(forKeyCode: KeyCodes.rightCommand))
        XCTAssertNil(TriggerKey.rejection(forKeyCode: KeyCodes.functionKeys[0]))
        XCTAssertEqual(TriggerKey.rejection(forKeyCode: KeyCodes.capsLock), .capsLock)
        XCTAssertEqual(TriggerKey.rejection(forKeyCode: KeyCodes.escape), .escape)
        XCTAssertEqual(TriggerKey.rejection(forKeyCode: 0x00), .typingKey)
        XCTAssertEqual(TriggerKey.rejection(forKeyCode: KeyCodes.space), .typingKey)
    }

    func testEveryTriggerKeyRoundTripsAndOldNamesStillLoad() throws {
        var all: [TriggerKey] = [.fn]
        for code in [KeyCodes.leftShift, KeyCodes.rightShift, KeyCodes.leftControl, KeyCodes.rightControl,
                     KeyCodes.leftOption, KeyCodes.rightOption, KeyCodes.leftCommand, KeyCodes.rightCommand] + KeyCodes.functionKeys {
            all.append(try XCTUnwrap(TriggerKey.from(keyCode: code)))
        }
        XCTAssertEqual(Set(all).count, 29)
        for key in all {
            XCTAssertEqual(TriggerKey(rawValue: key.rawValue), key, key.rawValue)
            var config = HotkeyConfig()
            config.trigger = key
            let data = try JSONEncoder().encode(config)
            XCTAssertEqual(try JSONDecoder().decode(HotkeyConfig.self, from: data).trigger, key)
        }
        // The first version saved these four names.
        XCTAssertEqual(TriggerKey(rawValue: "rightOption"), .rightOption)
        XCTAssertEqual(TriggerKey(rawValue: "rightCommand"), .rightCommand)
        XCTAssertEqual(TriggerKey(rawValue: "rightControl"), .rightControl)
        XCTAssertEqual(TriggerKey(rawValue: "fn"), .fn)
        XCTAssertNil(TriggerKey(rawValue: "f21"))
        XCTAssertNil(TriggerKey(rawValue: "capsLock"))
        XCTAssertNil(TriggerKey(rawValue: "middleOption"))
    }
}
