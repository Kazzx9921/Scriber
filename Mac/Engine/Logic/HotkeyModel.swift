import Foundation

// Pure model of the global hotkey: which key, which mode, which variants. Foundation only (raw
// CGEventFlags bit values) so it compiles into the logic test bundle without the app.

/// Raw `CGEventFlags` / IOKit `NX_DEVICE*KEYMASK` bits. Device-dependent bits tell the left and
/// right copies of a modifier apart; most keyboards set them, some remappers do not.
enum ModifierBits {
    static let capsLock: UInt64 = 0x0001_0000      // maskAlphaShift
    static let shift: UInt64 = 0x0002_0000         // maskShift
    static let control: UInt64 = 0x0004_0000       // maskControl
    static let option: UInt64 = 0x0008_0000        // maskAlternate
    static let command: UInt64 = 0x0010_0000       // maskCommand
    static let numericPad: UInt64 = 0x0020_0000
    static let help: UInt64 = 0x0040_0000
    static let secondaryFn: UInt64 = 0x0080_0000   // maskSecondaryFn

    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let rightControl: UInt64 = 0x0000_2000
}

/// The four modifier families that can be held as a variant (Fn and Caps Lock never count).
enum ModifierFamily: String, CaseIterable, Codable, Sendable {
    case shift, control, option, command

    var flag: UInt64 {
        switch self {
        case .shift: ModifierBits.shift
        case .control: ModifierBits.control
        case .option: ModifierBits.option
        case .command: ModifierBits.command
        }
    }

    /// Both device-dependent bits of the family.
    var deviceBits: UInt64 {
        switch self {
        case .shift: ModifierBits.leftShift | ModifierBits.rightShift
        case .control: ModifierBits.leftControl | ModifierBits.rightControl
        case .option: ModifierBits.leftOption | ModifierBits.rightOption
        case .command: ModifierBits.leftCommand | ModifierBits.rightCommand
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        }
    }

    var displayName: String {
        switch self {
        case .shift: "Shift ⇧"
        case .control: "Control ⌃"
        case .option: "Option ⌥"
        case .command: "Command ⌘"
        }
    }

    /// Families currently held according to `flags`.
    static func held(in flags: UInt64) -> Set<ModifierFamily> {
        Set(allCases.filter { flags & $0.flag != 0 })
    }

    /// The family a modifier key code belongs to (nil for Fn, Caps Lock and ordinary keys).
    static func of(keyCode: UInt16) -> ModifierFamily? {
        switch keyCode {
        case KeyCodes.leftShift, KeyCodes.rightShift: .shift
        case KeyCodes.leftControl, KeyCodes.rightControl: .control
        case KeyCodes.leftOption, KeyCodes.rightOption: .option
        case KeyCodes.leftCommand, KeyCodes.rightCommand: .command
        default: nil
        }
    }
}

/// Carbon `kVK_*` virtual key codes used here.
enum KeyCodes {
    static let escape: UInt16 = 0x35
    static let leftCommand: UInt16 = 0x37
    static let rightCommand: UInt16 = 0x36
    static let leftShift: UInt16 = 0x38
    static let rightShift: UInt16 = 0x3C
    static let leftOption: UInt16 = 0x3A
    static let rightOption: UInt16 = 0x3D
    static let leftControl: UInt16 = 0x3B
    static let rightControl: UInt16 = 0x3E
    static let capsLock: UInt16 = 0x39
    static let function: UInt16 = 0x3F
    /// Some Apple keyboards report the 🌐 key with this code instead of `function`.
    static let globe: UInt16 = 0xB3
    static let ansiV: UInt16 = 0x09
    static let ansiC: UInt16 = 0x08
    static let space: UInt16 = 0x31
    static let returnKey: UInt16 = 0x24
    static let keypadEnter: UInt16 = 0x4C
    static let tab: UInt16 = 0x30
    static let delete: UInt16 = 0x33
    static let forwardDelete: UInt16 = 0x75
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let downArrow: UInt16 = 0x7D
    static let upArrow: UInt16 = 0x7E
    static let home: UInt16 = 0x73
    static let end: UInt16 = 0x77
    static let pageUp: UInt16 = 0x74
    static let pageDown: UInt16 = 0x79
    /// F1…F20 in order.
    static let functionKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
                                         0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]

    static let modifierKeys: Set<UInt16> = [leftCommand, rightCommand, leftShift, rightShift, leftOption, rightOption,
                                            leftControl, rightControl, capsLock, function, globe]
}

