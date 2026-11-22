import Foundation
import ScriberShared

/// What the migration needs from settings that are not in `AppSettings`.
public struct LegacyModeSettings: Sendable, Equatable {
    /// macOS: the modifier held with the trigger for 說話改字 and for 翻譯, as `VariantModifier` raw
    /// values ("none", "shift", "control", "option", "command"). nil on iOS (no hotkeys).
    public var macEditModifier: String?
    public var macTranslateModifier: String?

    public init(macEditModifier: String? = nil, macTranslateModifier: String? = nil) {
        self.macEditModifier = macEditModifier; self.macTranslateModifier = macTranslateModifier
    }
}

/// Upgrades settings from before modes (docs/PRD-模式.md §3 遷移). Runs once per version, idempotent.
///
/// The rule: the global settings become the defaults, and the shipped modes follow them, so nothing
/// is copied and behaviour after the upgrade is identical:
/// - engine, language, real-time text, Traditional / spacing / punctuation → every shipped mode
///   follows the global setting;
/// - 「AI 潤飾」 on/off and its provider → 聽寫 follows the global switch (on: polished with that
///   provider, rule-based cleanup if it fails or has no key; off: rule-based cleanup). The default
///   mode stays 聽寫. 潤飾 is a separate mode that always polishes;
/// - translate language and the three quick languages → 翻譯 follows the global translate language,
///   which the keyboard key and the menu keep switching;
/// - 翻譯 and 改寫 keep using any LLM key (Groq, then Anthropic) whether 「AI 潤飾」 is on or not;
/// - macOS 說話改字 / 翻譯 modifier keys → recorded as the hotkeys of 改寫 / 翻譯 (stored only;
///   the hotkey settings still drive the keys until the mode editor exists).
public enum ModeMigration {
    public static let currentVersion = 1
    static let versionKey = "modes.migrationVersion"

    /// Runs the migration if this version has not run yet. Returns whether it ran.
    @discardableResult
    public static func runIfNeeded(store: ModeStore = .shared, legacy: LegacyModeSettings = LegacyModeSettings(),
                                   defaults: UserDefaults = AppGroup.defaults,
                                   log: (String) -> Void = { DiagLog.log("modes", $0) }) -> Bool {
        let done = defaults.integer(forKey: versionKey)
        guard done < currentVersion else { return false }
        if let edit = legacy.macEditModifier, let translate = legacy.macTranslateModifier {
            store.setLegacyVariantHotkeys(editModifier: edit, translateModifier: translate)
        }
        // Write the shipped modes so the app and the keyboard read the same file from now on.
        store.persistIfMissing()
        defaults.set(currentVersion, forKey: versionKey)
        let snapshot = store.snapshot()
        let hotkeys = [BuiltInModeID.rewrite, .translate].map { id -> String in
            let hotkey = snapshot.first { $0.id == id.rawValue }?.trigger.hotkey
            return "\(id.rawValue)=\(hotkey?.modifiers.joined(separator: "+") ?? "none")"
        }
        log("migrated to modes v\(currentVersion) from v\(done) modes=\(snapshot.count) "
            + "default=\(ModeStore.defaultMode(in: snapshot).id) \(hotkeys.joined(separator: " "))")
        return true
    }
}
