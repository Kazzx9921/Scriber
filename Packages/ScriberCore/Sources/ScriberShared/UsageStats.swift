import Foundation

// CONTRACT FILE — shared by the app and the keyboard extension.

/// Lifetime usage counters for the Home screen ("time saved compared with typing").
/// Stored in the App Group defaults; both processes add to it. Numbers only, never text.
public struct UsageStats: Sendable, Equatable {
    public var dictations: Int
    /// Characters inserted (CJK characters and Latin letters alike, whitespace excluded).
    public var characters: Int
    /// Seconds spent speaking (length of the recorded clips).
    public var speakingSeconds: Double

    /// Typing speed used for the comparison. Phone typing in Traditional Chinese is roughly
    /// 30–40 characters a minute for most people; we use a conservative 35.
    public static let typingCharactersPerMinute: Double = 35

    /// Estimated seconds saved versus typing the same text on the phone keyboard.
    public var secondsSaved: Double {
        max(0, Double(characters) / Self.typingCharactersPerMinute * 60 - speakingSeconds)
    }

    private static let keys = (count: "stats.dictations", chars: "stats.characters", seconds: "stats.speakingSeconds")

    public static func load() -> UsageStats {
        let d = AppGroup.defaults
        return UsageStats(dictations: d.integer(forKey: keys.count), characters: d.integer(forKey: keys.chars),
                          speakingSeconds: d.double(forKey: keys.seconds))
    }

    /// Call once per successful dictation, from whichever process produced the text.
    public static func record(text: String, speakingSeconds: Double) {
        let d = AppGroup.defaults
        let count = text.unicodeScalars.reduce(0) { $0 + (CharacterSet.whitespacesAndNewlines.contains($1) ? 0 : 1) }
        d.set(d.integer(forKey: keys.count) + 1, forKey: keys.count)
        d.set(d.integer(forKey: keys.chars) + count, forKey: keys.chars)
        d.set(d.double(forKey: keys.seconds) + max(0, speakingSeconds), forKey: keys.seconds)
    }

    public static func reset() {
        let d = AppGroup.defaults
        [keys.count, keys.chars, keys.seconds].forEach { d.removeObject(forKey: $0) }
    }
}