/// A key that starts dictation when pressed and released on its own: any modifier key on either
/// side (⌘ ⌥ ⌃ ⇧), Fn/🌐, or a function key F1–F20. Identified by the physical key, so left and
/// right copies of a modifier are different triggers.
///
/// Never allowed: ordinary typing keys (they would fire while typing), Esc (it cancels), and
/// Caps Lock (macOS toggles the lock in hardware before any app sees the press).
///
/// Persisted as a short string. The first version's four values ("rightOption", "rightCommand",
/// "rightControl", "fn") keep their spelling, so saved settings still load.
struct TriggerKey: Hashable, Sendable, Identifiable {
    enum Side: String, Hashable, Sendable {
        case left, right
    }

    enum Kind: Hashable, Sendable {
        case modifier(ModifierFamily, Side)
        case fn
        /// F1…F20.
        case function(Int)
    }

    let kind: Kind

    init?(kind: Kind) {
        if case .function(let number) = kind, !(1...KeyCodes.functionKeys.count).contains(number) { return nil }
        self.kind = kind
    }

    private init(validated kind: Kind) {
        self.kind = kind
    }

    static let rightOption = TriggerKey(validated: .modifier(.option, .right))
    static let rightCommand = TriggerKey(validated: .modifier(.command, .right))
    static let rightControl = TriggerKey(validated: .modifier(.control, .right))
    static let fn = TriggerKey(validated: .fn)

    static let `default`: TriggerKey = .rightOption

    var id: String { rawValue }

    /// The key itself, or nil for a key that cannot be a trigger.
    static func from(keyCode: UInt16) -> TriggerKey? {
        switch keyCode {
        case KeyCodes.function, KeyCodes.globe: return .fn
        case KeyCodes.leftShift: return TriggerKey(validated: .modifier(.shift, .left))
        case KeyCodes.rightShift: return TriggerKey(validated: .modifier(.shift, .right))
        case KeyCodes.leftControl: return TriggerKey(validated: .modifier(.control, .left))
        case KeyCodes.rightControl: return TriggerKey(validated: .modifier(.control, .right))
        case KeyCodes.leftOption: return TriggerKey(validated: .modifier(.option, .left))
        case KeyCodes.rightOption: return TriggerKey(validated: .modifier(.option, .right))
        case KeyCodes.leftCommand: return TriggerKey(validated: .modifier(.command, .left))
        case KeyCodes.rightCommand: return TriggerKey(validated: .modifier(.command, .right))
        default:
            guard let index = KeyCodes.functionKeys.firstIndex(of: keyCode) else { return nil }
            return TriggerKey(validated: .function(index + 1))
        }
    }

    enum Rejection: Equatable, Sendable {
        /// Caps Lock: its lock toggles before any app sees the press.
        case capsLock
        /// Esc cancels a recording.
        case escape
        /// A letter, digit, Space, arrow…: it would fire while typing.
        case typingKey
    }

    /// Why a key cannot be the single-key trigger (nil when it can).
    static func rejection(forKeyCode keyCode: UInt16) -> Rejection? {
        if from(keyCode: keyCode) != nil { return nil }
        switch keyCode {
        case KeyCodes.capsLock: return .capsLock
        case KeyCodes.escape: return .escape
        default: return .typingKey
        }
    }

    /// The key codes that are this key (Fn: also the 🌐 key code some keyboards send).
    var keyCodes: Set<UInt16> {
        switch kind {
        case .fn: return [KeyCodes.function, KeyCodes.globe]
        case .function(let number): return [KeyCodes.functionKeys[number - 1]]
        case let .modifier(family, side): return [Self.keyCode(family, side)]
        }
    }

