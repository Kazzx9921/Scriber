import Foundation
import ScriberCore
import ScriberShared

// Mode hotkeys (docs/PRD-模式.md §7.3, M2). A mode starts a recording in that mode with either
// - **modifier + main hotkey**: hold ⇧ (or ⌃, ⌥, ⌘) and press the main hotkey — the pre-modes
//   說話改字 (⇧) and 翻譯 (⌃). Works through both listeners: the event tap reads the modifier held
//   with the single key; the key combination path registers the main combination with it added.
// - **a key combination of its own** (⌃⌥M, F6…), always registered through Carbon: it needs no
//   permission and keeps working while secure input is on.
// Tap / hold behaves as the main hotkey's 操作方式.
//
// `HotkeyRoutes.build` turns the modes into what the listeners use, with the same rules the
// pre-modes variants had (one modifier family can mean one thing; 改寫 wins over 翻譯; 改寫 is only
// offered on the key combination path with Accessibility, which reading the selection needs), and
// reports why a mode's hotkey does nothing in a few words. Pure and tested in the logic bundle.

/// A mode's own hotkey in the Mac's hotkey types.
enum ModeShortcut: Hashable, Sendable {
    /// Hold these with the main hotkey.
    case withTrigger(Set<ModifierFamily>)
    /// A key combination of its own.
    case combination(KeyCombo)

    /// nil for hotkeys this version cannot use (unknown modifier names, no key code).
    init?(_ hotkey: ModeHotkey) {
        let families = hotkey.modifiers.compactMap(ModifierFamily.init(rawValue:))
        guard families.count == hotkey.modifiers.count else { return nil }
        switch hotkey.kind {
        case .withMainTrigger:
            guard !families.isEmpty else { return nil }
            self = .withTrigger(Set(families))
        case .combination:
            guard let code = hotkey.keyCode, let keyCode = UInt16(exactly: code) else { return nil }
            let label = hotkey.keyLabel.flatMap { $0.isEmpty ? nil : $0 } ?? KeyCombo.specialKeyLabel(for: keyCode) ?? "?"
            self = .combination(KeyCombo(keyCode: keyCode, modifiers: Set(families), keyLabel: label))
        }
    }

    var modeHotkey: ModeHotkey {
        switch self {
        case .withTrigger(let families):
            return ModeHotkey(kind: .withMainTrigger, modifiers: Self.names(families))
        case .combination(let combo):
            return ModeHotkey(kind: .combination, modifiers: Self.names(combo.modifiers), keyCode: Int(combo.keyCode),
                              keyLabel: combo.keyLabel)
        }
    }

    /// The same keys (the printed label of a combination does not matter).
    func sameKeys(as other: ModeShortcut) -> Bool {
        switch (self, other) {
        case let (.withTrigger(a), .withTrigger(b)): return a == b
        case let (.combination(a), .combination(b)): return a.sameKeys(as: b)
        default: return false
        }
    }

    /// Keycaps to draw: the modifiers, then the main hotkey's keycaps or the combination's key.
    func keycaps(mainHotkey: [String]) -> [String] {
        switch self {
        case .withTrigger(let families):
            return KeyCombo.displayOrder.filter(families.contains).map(\.symbol) + mainHotkey
        case .combination(let combo):
            return combo.keycaps
        }
    }

    private static func names(_ families: Set<ModifierFamily>) -> [String] {
        KeyCombo.displayOrder.filter(families.contains).map(\.rawValue)
    }
}

extension KeyCombo {
    /// Same key code and modifiers.
    func sameKeys(as other: KeyCombo) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

extension HotkeyVariant {
    /// What a mode's hotkey sends: 改寫 and 翻譯 keep the pre-modes variants.
    static func forMode(_ id: String) -> HotkeyVariant {
        switch BuiltInModeID(rawValue: id) {
        case .rewrite?: return .edit
        case .translate?: return .translate
        default: return .mode(id)
        }
    }

