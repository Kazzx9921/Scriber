import AppKit
import SwiftUI
import XCTest
import ScriberCore
import ScriberShared

/// Every window and state of the redesign, in light and dark, at the default and a small size.
/// Output: `$SCRIBER_SNAPSHOT_DIR` (see `SnapshotRenderer`). Run with
/// `xcodebuild test -scheme ScriberMacSnapshots`.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    private let mainSize = CGSize(width: WindowManager.mainDefaultSize.width, height: WindowManager.mainDefaultSize.height)
    private let mainSmall = CGSize(width: WindowManager.mainMinimumSize.width, height: WindowManager.mainMinimumSize.height)
    private let onboardingSize = OnboardingView.size

    // MARK: Onboarding

    private func onboarding(_ step: OnboardingView.Step, settings: MacSettings, status: EngineStatus) -> some View {
        OnboardingView(initialStep: step, onFinish: {})
            .environment(settings)
            .environment(status)
    }

    func testOnboarding() throws {
        let fresh = Sample.settings(keys: [])
        let ready = Sample.settings()
        try SnapshotRenderer.renderBoth("01-onboarding-1-welcome", size: onboardingSize) {
            onboarding(.welcome, settings: fresh, status: Sample.status(mic: .notDetermined))
        }
        try SnapshotRenderer.renderBoth("01-onboarding-2-mic-ask", size: onboardingSize) {
            onboarding(.microphone, settings: fresh, status: Sample.status(mic: .notDetermined))
        }
        try SnapshotRenderer.renderBoth("01-onboarding-2-mic-granted", size: onboardingSize) {
            onboarding(.microphone, settings: fresh, status: Sample.status(mic: .granted))
        }
        try SnapshotRenderer.renderBoth("01-onboarding-2-mic-denied", size: onboardingSize) {
            onboarding(.microphone, settings: fresh, status: Sample.status(mic: .denied))
        }
        try SnapshotRenderer.renderBoth("01-onboarding-3-key-empty", size: onboardingSize) {
            onboarding(.apiKey, settings: fresh, status: Sample.status())
        }
        try SnapshotRenderer.renderBoth("01-onboarding-3-key-ready", size: onboardingSize) {
            onboarding(.apiKey, settings: ready, status: Sample.status())
        }
        try SnapshotRenderer.renderBoth("01-onboarding-4-try", size: onboardingSize) {
            onboarding(.tryIt, settings: ready, status: Sample.status())
        }
        try SnapshotRenderer.renderBoth("01-onboarding-4-try-recording", size: onboardingSize) {
            onboarding(.tryIt, settings: ready, status: Sample.status(phase: .recording))
        }
        try SnapshotRenderer.renderBoth("01-onboarding-4-try-combo-taken", size: onboardingSize) {
            onboarding(.tryIt, settings: ready, status: Sample.status(hotkey: Sample.comboTaken))
        }
        try SnapshotRenderer.renderBoth("01-onboarding-5-autopaste", size: onboardingSize) {
            onboarding(.autoPaste, settings: ready, status: Sample.status())
        }
        try SnapshotRenderer.renderBoth("01-onboarding-5-autopaste-done", size: onboardingSize) {
            onboarding(.autoPaste, settings: ready, status: Sample.status(trusted: true))
        }
        // Smaller than the window ever is: content must scroll, never clip or overlap the footer.
        try SnapshotRenderer.renderBoth("01-onboarding-small-3-key", size: CGSize(width: 520, height: 440)) {
            onboarding(.apiKey, settings: fresh, status: Sample.status())
        }
        try SnapshotRenderer.renderBoth("01-onboarding-small-5-autopaste", size: CGSize(width: 520, height: 440)) {
            onboarding(.autoPaste, settings: ready, status: Sample.status())
        }
    }

    // MARK: 自動貼上 window

    func testAutoPasteWindow() throws {
        let size = AutoPasteWindowView.size
        try SnapshotRenderer.renderBoth("02-autopaste-1-offer", size: size) {
            AutoPasteWindowView(onClose: {}).environment(Sample.settings()).environment(Sample.status())
        }
        try SnapshotRenderer.renderBoth("02-autopaste-2-waiting", size: size) {
            AutoPasteWindowView(onClose: {}, requested: true).environment(Sample.settings()).environment(Sample.status())
        }
        try SnapshotRenderer.renderBoth("02-autopaste-3-done", size: size) {
            AutoPasteWindowView(onClose: {}).environment(Sample.settings()).environment(Sample.status(trusted: true))
        }
        let relaunch = HotkeyRuntimeState(active: .combo(.optionSpace), combo: .registered, tapFailed: true)
        try SnapshotRenderer.renderBoth("02-autopaste-4-relaunch", size: size) {
            AutoPasteWindowView(onClose: {}).environment(Sample.settings()).environment(Sample.status(trusted: true, hotkey: relaunch))
        }
    }

    // MARK: Home

    func testHome() throws {
        let filled = Sample.sources(history: Sample.history(Sample.historyItems), stats: Sample.stats)
        let empty = Sample.sources(history: Sample.history([]), stats: Sample.noStats)
        try SnapshotRenderer.renderBoth("03-home-1-first-run", size: mainSize) {
            mainWindow(.home, settings: Sample.settings(keys: []), status: Sample.status(mic: .notDetermined), data: empty)
        }
        try SnapshotRenderer.renderBoth("03-home-2-empty-ready", size: mainSize) {
            mainWindow(.home, settings: Sample.settings(), status: Sample.status(), data: empty)
        }
        try SnapshotRenderer.renderBoth("03-home-3-filled", size: mainSize) {
            mainWindow(.home, settings: Sample.settings(), status: Sample.status(), data: filled)
        }
        try SnapshotRenderer.renderBoth("03-home-4-filled-autopaste-on", size: mainSize) {
            mainWindow(.home, settings: Sample.settings(), status: Sample.status(trusted: true), data: filled)
        }
        try SnapshotRenderer.renderBoth("03-home-5-small", size: mainSmall) {
            mainWindow(.home, settings: Sample.settings(), status: Sample.status(trusted: true), data: filled)
        }
        try SnapshotRenderer.renderBoth("03-home-6-combo-taken", size: mainSize) {
            mainWindow(.home, settings: Sample.settings(), status: Sample.status(hotkey: Sample.comboTaken), data: filled)
        }
        try SnapshotRenderer.renderBoth("03-home-7-large", size: CGSize(width: 1400, height: 900)) {
            mainWindow(.home, settings: Sample.settings(), status: Sample.status(trusted: true), data: filled)
        }
    }

    // MARK: Dictionary

    func testDictionary() throws {
        let filled = Sample.sources(history: Sample.history([]), dictionary: Sample.dictionary(Sample.dictionaryEntries),
                                    stats: Sample.stats)
        let empty = Sample.sources(history: Sample.history([]), dictionary: Sample.dictionary([]), stats: Sample.stats)
        try SnapshotRenderer.renderBoth("04-dictionary-1-empty", size: mainSize) {
            mainWindow(.dictionary, settings: Sample.settings(), status: Sample.status(trusted: true), data: empty)
        }
        try SnapshotRenderer.renderBoth("04-dictionary-2-filled", size: mainSize) {
            mainWindow(.dictionary, settings: Sample.settings(), status: Sample.status(trusted: true), data: filled)
        }
        try SnapshotRenderer.renderBoth("04-dictionary-3-small", size: mainSmall) {
            mainWindow(.dictionary, settings: Sample.settings(), status: Sample.status(trusted: true), data: filled)
        }
        let store = Sample.dictionary(Sample.dictionaryEntries)
        try SnapshotRenderer.renderBoth("04-dictionary-4-editor-new", size: CGSize(width: 460, height: 330), chrome: false) {
            DictionaryEntryEditor(target: .new, store: store)
        }
        try SnapshotRenderer.renderBoth("04-dictionary-5-editor-edit", size: CGSize(width: 460, height: 330), chrome: false) {
            DictionaryEntryEditor(target: .edit(store.entries[3]), store: store)
        }
    }

    // MARK: History

    func testHistory() throws {
        let filled = Sample.sources(history: Sample.history(Sample.historyItems), stats: Sample.stats)
        let empty = Sample.sources(history: Sample.history([]), stats: Sample.stats)
        try SnapshotRenderer.renderBoth("05-history-1-empty", size: mainSize) {
            mainWindow(.history, settings: Sample.settings(), status: Sample.status(trusted: true), data: empty)
        }
        try SnapshotRenderer.renderBoth("05-history-2-paused-empty", size: mainSize) {
            mainWindow(.history, settings: Sample.settings(saveHistory: false), status: Sample.status(trusted: true), data: empty)
        }
        try SnapshotRenderer.renderBoth("05-history-3-filled", size: mainSize) {
            mainWindow(.history, settings: Sample.settings(), status: Sample.status(trusted: true), data: filled)
        }
        try SnapshotRenderer.renderBoth("05-history-4-small", size: mainSmall) {
            mainWindow(.history, settings: Sample.settings(saveHistory: false), status: Sample.status(trusted: true), data: filled)
        }
    }

    // MARK: Settings

    private func trigger(_ code: UInt16) -> TriggerKey { TriggerKey.from(keyCode: code)! }

    func testSettings() throws {
        let data = Sample.sources(history: Sample.history([]), stats: Sample.stats)
        let tall = CGSize(width: 980, height: 2250)
        try SnapshotRenderer.renderBoth("06-settings-1-no-autopaste", size: mainSize) {
            mainWindow(.settings, settings: Sample.settings(keys: [.elevenLabs]), status: Sample.status(), data: data)
        }
        try SnapshotRenderer.renderBoth("06-settings-2-autopaste-on", size: mainSize) {
            mainWindow(.settings, settings: Sample.settings(realtime: true), status: Sample.status(trusted: true), data: data)
        }
        try SnapshotRenderer.renderBoth("06-settings-3-small", size: mainSmall) {
            mainWindow(.settings, settings: Sample.settings(keys: [.elevenLabs]), status: Sample.status(), data: data)
        }
        // Every section, Accessibility off, nothing configured beyond one key.
        try SnapshotRenderer.renderBoth("06-settings-4-all-off", size: tall) {
            mainWindow(.settings, settings: Sample.settings(keys: [.elevenLabs], polish: .anthropic),
                       status: Sample.status(mic: .notDetermined), data: data)
        }
        // Every section with problems: combination taken, microphone denied, secure input.
        try SnapshotRenderer.renderBoth("06-settings-5-all-problems", size: tall) {
            mainWindow(.settings, settings: Sample.settings(keys: [.elevenLabs], realtime: true),
                       status: Sample.status(mic: .denied, hotkey: Sample.comboTaken, secureInputOwner: "1Password"), data: data)
        }
        // Accessibility on, a custom left-Control trigger, hold mode, conflicting variant.
        var custom = HotkeyConfig()
        custom.trigger = trigger(KeyCodes.leftControl)
        custom.mode = .hold
        custom.combo = KeyCombo(keyCode: 0x02, modifiers: [.control, .option], keyLabel: "D")
        try SnapshotRenderer.renderBoth("06-settings-6-custom-trigger", size: mainSize) {
            mainWindow(.settings, settings: Sample.settings(realtime: true, hotkey: custom),
                       status: Sample.status(trusted: true), data: data)
        }
    }

    /// The 快捷鍵 section alone, in each state (inside a grouped form like the real page).
    private func hotkeyForm(settings: MacSettings, status: EngineStatus, showsOther: Bool = false) -> some View {
        Form {
            Section {
                HotkeySettingsView(showsOther: showsOther)
            } header: {
                Text("快捷鍵")
            }
        }
        .formStyle(.grouped)
        .environment(settings)
        .environment(status)
    }

    func testHotkeySection() throws {
        let size = CGSize(width: 700, height: 430)
        try SnapshotRenderer.renderBoth("09-hotkeys-1-combo-in-effect", size: size, chrome: false) {
            hotkeyForm(settings: Sample.settings(), status: Sample.status())
        }
        try SnapshotRenderer.renderBoth("09-hotkeys-2-single-in-effect-expanded", size: CGSize(width: 700, height: 500), chrome: false) {
            hotkeyForm(settings: Sample.settings(), status: Sample.status(trusted: true), showsOther: true)
        }
        try SnapshotRenderer.renderBoth("09-hotkeys-3-combo-taken", size: size, chrome: false) {
            hotkeyForm(settings: Sample.settings(), status: Sample.status(hotkey: Sample.comboTaken))
        }
        var fn = HotkeyConfig()
        fn.trigger = .fn
        try SnapshotRenderer.renderBoth("09-hotkeys-4-fn-trigger", size: size, chrome: false) {
            hotkeyForm(settings: Sample.settings(hotkey: fn), status: Sample.status(trusted: true))
        }
        var f5 = HotkeyConfig()
        f5.trigger = trigger(KeyCodes.functionKeys[4])
        f5.editModifier = .none
        try SnapshotRenderer.renderBoth("09-hotkeys-5-f5-trigger", size: size, chrome: false) {
            hotkeyForm(settings: Sample.settings(hotkey: f5), status: Sample.status(trusted: true))
        }
        let relaunch = HotkeyRuntimeState(active: .combo(.optionSpace), combo: .registered, tapFailed: true)
        try SnapshotRenderer.renderBoth("09-hotkeys-6-not-active-yet", size: size, chrome: false) {
            hotkeyForm(settings: Sample.settings(), status: Sample.status(trusted: true, hotkey: relaunch))
        }
    }

    /// The recorder's states: listening, a refused key (still listening), saved.
    func testRecorderStates() throws {
        let rows: [(String, HotkeyRecorderRow.Target, HotkeyRecorderRow.Phase)] = [
            ("1-single-listening", .single, .listening),
            ("2-single-typing-key", .single, .rejected(HotkeyRecorderRow.message(for: .typingKey))),
            ("3-single-caps-lock", .single, .rejected(HotkeyRecorderRow.message(for: .capsLock))),
            ("4-single-two-keys", .single, .rejected("只按一個鍵")),
            ("5-combo-listening", .combination, .listening),
            ("6-combo-needs-modifier", .combination, .rejected("要加上 ⌘、⌃ 或 ⌥")),
            ("7-saved", .single, .saved),
        ]
        for (name, target, phase) in rows {
            try SnapshotRenderer.renderBoth("10-recorder-\(name)", size: CGSize(width: 640, height: 110), chrome: false) {
                Form {
                    HotkeyRecorderRow(target: target, title: "快捷鍵", caption: "單鍵・說完直接貼上", initialPhase: phase)
                }
                .formStyle(.grouped)
                .environment(Sample.settings())
                .environment(Sample.status(trusted: true))
            }
        }
    }

    /// Engine rows: idle without a key (quiet 未設定), hovered (設定 key shows), selected without a
    /// key (always shows, it needs action), with a key (quiet 已設定), and the custom engine.
    func testProviderRows() throws {
        let settings = Sample.settings(keys: [.elevenLabs], stt: .groqWhisperTurbo)
        try SnapshotRenderer.renderBoth("11-provider-rows", size: CGSize(width: 640, height: 400), chrome: false) {
            Form {
                Section {
                    ProviderRow(title: "Scribe v3", tag: "ElevenLabs・最準", isSelected: false, keyKind: .elevenLabs) { false }
                    ProviderRow(title: "Whisper Large v3", tag: "Groq・快又便宜（滑鼠停在這列）", isSelected: false, keyKind: .groq) { false }
                        .environment(\.forcedHover, true)
                    ProviderRow(title: "Whisper Large v3 Turbo", tag: "Groq・最快（選了但沒有 key）", isSelected: true, keyKind: .groq) { false }
                    CustomEngineRow()
                    CustomEngineRow()
                        .environment(\.forcedHover, true)
                } header: {
                    Text("語音辨識")
                }
            }
            .formStyle(.grouped)
            .environment(settings)
            .environment(Sample.status())
        }
    }

    // MARK: Popovers and sheets

    func testPopovers() throws {
        try SnapshotRenderer.renderBoth("07-popover-1-key-entry", size: CGSize(width: 340, height: 150), chrome: false) {
            KeyEntryView(kind: .groq, onDone: {}).environment(Sample.settings(keys: []))
        }
        try SnapshotRenderer.renderBoth("07-popover-2-combo-recorder", size: CGSize(width: 340, height: 130), chrome: false) {
            ComboRecorderPopover().environment(Sample.settings()).environment(Sample.status())
        }
        try SnapshotRenderer.renderBoth("07-popover-3-combo-recorder-taken", size: CGSize(width: 340, height: 130), chrome: false) {
            ComboRecorderPopover().environment(Sample.settings()).environment(Sample.status(hotkey: Sample.comboTaken))
        }
        try SnapshotRenderer.renderBoth("07-sheet-4-custom-engine", size: CGSize(width: 440, height: 300), chrome: false) {
            CustomEngineForm(onDone: {}).environment(Sample.settings(keys: []))
        }
        try SnapshotRenderer.renderBoth("07-info-5-why-autopaste", size: CGSize(width: 332, height: 170), chrome: false) {
            VStack(alignment: .leading) { InfoText(AutoPasteSetupView.why) }
                .font(.callout).frame(width: 300, alignment: .leading).padding(16)
        }
    }

    // MARK: Sidebar

    /// The sidebar outside the split view: there its vibrant material cannot be captured (text and
    /// secondary icons come out faded), so this render is the one to judge its layout by.
    func testSidebar() throws {
        for section in MainSection.allCases {
            try SnapshotRenderer.renderBoth("03-sidebar-\(section.rawValue)", size: CGSize(width: 220, height: 560)) {
                let navigation = MainNavigation()
                navigation.section = section
                return MainSidebar(attention: section == .history)
                    .environment(navigation)
                    .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
    }

    // MARK: Art and symbols

    func testHeroArt() throws {
        try SnapshotRenderer.renderBoth("08-art-mic-disc", size: CGSize(width: 320, height: 320), chrome: false) {
            MicDiscArt(size: 280).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Every SF Symbol name the redesign uses must exist on this system (a missing name draws nothing).
    func testSymbolsExist() {
        let names = ["mic.fill", "mic.slash.fill", "key.fill", "command", "arrow.clockwise", "wand.and.sparkles", "text.cursor",
                     "house", "character.book.closed", "clock.arrow.circlepath", "gearshape", "waveform", "character.bubble",
                     "key", "wave.3.right", "text.bubble.fill", "checkmark", "sparkle", "keyboard", "wand.and.stars",
                     "info.circle", "doc.on.clipboard", "doc.on.doc", "ellipsis", "text.bubble", "pause.circle",
                     "magnifyingglass", "xmark.circle.fill", "sparkles", "pencil", "arrow.left", "character.book.closed.fill",
                     "clock.fill", "pause.fill", "pause.circle.fill", "exclamationmark.triangle.fill", "globe", "lock.fill",
                     "checkmark.circle.fill", "chevron.right", "mic", "translate", "exclamationmark.circle.fill"]
        let missing = names.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        XCTAssertEqual(missing, [], "missing SF Symbols")
    }
}