    /// The modifier family the key belongs to (nil for Fn and function keys).
    var family: ModifierFamily? {
        if case .modifier(let family, _) = kind { return family }
        return nil
    }

    /// A function key: arrives as key down / key up, not as a modifier change.
    var isFunctionKey: Bool {
        if case .function = kind { return true }
        return false
    }

    /// Device-dependent bit of this exact key (Fn: the secondary-fn flag; function keys: none).
    var deviceBit: UInt64 {
        switch kind {
        case .fn: return ModifierBits.secondaryFn
        case .function: return 0
        case let .modifier(family, side):
            switch (family, side) {
            case (.shift, .left): return ModifierBits.leftShift
            case (.shift, .right): return ModifierBits.rightShift
            case (.control, .left): return ModifierBits.leftControl
            case (.control, .right): return ModifierBits.rightControl
            case (.option, .left): return ModifierBits.leftOption
            case (.option, .right): return ModifierBits.rightOption
            case (.command, .left): return ModifierBits.leftCommand
            case (.command, .right): return ModifierBits.rightCommand
            }
        }
    }

    /// "右邊的 Option ⌥", "左邊的 Shift ⇧", "Fn／🌐", "F5".
    var displayName: String {
        switch kind {
        case .fn: return "Fn／🌐"
        case .function(let number): return "F\(number)"
        case let .modifier(family, side): return "\(side == .left ? "左" : "右")邊的 \(family.displayName)"
        }
    }

    /// Fits a keycap or a menu line: "右 ⌥", "左 ⇧", "Fn", "F5".
    var shortName: String {
        switch kind {
        case .fn: return "Fn"
        case .function(let number): return "F\(number)"
        case let .modifier(family, side): return "\(side == .left ? "左" : "右") \(family.symbol)"
        }
    }

    /// Stable name for settings and the diagnostic log: "rightOption", "leftShift", "fn", "f5".
    var rawValue: String {
        switch kind {
        case .fn: return "fn"
        case .function(let number): return "f\(number)"
        case let .modifier(family, side): return side.rawValue + family.rawValue.prefix(1).uppercased() + family.rawValue.dropFirst()
        }
    }

    init?(rawValue: String) {
        if rawValue == "fn" {
            self = .fn
            return
        }
        if rawValue.hasPrefix("f"), let number = Int(rawValue.dropFirst()) {
            guard let key = TriggerKey(kind: .function(number)) else { return nil }
            self = key
            return
        }
        for side in [Side.left, .right] where rawValue.hasPrefix(side.rawValue) {
            let rest = rawValue.dropFirst(side.rawValue.count).lowercased()
            guard let family = ModifierFamily(rawValue: rest) else { return nil }
            self.init(validated: .modifier(family, side))
            return
        }
        return nil
    }

    private static func keyCode(_ family: ModifierFamily, _ side: Side) -> UInt16 {
        switch (family, side) {
        case (.shift, .left): KeyCodes.leftShift
        case (.shift, .right): KeyCodes.rightShift
        case (.control, .left): KeyCodes.leftControl
        case (.control, .right): KeyCodes.rightControl
        case (.option, .left): KeyCodes.leftOption
        case (.option, .right): KeyCodes.rightOption
        case (.command, .left): KeyCodes.leftCommand
        case (.command, .right): KeyCodes.rightCommand
        }
    }
}

extension TriggerKey: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let key = TriggerKey(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown trigger key \(raw)")
        }
        self = key
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum TriggerMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Tap to start, tap again to finish (default, same as iOS).
    case toggle
    /// Hold to talk, release to finish.
    case hold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggle: "點一下開始，再點一下結束"
        case .hold: "按住說話，放開結束"
        }
    }

    /// Segmented control label.
    var shortName: String {
        switch self {
        case .toggle: "點一下"
        case .hold: "按住說話"
        }
    }
}