    /// The mode the variant starts; nil for `.dictate` (the current mode).
    var modeID: String? {
        switch self {
        case .dictate: return nil
        case .edit: return BuiltInModeID.rewrite.rawValue
        case .translate: return BuiltInModeID.translate.rawValue
        case .mode(let id): return id
        }
    }
}

/// One enabled mode that has a hotkey.
struct ModeHotkeyCandidate: Equatable, Sendable {
    var modeID: String
    /// For messages only (never logged).
    var name: String
    var shortcut: ModeShortcut
    /// The mode rewrites the selected text, which needs Accessibility to read.
    var needsSelection: Bool

    var variant: HotkeyVariant { .forMode(modeID) }

    /// Enabled modes with a usable hotkey, in priority order: 改寫, 翻譯 (the pre-modes rule
    /// "說話改字 wins over 翻譯"), then the user's order.
    static func list(modes: [DictationModeConfig], prompts: [PromptTemplate]) -> [ModeHotkeyCandidate] {
        let priority = [BuiltInModeID.rewrite.rawValue, BuiltInModeID.translate.rawValue]
        let enabled = modes.filter(\.isEnabled)
        let ordered = priority.compactMap { id in enabled.first { $0.id == id } }
            + enabled.filter { !priority.contains($0.id) }
        return ordered.compactMap { mode in
            guard let hotkey = mode.trigger.hotkey, let shortcut = ModeShortcut(hotkey) else { return nil }
            let kind = ModeResolver.prompt(for: mode, in: prompts).kind
            return ModeHotkeyCandidate(modeID: mode.id, name: mode.name, shortcut: shortcut, needsSelection: kind == .rewrite)
        }
    }
}

/// Why a mode's hotkey does nothing right now. A few words each (shown under the row).
enum ModeHotkeyProblem: Equatable, Sendable {
    /// The modifier is the main single key's own kind of key (⇧ with right ⇧): indistinguishable.
    case sameKindAsTrigger
    /// The main key combination already holds this modifier (⌃ with ⌃⌥Space).
    case alreadyInCombo(String)
    /// Reads the selected text: needs automatic paste (Accessibility).
    case needsAccessibility
    /// Another mode uses the same keys (it comes first and keeps them).
    case sameAsMode(String)
    /// The main hotkey or its key combination.
    case sameAsMainHotkey
    /// A macOS shortcut (Spotlight, input sources, screenshots…).
    case system
    /// Typing or app shortcuts use it (⌘C, ⌃A, ⌥E…).
    case common
    /// Esc, or a key that cannot be a hotkey.
    case invalid
    /// macOS refused to register it.
    case taken(ComboConflict)

    /// For the diagnostic log (no names).
    var logName: String {
        switch self {
        case .sameKindAsTrigger: return "sameKindAsTrigger"
        case .alreadyInCombo: return "alreadyInCombo"
        case .needsAccessibility: return "needsAccessibility"
        case .sameAsMode: return "sameAsMode"
        case .sameAsMainHotkey: return "sameAsMainHotkey"
        case .system: return "system"
        case .common: return "common"
        case .invalid: return "invalid"
        case .taken(let conflict): return "taken-\(conflict.rawValue)"
        }
    }

    var message: String {
        switch self {
        case .sameKindAsTrigger: return "跟快捷鍵是同一種鍵，不能用"
        case .alreadyInCombo(let symbols): return "組合鍵已經有 \(symbols)，不能用"
        case .needsAccessibility: return "需要自動貼上"
        case .sameAsMode(let name): return "跟「\(name)」重複"
        case .sameAsMainHotkey: return "跟主要快捷鍵重複"
        case .system: return "跟 macOS 的快捷鍵重複"
        case .common: return "打字或 App 常用到，請用兩個修飾鍵，例如 ⌃⌥"
        case .invalid: return "這組按鍵不能用"
        case .taken(let conflict): return conflict.label
        }
    }
}

/// A mode's own combination to register.
struct ModeComboBinding: Hashable, Sendable {
    var modeID: String
    var combo: KeyCombo
    var variant: HotkeyVariant
}

/// What the listeners do with the modes' hotkeys.
struct HotkeyRoutes: Equatable, Sendable {
    /// Families added to the main combination, in registration order.
    struct ComboVariant: Equatable, Sendable {
        var families: Set<ModifierFamily>
        var variant: HotkeyVariant
    }

