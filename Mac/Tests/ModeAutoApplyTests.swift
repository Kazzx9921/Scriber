import AppKit
import XCTest
import ScriberCore
import ScriberShared

/// Modes M3 (docs/PRD-模式.md §4, §7.2, §7.5, §7.6): which mode a press runs when an app is in
/// front, what context goes into the request, what happens to the result, when the automatic
/// Return may be pressed, and how existing installs keep their behaviour.
final class ModeAutoApplyTests: XCTestCase {
    private let prompts = PromptLibrary.builtIns
    private let mail = "com.apple.mail"
    private let notesID = "user.notes"

    private var defaults: ModeDefaults {
        ModeDefaults(sttProvider: .elevenLabsScribe, polishProvider: .off, forceTraditional: true,
                     spaceBetweenCJKAndLatin: true, translateTarget: "English")
    }

    private let noLLMKey = ModeReadiness(hasLLMKey: false, readyEngines: Set(STTProviderKind.allCases))

    private func plan(_ variant: HotkeyVariant = .dictate, front: String?, modes: [DictationModeConfig] = DictationModeConfig.builtIns,
                      locked: Bool = false, readiness: ModeReadiness = .everything,
                      defaults: ModeDefaults? = nil) throws -> DictationStart {
        try XCTUnwrap(DictationStart.plan(variant, translateLocked: locked, modes: modes, prompts: prompts,
                                          defaults: defaults ?? self.defaults, frontmostBundleID: front, readiness: readiness))
    }

    private func notes(apps: [String], enabled: Bool = true, engine: STTProviderKind? = nil,
                       context: ModeContextFlags = .none) -> DictationModeConfig {
        DictationModeConfig(id: notesID, name: "筆記", icon: "note.text", isEnabled: enabled,
                            trigger: ModeTrigger(appBundleIDs: apps),
                            recognition: ModeRecognition(engine: engine.map { .custom($0) } ?? .followDefault),
                            ai: ModeAI(enabled: .custom(true), promptID: BuiltInPromptID.bullets.rawValue), context: context)
    }

    private func setting(_ id: BuiltInModeID, in modes: [DictationModeConfig],
                         _ change: (inout DictationModeConfig) -> Void) -> [DictationModeConfig] {
        modes.map { mode in
            var mode = mode
            if mode.id == id.rawValue { change(&mode) }
            return mode
        }
    }

    // MARK: Which mode (§7.2)

    func testShippedEmailRunsInMailWithAnAIKey() throws {
        let start = try plan(front: mail)
        XCTAssertEqual(start.modeID, BuiltInModeID.email.rawValue)
        XCTAssertEqual(start.autoAppliedFor, mail)
        XCTAssertEqual(start.request(id: "x"), DictationRequest(id: "x", mode: .dictate, modeID: BuiltInModeID.email.rawValue))
        XCTAssertTrue(start.showsMark, "the HUD shows Email's icon")
        XCTAssertEqual(start.icon, "envelope")
        XCTAssertTrue(start.autoApplySkipped.isEmpty)
    }

    func testEmailWithoutAnAIKeyFallsThroughToTheDefaultMode() throws {
        let start = try plan(front: mail, readiness: noLLMKey)
        XCTAssertEqual(start.modeID, BuiltInModeID.dictate.rawValue)
        XCTAssertNil(start.autoAppliedFor)
        XCTAssertEqual(start.autoApplySkipped, ["builtin.email:no-llm-key"])
        XCTAssertFalse(start.requiresLLM, "plain dictation: nothing to refuse")
        XCTAssertEqual(start.request(id: "x"), DictationRequest(id: "x"), "exactly the pre-modes request")
        XCTAssertFalse(start.showsMark)
    }