/// What a trigger press asks for, decided by the other modifiers held with it (or by a mode's own
/// key combination). `.edit` and `.translate` are the 改寫 and 翻譯 modes — the pre-modes
/// 說話改字 and 翻譯 variants; `.mode` is any other mode, by id (docs/PRD-模式.md §7.3).
enum HotkeyVariant: Hashable, Sendable {
    /// The current mode (the default mode, or 翻譯 while the menu's lock is on).
    case dictate
    case edit
    case translate
    case mode(String)

    /// For the diagnostic log: mode ids only (shipped ids or UUIDs), never names.
    var logName: String {
        switch self {
        case .dictate: "dictate"
        case .edit: "edit"
        case .translate: "translate"
        case .mode(let id): "mode:\(id)"
        }
    }
}

/// A modifier that, held together with the trigger, selects a variant.
enum VariantModifier: String, CaseIterable, Codable, Identifiable, Sendable {
    case none, shift, control, option, command

    var id: String { rawValue }

    var family: ModifierFamily? {
        switch self {
        case .none: nil
        case .shift: .shift
        case .control: .control
        case .option: .option
        case .command: .command
        }
    }

    var displayName: String {
        family?.displayName ?? "不使用"
    }
}

/// A key combination for the hotkey that needs no permission (Carbon `RegisterEventHotKey`),
/// e.g. ⌥Space. Works before Accessibility is granted; see `HotkeySelection`.
struct KeyCombo: Hashable, Codable, Sendable {
    var keyCode: UInt16
    var modifiers: Set<ModifierFamily>
    /// The key as printed when it was chosen (keyboard-layout dependent): "Space", "D", "F5".
    var keyLabel: String

    static let optionSpace = KeyCombo(keyCode: KeyCodes.space, modifiers: [.option], keyLabel: "Space")

    /// Apple's order for modifier symbols: ⌃ ⌥ ⇧ ⌘.
    static let displayOrder: [ModifierFamily] = [.control, .option, .shift, .command]

    var modifierSymbols: [String] {
        Self.displayOrder.filter { modifiers.contains($0) }.map(\.symbol)
    }

    /// One keycap per modifier, then the key: ["⌥", "Space"].
    var keycaps: [String] { modifierSymbols + [keyLabel] }

    /// "⌥ Space", "⌃⌥ D".
    var displayName: String { modifierSymbols.joined() + " " + keyLabel }

    /// Carbon modifier mask (`cmdKey` 0x100, `shiftKey` 0x200, `optionKey` 0x800, `controlKey` 0x1000),
    /// the format `RegisterEventHotKey` and the system shortcut table use.
    var carbonModifiers: UInt32 {
        modifiers.reduce(UInt32(0)) { mask, family in
            switch family {
            case .command: mask | 0x0100
            case .shift: mask | 0x0200
            case .option: mask | 0x0800
            case .control: mask | 0x1000
            }
        }
    }

    static let carbonModifierMask: UInt32 = 0x0100 | 0x0200 | 0x0800 | 0x1000

    /// The same key with one more modifier held (translate / 說話改字 variants).
    func adding(_ family: ModifierFamily) -> KeyCombo {
        var copy = self
        copy.modifiers.insert(family)
        return copy
    }

    enum Problem: Equatable, Sendable {
        /// Needs ⌘, ⌃ or ⌥ (Shift alone types a character).
        case needsModifier
        /// Esc cancels a recording; it cannot also start one.
        case reserved
    }

    /// Whether a pressed combination can be used as the hotkey.
    static func problem(keyCode: UInt16, modifiers: Set<ModifierFamily>) -> Problem? {
        if keyCode == KeyCodes.escape || KeyCodes.modifierKeys.contains(keyCode) { return .reserved }
        if KeyCodes.functionKeys.contains(keyCode) { return nil }
        return modifiers.isDisjoint(with: [.command, .control, .option]) ? .needsModifier : nil
    }