    /// Event tap: modifier families held with the single key → variant (a plain press is `.dictate`).
    var withTrigger: [Set<ModifierFamily>: HotkeyVariant] = [:]
    /// Key combination path: the main combination with these families added.
    var withCombo: [ComboVariant] = []
    /// Modes' own combinations (Carbon, whatever the permission).
    var combinations: [ModeComboBinding] = []
    /// Why a mode's hotkey does nothing, by mode id (for the listener in effect).
    var problems: [String: ModeHotkeyProblem] = [:]

    /// The variant for the families held with the single key; nil = the press means nothing.
    func variant(for extras: Set<ModifierFamily>) -> HotkeyVariant? {
        extras.isEmpty ? .dictate : withTrigger[extras]
    }

    /// The combinations of the key combination path: plain dictation first, then the modes that
    /// add a modifier to it (the same list the pre-modes `HotkeySelection.comboBindings` made).
    func comboBindings(base: KeyCombo) -> [ComboBinding] {
        [ComboBinding(combo: base, variant: .dictate)]
            + withCombo.map { variant in
                ComboBinding(combo: variant.families.reduce(base) { $0.adding($1) }, variant: variant.variant)
            }
    }

    /// `accessibilityTrusted` decides which listener's problems are reported and whether modes that
    /// read the selection join the key combination path.
    static func build(config: HotkeyConfig, candidates: [ModeHotkeyCandidate], accessibilityTrusted: Bool) -> HotkeyRoutes {
        var routes = HotkeyRoutes()
        let base = config.combo
        let triggerFamily = config.trigger.family
        var claimed: [(shortcut: ModeShortcut, name: String)] = []
        /// The main combination plus a mode's modifiers, whatever the permission (for clashes with
        /// modes' own combinations: Carbon cannot register one combination twice).
        var variantCombos: [(combo: KeyCombo, name: String)] = []
        var ownCombos: [(candidate: ModeHotkeyCandidate, combo: KeyCombo)] = []

        for candidate in candidates {
            if let owner = claimed.first(where: { $0.shortcut.sameKeys(as: candidate.shortcut) }) {
                routes.problems[candidate.modeID] = .sameAsMode(owner.name)
                continue
            }
            claimed.append((candidate.shortcut, candidate.name))
            switch candidate.shortcut {
            case .withTrigger(let families):
                var tapProblem: ModeHotkeyProblem?
                if let triggerFamily, families.contains(triggerFamily) {
                    tapProblem = .sameKindAsTrigger
                } else {
                    routes.withTrigger[families] = candidate.variant
                }
                var comboProblem: ModeHotkeyProblem?
                let overlap = families.intersection(base.modifiers)
                if !overlap.isEmpty {
                    comboProblem = .alreadyInCombo(KeyCombo.displayOrder.filter(overlap.contains).map(\.symbol).joined())
                } else {
                    variantCombos.append((families.reduce(base) { $0.adding($1) }, candidate.name))
                    if candidate.needsSelection, !accessibilityTrusted {
                        comboProblem = .needsAccessibility
                    } else {
                        routes.withCombo.append(ComboVariant(families: families, variant: candidate.variant))
                    }
                }
                if let problem = accessibilityTrusted ? tapProblem : comboProblem {
                    routes.problems[candidate.modeID] = problem
                }
            case .combination(let combo):
                ownCombos.append((candidate, combo))
            }
        }
        // Modes' own combinations, once every "main combination + a mode's modifier" is known.
        // The most specific reason first: the main hotkey, another mode, then the general rules.
        for (candidate, combo) in ownCombos {
            if combo.sameKeys(as: base) || Self.isTriggerKey(combo, config.trigger) {
                routes.problems[candidate.modeID] = .sameAsMainHotkey
            } else if let owner = variantCombos.first(where: { $0.combo.sameKeys(as: combo) }) {
                routes.problems[candidate.modeID] = .sameAsMode(owner.name)
            } else if let problem = ModeComboRules.problem(for: combo) {
                routes.problems[candidate.modeID] = problem
            } else {
                routes.combinations.append(ModeComboBinding(modeID: candidate.modeID, combo: combo, variant: candidate.variant))
            }
        }
        return routes
    }

