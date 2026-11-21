import Foundation

// CONTRACT FILE — shared by the iOS app, the keyboard and the Mac app.

/// What to do with punctuation in dictated text (applied to texts up to `AppSettings.punctuationLimit` units).
public enum PunctuationRule: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Leave the engine's punctuation as it is.
    case keep
    /// Remove a full stop at the very end ("我到了。" → "我到了").
    case dropFinalPeriod
    /// Remove sentence punctuation altogether ("好，謝謝。" → "好謝謝").
    case removeAll
    /// Replace sentence punctuation with a space ("好，謝謝。" → "好 謝謝"). Line breaks stay.
    case spaces

    public var id: String { rawValue }
}

public extension AppSettings {
    var punctuationRule: PunctuationRule {
        get { PunctuationRule(rawValue: AppGroup.defaults.string(forKey: "punctuationRule") ?? "") ?? .dropFinalPeriod }
        nonmutating set { AppGroup.defaults.set(newValue.rawValue, forKey: "punctuationRule") }
    }

    /// The rule applies to texts of at most this many units (a CJK character, or a Latin
    /// word / number, counts as one). 0 means "any length".
    var punctuationLimit: Int {
        get { AppGroup.defaults.object(forKey: "punctuationLimit") as? Int ?? 20 }
        nonmutating set { AppGroup.defaults.set(max(0, newValue), forKey: "punctuationLimit") }
    }

    /// Choices offered in Settings for `punctuationLimit` (0 = any length).
    static let punctuationLimitChoices = [10, 20, 30, 50, 100, 0]
}

public extension PunctuationRule {
    /// Shown in Settings (zh-Hant).
    var displayName: String {
        switch self {
        case .keep: return "保留標點"
        case .dropFinalPeriod: return "去掉句尾句號"
        case .removeAll: return "去掉所有標點"
        case .spaces: return "標點換成空格"
        }
    }

    static func limitName(_ limit: Int) -> String {
        limit <= 0 ? "不限字數" : "\(limit) 個字以內"
    }

    static let explanation = """
    去掉句尾句號：「我到了。」→「我到了」
    去掉所有標點：「好，謝謝。」→「好謝謝」
    標點換成空格：「好，謝謝。」→「好 謝謝」
    換行會保留。網址、小數、時間裡的符號不會動。「說話改字」不套用。
    """
}
