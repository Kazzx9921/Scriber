import Foundation

// CONTRACT FILE — implementation owned by the "zh-TW + stores" agent.

public enum ZhTW {
    /// Simplified → Traditional (Taiwan) with Taiwan phrasing, equivalent to OpenCC `s2twp`.
    /// Must be idempotent and must leave already-Traditional text, Latin text, numbers and emoji untouched.
    ///
    /// Plain s2twp is neither idempotent nor safe on Traditional input (it rewrites 文件→檔案,
    /// 干擾→幹擾, 馬里蘭→馬裡蘭), so this applies it per sentence, by script:
    /// - Simplified, mostly Simplified, or script-neutral text: exact s2twp (OpenCC 1.4.2 data).
    /// - Traditional text: unchanged.
    /// - Traditional text with stray Simplified characters: only the phrases holding them are converted.
    /// The result never contains a Simplified-only character (`containsSimplified` is false).
    /// Dictionaries load lazily on first use (thread-safe); call `prewarm()` early to hide that cost.
    public static func toTraditionalTaiwan(_ text: String) -> String {
        // No dictionary key is pure ASCII, so ASCII-only text can never change.
        guard text.utf8.contains(where: { $0 >= 0x80 }) else { return text }
        return OpenCCS2TWP.shared.convertScriptAware(text)
    }

    /// Half-width → full-width punctuation next to CJK (, . ? ! : ; ( )), and optional
    /// spacing between CJK and Latin/digits. Must not touch URLs, emails, decimals or code-like tokens.
    public static func normalize(_ text: String, spaceBetweenCJKAndLatin: Bool) -> String {
        ZhTWNormalizer.normalize(text, spaceBetweenCJKAndLatin: spaceBetweenCJKAndLatin)
    }

    /// True if the text still contains characters that only exist in Simplified Chinese. Used by tests/eval.
    ///
    /// A character counts when OpenCC's STCharacters maps it only to other characters, it is not a
    /// Traditional character itself (TSCharacters key), and s2twp never outputs it. So 发/们/这 count,
    /// while 后/干/里/台 (also valid Traditional) and 群/秘/床 (Taiwan-standard forms) do not.
    public static func containsSimplified(_ text: String) -> Bool {
        guard text.utf8.contains(where: { $0 >= 0x80 }) else { return false }
        return OpenCCS2TWP.shared.containsSimplified(text)
    }

    /// Loads the conversion dictionaries now instead of on the first conversion.
    /// Safe to call from any thread, any number of times; call it off the main thread at app launch.
    public static func prewarm() {
        _ = OpenCCS2TWP.shared
    }

    /// Exact OpenCC `s2twp` output, without the script-aware protection of `toTraditionalTaiwan`.
    /// For evaluation and comparison against the reference implementation; not for user text.
    public static func openCCS2TWP(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 >= 0x80 }) else { return text }
        return OpenCCS2TWP.shared.exactString(text)
    }

    /// Everyday Taiwan usage writes 台 (台灣、台北、平台、舞台), while OpenCC's s2twp standard emits 臺.
    /// Applied to every dictation output, including text that was already Traditional.
    public static func preferCommonTai(_ text: String) -> String {
        text.contains("臺") ? text.replacingOccurrences(of: "臺", with: "台") : text
    }
}