    func testDisabledModeAndOtherAppsDoNotApply() throws {
        let emailOff = setting(.email, in: DictationModeConfig.builtIns) { $0.isEnabled = false }
        let off = try plan(front: mail, modes: emailOff)
        XCTAssertEqual(off.modeID, BuiltInModeID.dictate.rawValue)
        XCTAssertNil(off.autoAppliedFor)
        XCTAssertTrue(off.autoApplySkipped.isEmpty, "a disabled mode is not even a candidate")

        for front in ["com.apple.Safari", "", nil] as [String?] {
            let start = try plan(front: front)
            XCTAssertEqual(start.modeID, BuiltInModeID.dictate.rawValue, "\(front ?? "nil")")
            XCTAssertNil(start.autoAppliedFor)
        }
    }

    func testAModesOwnHotkeyWinsOverAutoApply() throws {
        let modes = DictationModeConfig.builtIns + [notes(apps: [mail])]
        XCTAssertEqual(try plan(.translate, front: mail, modes: modes).modeID, BuiltInModeID.translate.rawValue)
        XCTAssertEqual(try plan(.edit, front: mail, modes: modes).modeID, BuiltInModeID.rewrite.rawValue)
        XCTAssertEqual(try plan(.mode(BuiltInModeID.assistant.rawValue), front: mail, modes: modes).modeID,
                       BuiltInModeID.assistant.rawValue)
        XCTAssertNil(try plan(.translate, front: mail, modes: modes).autoAppliedFor)
    }

    func testEarlierInTheListWinsAndAModeThatCannotRunIsPassedOver() throws {
        // Email (shipped, earlier) and the user's mode both list Mail.
        let both = DictationModeConfig.builtIns + [notes(apps: [mail])]
        XCTAssertEqual(try plan(front: mail, modes: both).modeID, BuiltInModeID.email.rawValue)
        // Moved to the top: the user's mode wins.
        let reordered = [notes(apps: [mail])] + DictationModeConfig.builtIns
        XCTAssertEqual(try plan(front: mail, modes: reordered).modeID, notesID)
        // The first one's engine has no key: the next one runs.
        let whisperFirst = [notes(apps: [mail], engine: .groqWhisperLarge)] + DictationModeConfig.builtIns
        let readiness = ModeReadiness(hasLLMKey: true, readyEngines: [.elevenLabsScribe])
        let start = try plan(front: mail, modes: whisperFirst, readiness: readiness)
        XCTAssertEqual(start.modeID, BuiltInModeID.email.rawValue)
        XCTAssertEqual(start.autoApplySkipped, ["\(notesID):engine"])
        // Neither can run: the default mode.
        let none = try plan(front: mail, modes: whisperFirst,
                            readiness: ModeReadiness(hasLLMKey: false, readyEngines: [.elevenLabsScribe]))
        XCTAssertEqual(none.modeID, BuiltInModeID.dictate.rawValue)
        XCTAssertEqual(none.autoApplySkipped, ["\(notesID):engine", "builtin.email:no-llm-key"])
    }

    func testAutoApplyWinsOverTheCurrentModeIncludingTheTranslateLock() throws {
        let locked = try plan(front: mail, locked: true)
        XCTAssertEqual(locked.modeID, BuiltInModeID.email.rawValue)
        XCTAssertEqual(locked.autoAppliedFor, mail)
        let elsewhere = try plan(front: "com.apple.Safari", locked: true)
        XCTAssertEqual(elsewhere.modeID, BuiltInModeID.translate.rawValue)
        XCTAssertEqual(elsewhere.request(id: "x"), DictationRequest(id: "x", mode: .translate))
        // Email is the default already: nothing was "applied", nothing extra in the HUD for that.
        let emailDefault = setting(.email, in: setting(.dictate, in: DictationModeConfig.builtIns) { $0.isDefault = false }) {
            $0.isDefault = true
        }
        let same = try plan(front: mail, modes: emailDefault)
        XCTAssertEqual(same.modeID, BuiltInModeID.email.rawValue)
        XCTAssertNil(same.autoAppliedFor)
    }