    /// An F-key alone that is also the single-key hotkey.
    private static func isTriggerKey(_ combo: KeyCombo, _ trigger: TriggerKey) -> Bool {
        combo.modifiers.isEmpty && trigger.isFunctionKey && trigger.keyCodes.contains(combo.keyCode)
    }

    /// The 改寫 / 翻譯 hotkeys as the pre-modes settings fields (`HotkeyConfig.editModifier` /
    /// `translateModifier`), kept current so the saved hotkey settings still describe them (and an
    /// older build that reads only those does the same thing). A disabled mode, no hotkey, or a
    /// hotkey of another kind is `.none`.
    static func legacyModifiers(in modes: [DictationModeConfig]) -> (edit: VariantModifier, translate: VariantModifier) {
        func modifier(_ id: BuiltInModeID) -> VariantModifier {
            guard let mode = modes.first(where: { $0.id == id.rawValue }), mode.isEnabled,
                  let hotkey = mode.trigger.hotkey, let shortcut = ModeShortcut(hotkey),
                  case .withTrigger(let families) = shortcut, families.count == 1, let family = families.first else { return .none }
            return VariantModifier(rawValue: family.rawValue) ?? .none
        }
        return (modifier(.rewrite), modifier(.translate))
    }
}

/// Which combinations a mode may use. Stricter than the main hotkey's: a mode's combination is
/// registered for the whole system, so it must not take keys people type or use in apps.
enum ModeComboRules {
    /// nil when the combination can be used.
    static func problem(for combo: KeyCombo) -> ModeHotkeyProblem? {
        if KeyCombo.problem(keyCode: combo.keyCode, modifiers: combo.modifiers) != nil { return .invalid }
        if isSystem(combo) { return .system }
        let isFunctionKey = KeyCodes.functionKeys.contains(combo.keyCode)
        if isFunctionKey { return nil }
        // One of ⌘ ⌃ ⌥ (with or without ⇧) plus an ordinary key: ⌘C, ⇧⌘Z, ⌃A, ⌥E (types é)…
        let strong = combo.modifiers.intersection([.command, .control, .option])
        if strong.count < 2, !(combo.modifiers == [.control, .shift]) { return .common }
        return nil
    }

    /// Well-known macOS shortcuts with two or more modifiers, or on function keys. Not exhaustive:
    /// the live system table and the exclusive registration catch the rest.
    static func isSystem(_ combo: KeyCombo) -> Bool {
        let space = KeyCodes.space
        let known: [(UInt16, Set<ModifierFamily>)] = [
            (space, [.control]),                       // 選取上一個輸入方式
            (space, [.control, .option]),              // 選取下一個輸入方式
            (space, [.control, .command]),             // 表情符號與符號
            (space, [.option, .command]),              // Finder 搜尋視窗
            (KeyCodes.escape, [.option, .command]),    // 強制結束
            (0x0C, [.control, .command]),              // ⌃⌘Q 鎖定螢幕
            (0x03, [.control, .command]),              // ⌃⌘F 全螢幕
            (0x02, [.option, .command]),               // ⌥⌘D 隱藏 Dock
            (0x04, [.option, .command]),               // ⌥⌘H 隱藏其他
            (0x14, [.control, .shift, .command]),      // ⌃⇧⌘3 截圖到剪貼簿
            (0x15, [.control, .shift, .command]),      // ⌃⇧⌘4
            (KeyCodes.functionKeys[4], [.command]),    // ⌘F5 VoiceOver
            (KeyCodes.leftArrow, [.control]), (KeyCodes.rightArrow, [.control]),
            (KeyCodes.upArrow, [.control]), (KeyCodes.downArrow, [.control]), // 指揮中心、切換空間
        ]
        return known.contains { $0.0 == combo.keyCode && $0.1 == combo.modifiers }
    }
}