    /// Labels for keys whose cap is not a character (nil: use the typed character).
    static func specialKeyLabel(for keyCode: UInt16) -> String? {
        if let index = KeyCodes.functionKeys.firstIndex(of: keyCode) { return "F\(index + 1)" }
        switch keyCode {
        case KeyCodes.space: return "Space"
        case KeyCodes.returnKey, KeyCodes.keypadEnter: return "↩"
        case KeyCodes.tab: return "⇥"
        case KeyCodes.delete: return "⌫"
        case KeyCodes.forwardDelete: return "⌦"
        case KeyCodes.leftArrow: return "←"
        case KeyCodes.rightArrow: return "→"
        case KeyCodes.downArrow: return "↓"
        case KeyCodes.upArrow: return "↑"
        case KeyCodes.home: return "↖"
        case KeyCodes.end: return "↘"
        case KeyCodes.pageUp: return "⇞"
        case KeyCodes.pageDown: return "⇟"
        default: return nil
        }
    }

    /// Content-free description for the diagnostic log.
    var logDescription: String {
        let mods = Self.displayOrder.filter { modifiers.contains($0) }.map(\.rawValue).joined(separator: "+")
        return "\(mods.isEmpty ? "none" : mods)+key\(keyCode)"
    }
}

struct HotkeyConfig: Equatable, Codable, Sendable {
    /// Lone-modifier trigger (event tap, needs Accessibility).
    var trigger: TriggerKey = .default
    /// Key combination (no permission needed); the one that works until Accessibility is granted.
    var combo: KeyCombo = .optionSpace
    var mode: TriggerMode = .toggle
    /// Held with the trigger: rewrite the selected text (說話改字).
    var editModifier: VariantModifier = .shift
    /// Held with the trigger: translate.
    var translateModifier: VariantModifier = .control

    static let `default` = HotkeyConfig()

    /// The variant for the set of other modifier families held with the trigger, or nil when the
    /// combination means nothing (then the press is ignored).
    func variant(for extras: Set<ModifierFamily>) -> HotkeyVariant? {
        if extras.isEmpty { return .dictate }
        if let family = editFamily, extras == [family] { return .edit }
        if let family = translateFamily, extras == [family] { return .translate }
        return nil
    }

    /// The edit modifier's family, unless it is the trigger's own family (indistinguishable).
    var editFamily: ModifierFamily? { usable(editModifier) }

    /// Same for translate; when both variants use the same modifier, edit wins.
    var translateFamily: ModifierFamily? {
        translateModifier == editModifier ? nil : usable(translateModifier)
    }

    private func usable(_ modifier: VariantModifier) -> ModifierFamily? {
        guard let family = modifier.family, family != trigger.family else { return nil }
        return family
    }

    /// For the settings screen: nil when fine, else a short problem.
    func problem(for modifier: VariantModifier) -> String? {
        guard let family = modifier.family else { return nil }
        if family == trigger.family { return "跟快捷鍵是同一種鍵，不能用" }
        if translateModifier == editModifier, modifier == editModifier { return "說話改字和翻譯不能用同一個鍵" }
        return nil
    }

    // MARK: Persistence (UserDefaults, one JSON blob)

    static let defaultsKey = "mac.hotkey"

    static func load(from defaults: UserDefaults) -> HotkeyConfig {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data) else { return .default }
        return config
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Short, content-free description for the diagnostic log.
    var logDescription: String {
        "trigger=\(trigger.rawValue) combo=\(combo.logDescription) mode=\(mode.rawValue) "
            + "edit=\(editModifier.rawValue) translate=\(translateModifier.rawValue)"
    }
}

extension HotkeyConfig {
    // Older or hand-edited blobs may miss fields: fill them with defaults instead of failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HotkeyConfig.default
        trigger = (try? c.decode(TriggerKey.self, forKey: .trigger)) ?? d.trigger
        combo = (try? c.decode(KeyCombo.self, forKey: .combo)) ?? d.combo
        mode = (try? c.decode(TriggerMode.self, forKey: .mode)) ?? d.mode
        editModifier = (try? c.decode(VariantModifier.self, forKey: .editModifier)) ?? d.editModifier
        translateModifier = (try? c.decode(VariantModifier.self, forKey: .translateModifier)) ?? d.translateModifier
    }
}
