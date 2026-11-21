import Foundation

// CONTRACT FILE — shared by the app and the keyboard extension.

/// A language the user can translate into.
public struct TranslateLanguage: Identifiable, Hashable, Sendable {
    /// BCP-47-ish id, stored in settings.
    public let id: String
    /// Shown in the UI (Traditional Chinese).
    public let displayName: String
    /// Short label for the keyboard key, 1–2 characters / letters ("EN", "日", "韓").
    public let shortLabel: String
    /// Name used inside the LLM prompt.
    public let promptName: String

    public static let all: [TranslateLanguage] = [
        .init(id: "en", displayName: "英文", shortLabel: "EN", promptName: "English"),
        .init(id: "ja", displayName: "日文", shortLabel: "日", promptName: "Japanese"),
        .init(id: "ko", displayName: "韓文", shortLabel: "韓", promptName: "Korean"),
        .init(id: "zh-Hant", displayName: "繁體中文", shortLabel: "繁", promptName: "Traditional Chinese (Taiwan)"),
        .init(id: "zh-Hans", displayName: "簡體中文", shortLabel: "简", promptName: "Simplified Chinese"),
        .init(id: "es", displayName: "西班牙文", shortLabel: "ES", promptName: "Spanish"),
        .init(id: "fr", displayName: "法文", shortLabel: "FR", promptName: "French"),
        .init(id: "de", displayName: "德文", shortLabel: "DE", promptName: "German"),
        .init(id: "it", displayName: "義大利文", shortLabel: "IT", promptName: "Italian"),
        .init(id: "pt", displayName: "葡萄牙文", shortLabel: "PT", promptName: "Portuguese"),
        .init(id: "th", displayName: "泰文", shortLabel: "TH", promptName: "Thai"),
        .init(id: "vi", displayName: "越南文", shortLabel: "VI", promptName: "Vietnamese"),
        .init(id: "id", displayName: "印尼文", shortLabel: "ID", promptName: "Indonesian"),
    ]

    public static func find(_ id: String) -> TranslateLanguage {
        all.first { $0.id == id } ?? all[0]
    }
}

public extension AppSettings {
    /// The three languages offered on the keyboard's translate key (long-press to pick).
    var translateQuickLanguageIDs: [String] {
        get {
            let stored = AppGroup.defaults.stringArray(forKey: "translateQuickLanguageIDs") ?? []
            let valid = stored.filter { id in TranslateLanguage.all.contains { $0.id == id } }
            return valid.count == 3 ? valid : ["en", "ja", "ko"]
        }
        nonmutating set { AppGroup.defaults.set(Array(newValue.prefix(3)), forKey: "translateQuickLanguageIDs") }
    }

    /// The language translate mode currently outputs. Setting it also updates `translateTarget`
    /// (the prompt name the pipeline reads).
    var translateLanguageID: String {
        get { AppGroup.defaults.string(forKey: "translateLanguageID") ?? "en" }
        nonmutating set {
            AppGroup.defaults.set(newValue, forKey: "translateLanguageID")
            translateTarget = TranslateLanguage.find(newValue).promptName
        }
    }
}