    func testAutoAppliedPlainDictationStillShowsItsIcon() throws {
        // 潤飾 is the default; 聽寫 is set to apply in Terminal.
        var modes = setting(.dictate, in: DictationModeConfig.builtIns) {
            $0.isDefault = false
            $0.trigger.appBundleIDs = ["com.apple.Terminal"]
        }
        modes = setting(.polish, in: modes) { $0.isDefault = true }
        let start = try plan(front: "com.apple.Terminal", modes: modes)
        XCTAssertEqual(start.modeID, BuiltInModeID.dictate.rawValue)
        XCTAssertEqual(start.autoAppliedFor, "com.apple.Terminal")
        XCTAssertTrue(start.showsMark)
        XCTAssertEqual(start.icon, "mic")
        XCTAssertEqual(try plan(front: "com.apple.Safari", modes: modes).modeID, BuiltInModeID.polish.rawValue)
    }

    // MARK: Context (§7.6)

    func testContextGoesIntoTheRequestOnlyWhenTheModeAsks() throws {
        let given = DictationStart.Context(appName: "Mail", clipboard: "會議改到三點")
        // Shipped modes ask for nothing (改寫's selection aside).
        for id in BuiltInModeID.allCases {
            let start = try plan(.mode(id.rawValue), front: nil)
            XCTAssertFalse(start.wantsClipboard, id.rawValue)
            XCTAssertFalse(start.wantsAppName, id.rawValue)
            let request = start.request(id: "x", context: given)
            XCTAssertNil(request.clipboardText, id.rawValue)
            XCTAssertNil(request.appName, id.rawValue)
            XCTAssertEqual(start.needsSelection, id == .rewrite, id.rawValue)
        }
        // Only the clipboard asked for.
        let clipOnly = DictationStart.plan(.mode(notesID), translateLocked: false,
                                           modes: DictationModeConfig.builtIns + [notes(apps: [], context: ModeContextFlags(clipboard: true))],
                                           prompts: prompts, defaults: defaults)
        let clip = try XCTUnwrap(clipOnly)
        XCTAssertTrue(clip.wantsClipboard)
        XCTAssertFalse(clip.wantsAppName)
        XCTAssertFalse(clip.needsSelection)
        let request = clip.request(id: "x", context: given)
        XCTAssertEqual(request.clipboardText, "會議改到三點")
        XCTAssertNil(request.appName)
        // All three.
        let all = try XCTUnwrap(DictationStart.plan(.mode(notesID), translateLocked: false,
                                                     modes: DictationModeConfig.builtIns + [notes(apps: [], context: ModeContextFlags(selectedText: true, clipboard: true, appName: true))],
                                                     prompts: prompts, defaults: defaults))
        XCTAssertTrue(all.needsSelection)
        XCTAssertFalse(all.selectionRequired, "context only: no ⌘C, no fallback to dictation")
        XCTAssertEqual(all.request(id: "x", context: given).appName, "Mail")
        // Empty values are left out; long ones are capped.
        let long = String(repeating: "字", count: ModeContextLimit.characters + 10)
        let capped = all.request(id: "x", context: DictationStart.Context(appName: "  ", clipboard: long))
        XCTAssertNil(capped.appName)
        XCTAssertEqual(capped.clipboardText?.count, ModeContextLimit.characters)
        let longName = String(repeating: "A", count: 200)
        XCTAssertEqual(all.request(id: "x", context: DictationStart.Context(appName: longName)).appName?.count, ModeContextLimit.appName)
    }

    func testNoContextWhenTheModesAIDoesNotRun() throws {
        var mode = notes(apps: [], context: ModeContextFlags(selectedText: true, clipboard: true, appName: true))
        mode.ai = ModeAI(enabled: .custom(false))
        let start = try XCTUnwrap(DictationStart.plan(.mode(notesID), translateLocked: false,
                                                       modes: DictationModeConfig.builtIns + [mode], prompts: prompts,
                                                       defaults: defaults))
        XCTAssertFalse(start.wantsClipboard)
        XCTAssertFalse(start.wantsAppName)
        XCTAssertFalse(start.needsSelection)
        let request = start.request(id: "x", context: DictationStart.Context(appName: "Mail", clipboard: "秘密"))
        XCTAssertNil(request.clipboardText)
        XCTAssertNil(request.appName)
    }

