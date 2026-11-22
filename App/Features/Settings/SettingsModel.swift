import Foundation
import Observation
import ScriberCore
import ScriberShared

/// Observable mirror of `AppSettings` (App Group UserDefaults) and key presence in the Keychain.
/// Keeps the key strings in one place (the contract) while giving SwiftUI something to observe.
/// API key values are never held here, only whether one is stored.
@MainActor
@Observable
final class SettingsModel {
    static let shared = SettingsModel()

    @ObservationIgnored private let store: AppSettings
    @ObservationIgnored private let keychain: KeychainStore

    var hasCompletedOnboarding: Bool { didSet { store.hasCompletedOnboarding = hasCompletedOnboarding } }
    var sttProvider: STTProviderKind { didSet { store.sttProvider = sttProvider } }
    var polishProvider: PolishProviderKind { didSet { store.polishProvider = polishProvider } }
    var sessionMinutes: Int { didSet { store.sessionMinutes = sessionMinutes } }
    var spaceBetweenCJKAndLatin: Bool { didSet { store.spaceBetweenCJKAndLatin = spaceBetweenCJKAndLatin } }
    var punctuationRule: PunctuationRule { didSet { store.punctuationRule = punctuationRule } }
    var punctuationLimit: Int { didSet { store.punctuationLimit = punctuationLimit } }
    var forceTraditional: Bool { didSet { store.forceTraditional = forceTraditional } }
    var saveHistory: Bool { didSet { store.saveHistory = saveHistory } }
    var hapticsEnabled: Bool { didSet { store.hapticsEnabled = hapticsEnabled } }

    // MARK: Translation
    /// The language translate mode outputs now (the keyboard can change it too; see `reloadShared`).
    var translateLanguageID: String {
        didSet { if translateLanguageID != oldValue { store.translateLanguageID = translateLanguageID } }
    }
    /// The three languages on the keyboard's translate key, in order, never duplicated.
    var translateQuickLanguageIDs: [String] {
        didSet { if translateQuickLanguageIDs != oldValue { store.translateQuickLanguageIDs = translateQuickLanguageIDs } }
    }

    // MARK: Custom speech engine
    var customSTTName: String { didSet { store.customSTTName = customSTTName } }
    var customSTTBaseURL: String { didSet { store.customSTTBaseURL = customSTTBaseURL } }
    var customSTTModel: String { didSet { store.customSTTModel = customSTTModel } }

    // MARK: Experimental
    var standbyMode: StandbyMode {
        didSet {
            guard standbyMode != oldValue else { return }
            store.standbyMode = standbyMode
            // Choosing a mode again is the user's way to retry one that iOS refused.
            StandbyMemory.outputOnlyRefusal = nil
            DictationEngine.shared.standbySettingsChanged()
        }
    }
    var standbyMinutes: Int {
        didSet {
            guard standbyMinutes != oldValue else { return }
            store.standbyMinutes = standbyMinutes
            DictationEngine.shared.standbySettingsChanged()
        }
    }
    var autoReturn: Bool {
        didSet {
            store.autoReturn = autoReturn
            DiagLog.log("app", "settings autoReturn=\(autoReturn)")
        }
    }
    /// The app to return to after the keyboard opened Scriber (`AutoReturnCatalog`); nil = none.
    var autoReturnTargetID: String? {
        didSet {
            AutoReturnCatalog.selectedID = autoReturnTargetID
            DiagLog.log("app", "settings autoReturnTarget=\(autoReturnTargetID ?? "none")")
        }
    }
    var inKeyboardCapture: Bool {
        didSet {
            store.inKeyboardCapture = inKeyboardCapture
            DiagLog.log("app", "settings inKeyboardCapture=\(inKeyboardCapture)")
        }
    }

    private(set) var storedKeys: Set<APIKeyKind> = []

    static let sessionMinuteOptions = [5, 10, 15, 30]
    static let standbyMinuteOptions = [1, 5, 10, 30]

    init(store: AppSettings = .shared, keychain: KeychainStore = .shared) {
        self.store = store
        self.keychain = keychain
        hasCompletedOnboarding = store.hasCompletedOnboarding
        sttProvider = store.sttProvider
        polishProvider = store.polishProvider
        sessionMinutes = store.sessionMinutes
        spaceBetweenCJKAndLatin = store.spaceBetweenCJKAndLatin
        punctuationRule = store.punctuationRule
        punctuationLimit = store.punctuationLimit
        forceTraditional = store.forceTraditional
        saveHistory = store.saveHistory
        hapticsEnabled = store.hapticsEnabled
        translateLanguageID = store.translateLanguageID
        translateQuickLanguageIDs = store.translateQuickLanguageIDs
        customSTTName = store.customSTTName
        customSTTBaseURL = store.customSTTBaseURL
        customSTTModel = store.customSTTModel
        standbyMode = store.standbyMode
        standbyMinutes = store.standbyMinutes
        autoReturn = store.autoReturn
        autoReturnTargetID = AutoReturnCatalog.selectedID
        inKeyboardCapture = store.inKeyboardCapture
        refreshKeys()
    }

    /// Picks up values the keyboard may have changed while the app was in the background.
    func reloadShared() {
        let language = store.translateLanguageID
        if language != translateLanguageID { translateLanguageID = language }
        let quick = store.translateQuickLanguageIDs
        if quick != translateQuickLanguageIDs { translateQuickLanguageIDs = quick }
    }

    // MARK: Keys

    func hasKey(_ kind: APIKeyKind) -> Bool { storedKeys.contains(kind) }