    func testRewriteStillRequiresItsSelection() throws {
        let rewrite = try plan(.edit, front: nil)
        XCTAssertTrue(rewrite.needsSelection)
        XCTAssertTrue(rewrite.selectionRequired)
    }

    // MARK: Clipboard gate

    private struct FakeClipboard: ClipboardSource {
        var typeIdentifiers: Set<String>
        var text: String?
        /// Counts reads of the content (the gate must not read it when it skips).
        let reads = Counter()

        func plainText() -> String? {
            reads.count += 1
            return text
        }

        final class Counter: @unchecked Sendable { var count = 0 }
    }

    private let plain: Set<String> = ["public.utf8-plain-text"]

    func testClipboardGate() {
        let ok = FakeClipboard(typeIdentifiers: plain, text: "會議記錄草稿")
        XCTAssertEqual(ClipboardContext.read(ok, canRead: true), .text("會議記錄草稿"))
        XCTAssertEqual(ok.reads.count, 1)

        // Password managers: never read.
        let concealed = FakeClipboard(typeIdentifiers: plain.union([ClipboardContext.concealedType]), text: "hunter2")
        XCTAssertEqual(ClipboardContext.read(concealed, canRead: true), .skipped(.concealed))
        XCTAssertEqual(concealed.reads.count, 0)
        let transient = FakeClipboard(typeIdentifiers: plain.union([ClipboardContext.transientType]), text: "temp")
        XCTAssertEqual(ClipboardContext.read(transient, canRead: true), .skipped(.transient))
        XCTAssertEqual(transient.reads.count, 0)
        // Scriber's own temporary paste carries every marker.
        let ours = FakeClipboard(typeIdentifiers: plain.union(PasteboardMarkers.all.map(\.rawValue)), text: "上一段")
        XCTAssertEqual(ClipboardContext.read(ours, canRead: true), .skipped(.concealed))
        XCTAssertEqual(ours.reads.count, 0)

        // macOS denies reading.
        let denied = FakeClipboard(typeIdentifiers: plain, text: "x")
        XCTAssertEqual(ClipboardContext.read(denied, canRead: false), .skipped(.accessDenied))
        XCTAssertEqual(denied.reads.count, 0)

        // Not text: images, copied files (whose names come along as text).
        let image = FakeClipboard(typeIdentifiers: ["public.png", "public.tiff"], text: nil)
        XCTAssertEqual(ClipboardContext.read(image, canRead: true), .skipped(.notText))
        let files = FakeClipboard(typeIdentifiers: plain.union(["public.file-url"]), text: "報告.pdf")
        XCTAssertEqual(ClipboardContext.read(files, canRead: true), .skipped(.notText))
        XCTAssertEqual(files.reads.count, 0)

        // Empty.
        XCTAssertEqual(ClipboardContext.read(FakeClipboard(typeIdentifiers: plain, text: " \n"), canRead: true), .skipped(.empty))
        XCTAssertEqual(ClipboardContext.read(FakeClipboard(typeIdentifiers: plain, text: nil), canRead: true), .skipped(.empty))

        // Capped like every context.
        let long = String(repeating: "長", count: ModeContextLimit.characters * 2)
        XCTAssertEqual(ClipboardContext.read(FakeClipboard(typeIdentifiers: plain, text: long), canRead: true).text?.count,
                       ModeContextLimit.characters)

        // The log line has no content.
        XCTAssertEqual(ClipboardContext.Outcome.text("秘密內容").logDescription, "chars=4")
        XCTAssertEqual(ClipboardContext.Outcome.skipped(.concealed).logDescription, "skipped=concealed")
    }

    // MARK: Output (§4) and auto-send (§7.5)