    func refreshKeys() {
        storedKeys = Set(APIKeyKind.allCases.filter { keychain.hasKey(for: $0) })
        #if DEBUG
        if DebugLaunch.demoReady { storedKeys.formUnion([.elevenLabs, .groq]) } // display only
        #endif
    }

    func saveKey(_ value: String, for kind: APIKeyKind) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keychain.setKey(trimmed, for: kind)
        refreshKeys()
    }

    func deleteKey(_ kind: APIKeyKind) {
        keychain.setKey(nil, for: kind)
        refreshKeys()
    }

    /// Validates `draft` if given, else the stored key. Returns nil on success, else a user-facing message.
    /// The stored key is read only for the duration of the request and never surfaced.
    func validate(_ kind: APIKeyKind, draft: String? = nil) async -> String? {
        let candidate = draft?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        if let candidate, !candidate.isEmpty {
            key = candidate
        } else if let stored = keychain.key(for: kind), !stored.isEmpty {
            key = stored
        } else {
            return "還沒有可以測試的 key"
        }
        return await STTFactory.validateKey(kind, key: key)
    }

    /// Checks the custom engine against a base URL that may not be saved yet, with `draft` or the
    /// stored custom key. Same contract as `validate`.
    func validateCustom(draft: String?, baseURL: String) async -> String? {
        let candidate = draft?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        if let candidate, !candidate.isEmpty {
            key = candidate
        } else if let stored = keychain.key(for: .custom), !stored.isEmpty {
            key = stored
        } else {
            return "還沒有可以測試的 key"
        }
        return await STTFactory.validateCustomKey(key, baseURL: baseURL)
    }

    // MARK: Translation

    /// Puts `id` into quick slot `index`; if it is already in another slot, the two swap places.
    func setQuickLanguage(_ id: String, at index: Int) {
        var ids = translateQuickLanguageIDs
        guard ids.indices.contains(index), ids[index] != id else { return }
        if let other = ids.firstIndex(of: id) {
            ids.swapAt(index, other)
        } else {
            ids[index] = id
        }
        translateQuickLanguageIDs = ids
    }

    // MARK: Custom engine

    /// Display name of the custom engine ("自訂" until it has one).
    var customEngineName: String {
        let name = customSTTName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "自訂") : name
    }

    /// URL and model are filled in and valid (the key is tracked separately).
    var isCustomEngineConfigured: Bool {
        CustomEngineForm.problem(baseURL: customSTTBaseURL, model: customSTTModel) == nil
    }

    func saveCustomEngine(name: String, baseURL: String, model: String) {
        customSTTName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customSTTBaseURL = CustomEngineForm.normalized(baseURL)
        customSTTModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        DiagLog.log("app", "settings custom engine saved")
    }

    func removeCustomEngine() {
        customSTTName = ""
        customSTTBaseURL = ""
        customSTTModel = ""
        deleteKey(.custom)
        if sttProvider == .custom { sttProvider = fallbackSTTProvider }
        DiagLog.log("app", "settings custom engine removed")
    }

    /// A built-in engine the user has a key for, else the default.
    private var fallbackSTTProvider: STTProviderKind {
        for kind in [APIKeyKind.elevenLabs, .groq] where hasKey(kind) {
            if let engine = kind.defaultSTTProvider { return engine }
        }
        return .elevenLabsScribe
    }

    // MARK: Derived setup state

    /// What the selected speech engine still needs: its key, or for the custom engine also its
    /// URL and model (both are fixed in the same form).
    var missingSTTKey: APIKeyKind? {
        let kind = sttProvider.requiredKey
        if kind == .custom, !isCustomEngineConfigured { return .custom }
        return hasKey(kind) ? nil : kind
    }

    /// The key the selected polish provider needs, if it's missing.
    var missingPolishKey: APIKeyKind? {
        guard let kind = polishProvider.requiredKey else { return nil }
        return hasKey(kind) ? nil : kind
    }

    /// True when some speech engine is usable.
    var hasAnySTTKey: Bool {
        APIKeyKind.allCases.contains { kind in
            kind.canTranscribe && hasKey(kind) && (kind != .custom || isCustomEngineConfigured)
        }
    }

    /// Whether `kind` can be used right now (key present, custom engine filled in).
    func isReady(_ kind: STTProviderKind) -> Bool {
        if kind == .custom, !isCustomEngineConfigured { return false }
        return hasKey(kind.requiredKey)
    }

    /// After the user adds a speech key, switch to an engine that can use it if the current one can't.
    func adoptEngineIfNeeded(afterSaving kind: APIKeyKind) {
        guard missingSTTKey != nil, let engine = kind.defaultSTTProvider, isReady(engine) else { return }
        sttProvider = engine
    }
}

/// Validation and clean-up for the custom engine form. The URL rules are the provider's own
/// (`CustomSTTEndpoint.parse`: https only, a bare host gets https, a pasted
/// ".../audio/transcriptions" is cut back to the base), so the form and the engine always agree.
enum CustomEngineForm {
    /// nil when valid, else a short user-facing problem.
    static func problem(baseURL: String, model: String) -> String? {
        do {
            _ = try CustomSTTEndpoint.parse(baseURL)
        } catch {
            return message(for: error)
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "請填模型名稱")
        }
        return nil
    }

    /// The base URL as the provider will use it, or the trimmed input if it does not parse.
    static func normalized(_ baseURL: String) -> String {
        (try? CustomSTTEndpoint.parse(baseURL))?.baseURL.absoluteString
            ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func message(for error: Error) -> String {
        switch error as? CustomSTTError {
        case .missingURL?: String(localized: "請填網址")
        case .insecureURL?: String(localized: "網址要用 https:// 開頭")
        default: String(localized: "網址格式不對")
        }
    }
}