    func testOutputRouting() throws {
        XCTAssertEqual(ResultDelivery(output: .paste, autoSend: .none), .paste(autoSend: .none))
        XCTAssertEqual(ResultDelivery(output: .replaceSelection, autoSend: .returnKey), .paste(autoSend: .returnKey))
        XCTAssertEqual(ResultDelivery(output: .copyOnly, autoSend: .returnKey), .copyOnly)
        XCTAssertEqual(ResultDelivery(output: .answer, autoSend: .commandReturn), .answer)
        XCTAssertFalse(ResultDelivery.answer.pastes)
        XCTAssertFalse(ResultDelivery.copyOnly.pastes)
        XCTAssertTrue(ResultDelivery.paste(autoSend: .none).pastes)

        // 助理 shows its answer; the other shipped modes paste.
        for id in BuiltInModeID.allCases {
            let start = try plan(.mode(id.rawValue), front: nil)
            let delivery = ResultDelivery(output: start.resolved.output, autoSend: start.resolved.autoSend)
            XCTAssertEqual(delivery, id == .assistant ? .answer : .paste(autoSend: .none), id.rawValue)
        }
        // A pipeline result for 助理 is routed to the panel, never pasted.
        let assistant = ModeResolver.resolve(DictationRequest(modeID: BuiltInModeID.assistant.rawValue),
                                             modes: DictationModeConfig.builtIns, prompts: prompts, defaults: defaults)
        let result = PipelineResult(rawTranscript: "q", finalText: "a", sttMillis: 0, polishMillis: 0,
                                    sttProvider: .elevenLabsScribe, polishProvider: .groq, modeID: assistant.modeID,
                                    task: assistant.task, output: assistant.output, autoSend: assistant.autoSend)
        XCTAssertEqual(ResultDelivery(output: result.output, autoSend: result.autoSend), .answer)
    }

    func testAutoSendOnlyAfterARealPasteIntoTheSameApp() {
        let returnPaste = ResultDelivery.paste(autoSend: .returnKey)
        XCTAssertEqual(AutoSendGate.key(for: returnPaste, paste: .pasted, sameAppInFront: true, secureInput: false), .returnKey)
        XCTAssertEqual(AutoSendGate.key(for: .paste(autoSend: .commandReturn), paste: .pasted, sameAppInFront: true,
                                        secureInput: false), .commandReturn)
        XCTAssertEqual(AutoSendKey.returnKey, AutoSendKey(keyCode: 0x24, command: false))
        XCTAssertEqual(AutoSendKey.commandReturn, AutoSendKey(keyCode: 0x24, command: true))
        // Default: none.
        XCTAssertNil(AutoSendGate.key(for: .paste(autoSend: .none), paste: .pasted, sameAppInFront: true, secureInput: false))
        XCTAssertEqual(DictationModeConfig(name: "新模式").autoSend, ModeAutoSend.none)
        // Left on the clipboard (no Accessibility, secure input, events refused): never.
        XCTAssertNil(AutoSendGate.key(for: returnPaste, paste: .notPasted, sameAppInFront: true, secureInput: false))
        XCTAssertNil(AutoSendGate.key(for: returnPaste, paste: nil, sameAppInFront: true, secureInput: false))
        // Another app came to the front meanwhile, or a password field took secure input.
        XCTAssertNil(AutoSendGate.key(for: returnPaste, paste: .pasted, sameAppInFront: false, secureInput: false))
        XCTAssertNil(AutoSendGate.key(for: returnPaste, paste: .pasted, sameAppInFront: true, secureInput: true))
        // Copy-only and the answer panel: never, whatever the mode says.
        XCTAssertNil(AutoSendGate.key(for: ResultDelivery(output: .copyOnly, autoSend: .returnKey), paste: .pasted,
                                      sameAppInFront: true, secureInput: false))
        XCTAssertNil(AutoSendGate.key(for: ResultDelivery(output: .answer, autoSend: .returnKey), paste: .pasted,
                                      sameAppInFront: true, secureInput: false))
        XCTAssertLessThan(AutoSendGate.delay, PasteRestorePolicy.restoreDelay)
    }

    func testCopyOnlyMessage() {
        XCTAssertFalse(HUDFeedback.copiedOnly.isProblem)
        XCTAssertLessThanOrEqual(HUDFeedback.copiedOnly.label.count, 6)
    }

    // MARK: Existing installs (Email in Mail)

    private func temporaryStore() throws -> (ModeStore, UserDefaults, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScriberM3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "ScriberM3Tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = ModeStore(fileURL: folder.appendingPathComponent("modes.json"), recents: defaults)
        return (store, defaults, {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    func testNewInstallKeepsEmailInMail() throws {
        let (store, userDefaults, cleanup) = try temporaryStore()
        defer { cleanup() }
        var lines: [String] = []
        XCTAssertEqual(AutoApplyMigration.runIfNeeded(store: store, defaults: userDefaults, existingInstall: false) { lines.append($0) },
                       .keptShipped)
        XCTAssertEqual(store.mode(id: BuiltInModeID.email.rawValue)?.trigger.appBundleIDs, [mail])
        XCTAssertEqual(AutoApplyMigration.runIfNeeded(store: store, defaults: userDefaults, existingInstall: true), .alreadyDone)
        XCTAssertEqual(store.mode(id: BuiltInModeID.email.rawValue)?.trigger.appBundleIDs, [mail], "runs once")
        XCTAssertEqual(lines.count, 1)
    }

    func testExistingInstallDoesNotSuddenlyGetEmailInMail() throws {
        let (store, userDefaults, cleanup) = try temporaryStore()
        defer { cleanup() }
        // What an M1/M2 build wrote: the shipped modes, Email listing Mail (not acted on then).
        _ = ModeMigration.runIfNeeded(store: store, defaults: userDefaults) { _ in }
        XCTAssertEqual(store.mode(id: BuiltInModeID.email.rawValue)?.trigger.appBundleIDs, [mail])
        XCTAssertEqual(AutoApplyMigration.runIfNeeded(store: store, defaults: userDefaults, existingInstall: true), .heldBack)
        let email = try XCTUnwrap(store.mode(id: BuiltInModeID.email.rawValue))
        XCTAssertEqual(email.trigger.appBundleIDs, [])
        // So the main hotkey in Mail does what it did before.
        let start = try XCTUnwrap(DictationStart.plan(.dictate, translateLocked: false, modes: store.snapshot(), prompts: prompts,
                                                       defaults: defaults, frontmostBundleID: mail))
        XCTAssertEqual(start.modeID, BuiltInModeID.dictate.rawValue)
        XCTAssertEqual(start.request(id: "x"), DictationRequest(id: "x"))
        // Everything else about Email is untouched.
        var shipped = DictationModeConfig.builtIn(.email)
        shipped.trigger.appBundleIDs = []
        XCTAssertEqual(email, shipped)
        // The user turns it on again: never taken off a second time.
        var again = email
        again.trigger.appBundleIDs = [mail]
        try store.update(again)
        XCTAssertEqual(AutoApplyMigration.runIfNeeded(store: store, defaults: userDefaults, existingInstall: true), .alreadyDone)
        XCTAssertEqual(store.mode(id: BuiltInModeID.email.rawValue)?.trigger.appBundleIDs, [mail])
        // 還原預設 brings the shipped Mail back.
        try store.restoreDefault(id: BuiltInModeID.email.rawValue)
        XCTAssertEqual(store.mode(id: BuiltInModeID.email.rawValue)?.trigger.appBundleIDs, [mail])
    }

    func testExistingInstallSigns() {
        XCTAssertFalse(AutoApplyMigration.isExistingInstall(onboardingDone: false, modesMigrationVersion: 0, hasAnyKey: false))
        XCTAssertTrue(AutoApplyMigration.isExistingInstall(onboardingDone: true, modesMigrationVersion: 0, hasAnyKey: false))
        XCTAssertTrue(AutoApplyMigration.isExistingInstall(onboardingDone: false, modesMigrationVersion: 1, hasAnyKey: false))
        XCTAssertTrue(AutoApplyMigration.isExistingInstall(onboardingDone: false, modesMigrationVersion: 0, hasAnyKey: true))
    }

}
