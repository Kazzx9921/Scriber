import Foundation
import Observation
import ScriberCore
import ScriberShared

/// Observable mirror of `AppSettings` (standard defaults on macOS), the hotkey, and key presence
/// in the Keychain. API key values are never held here, only whether one is stored.
///
/// `MacSettings(sample:)` builds a detached copy for snapshot renders: it never touches the
/// Keychain, the defaults or the dictation controller.
@MainActor
@Observable
final class MacSettings {
    static let shared = MacSettings()

    @ObservationIgnored private let store = AppSettings.shared
    @ObservationIgnored private let keychain = KeychainStore.shared
    @ObservationIgnored private let defaults = AppGroup.defaults
    /// A sample copy: nothing is read from or written to the system.
    @ObservationIgnored private let isSample: Bool

    var hasCompletedOnboarding: Bool {
        didSet { if !isSample { store.hasCompletedOnboarding = hasCompletedOnboarding } }
    }
    var sttProvider: STTProviderKind {
        didSet {
            guard sttProvider != oldValue, !isSample else { return }
            store.sttProvider = sttProvider
            DiagLog.log("app", "settings stt=\(sttProvider.rawValue)")
        }
    }
    var polishProvider: PolishProviderKind {
        didSet {
            guard polishProvider != oldValue, !isSample else { return }
            store.polishProvider = polishProvider
            DiagLog.log("app", "settings polish=\(polishProvider.rawValue)")
        }
    }
    var forceTraditional: Bool { didSet { if !isSample { store.forceTraditional = forceTraditional } } }
    var punctuationRule: PunctuationRule = .dropFinalPeriod {
        didSet { if !isSample { store.punctuationRule = punctuationRule } }
    }
    var punctuationLimit: Int = 20 {
        didSet { if !isSample { store.punctuationLimit = punctuationLimit } }
    }
    var spaceBetweenCJKAndLatin: Bool {
        didSet { if !isSample { store.spaceBetweenCJKAndLatin = spaceBetweenCJKAndLatin } }
    }
    /// 即時顯示文字: stream to Scribe v3's real-time model while speaking (the feature itself lives
    /// in the dictation engine; this is only the switch).
    var realtimeEnabled: Bool {
        didSet {
            guard realtimeEnabled != oldValue, !isSample else { return }
            store.realtimeEnabled = realtimeEnabled
            DiagLog.log("app", "settings realtime=\(realtimeEnabled)")
        }
    }
    var saveHistory: Bool {
        didSet {
            guard !isSample else { return }
            store.saveHistory = saveHistory
            DiagLog.log("app", "settings saveHistory=\(saveHistory)")
        }
    }

    // MARK: Translation

    var translateLanguageID: String {
        didSet {
            guard translateLanguageID != oldValue, !isSample else { return }
            store.translateLanguageID = translateLanguageID
            DiagLog.log("app", "settings translate=\(translateLanguageID)")
        }
    }
    var translateQuickLanguageIDs: [String] {
        didSet {
            if translateQuickLanguageIDs != oldValue, !isSample { store.translateQuickLanguageIDs = translateQuickLanguageIDs }
        }
    }
    /// Menu toggle: the plain trigger translates instead of dictating.
    var translateLocked: Bool {
        didSet {
            guard !isSample else { return }
            defaults.set(translateLocked, forKey: "mac.translateLocked")
            DiagLog.log("app", "settings translateLocked=\(translateLocked)")
        }
    }

    /// Put the user's clipboard back after pasting. Needs a programmatic pasteboard read, which
    /// macOS 15.4+ may ask about (「允許從其他 App 貼上」). Off: the dictated text stays on the clipboard.
    var restoreClipboard: Bool {
        didSet {
            guard !isSample else { return }
            defaults.set(restoreClipboard, forKey: "mac.restoreClipboard")
            DiagLog.log("app", "settings restoreClipboard=\(restoreClipboard)")
        }
    }

    // MARK: Custom engine

    var customSTTName: String { didSet { if !isSample { store.customSTTName = customSTTName } } }
    var customSTTBaseURL: String { didSet { if !isSample { store.customSTTBaseURL = customSTTBaseURL } } }
    var customSTTModel: String { didSet { if !isSample { store.customSTTModel = customSTTModel } } }

    // MARK: Hotkey

    var hotkey: HotkeyConfig {
        didSet {
            guard hotkey != oldValue, !isSample else { return }
            hotkey.save(to: defaults)
            DictationController.shared.applyHotkey(hotkey)
            if hotkey.editModifier != oldValue.editModifier || hotkey.translateModifier != oldValue.translateModifier {
                // Modes (M1): keep the copy on 改寫 / 翻譯 current until the mode editor owns these keys.
                ModeStore.shared.setLegacyVariantHotkeys(editModifier: hotkey.editModifier.rawValue,
                                                         translateModifier: hotkey.translateModifier.rawValue)
            }
        }
    }

    // MARK: Keys

    private(set) var storedKeys: Set<APIKeyKind> = []

    init() {
        isSample = false
        hasCompletedOnboarding = store.hasCompletedOnboarding
        sttProvider = store.sttProvider
        polishProvider = store.polishProvider
        forceTraditional = store.forceTraditional
        spaceBetweenCJKAndLatin = store.spaceBetweenCJKAndLatin
        punctuationRule = store.punctuationRule
        punctuationLimit = store.punctuationLimit
        realtimeEnabled = store.realtimeEnabled
        saveHistory = store.saveHistory
        translateLanguageID = store.translateLanguageID
        translateQuickLanguageIDs = store.translateQuickLanguageIDs
        translateLocked = AppGroup.defaults.bool(forKey: "mac.translateLocked")
        restoreClipboard = AppGroup.defaults.object(forKey: "mac.restoreClipboard") as? Bool ?? true
        customSTTName = store.customSTTName
        customSTTBaseURL = store.customSTTBaseURL
        customSTTModel = store.customSTTModel
        hotkey = HotkeyConfig.load(from: AppGroup.defaults)
        refreshKeys()
    }

    /// Detached sample state for snapshot renders and previews.
    struct Sample {
        var hasCompletedOnboarding = true
        var sttProvider: STTProviderKind = .elevenLabsScribe
        var polishProvider: PolishProviderKind = .off
        var keys: Set<APIKeyKind> = []
        var hotkey = HotkeyConfig()
        var saveHistory = true
        var realtimeEnabled = false
        var customEngine: (name: String, baseURL: String, model: String)?
    }

    init(sample: Sample) {
        isSample = true
        hasCompletedOnboarding = sample.hasCompletedOnboarding
        sttProvider = sample.sttProvider
        polishProvider = sample.polishProvider
        forceTraditional = true
        spaceBetweenCJKAndLatin = true
        realtimeEnabled = sample.realtimeEnabled
        saveHistory = sample.saveHistory
        translateLanguageID = "en"
        translateQuickLanguageIDs = ["en", "ja", "ko"]
        translateLocked = false
        restoreClipboard = true
        customSTTName = sample.customEngine?.name ?? ""
        customSTTBaseURL = sample.customEngine?.baseURL ?? ""
        customSTTModel = sample.customEngine?.model ?? ""
        hotkey = sample.hotkey
        storedKeys = sample.keys
    }

    func hasKey(_ kind: APIKeyKind) -> Bool { storedKeys.contains(kind) }

    func refreshKeys() {
        guard !isSample else { return }
        storedKeys = Set(APIKeyKind.allCases.filter { keychain.hasKey(for: $0) })
    }

    func saveKey(_ value: String, for kind: APIKeyKind) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSample else { return }
        keychain.setKey(trimmed, for: kind)
        refreshKeys()
        DiagLog.log("app", "key saved kind=\(kind.rawValue) stored=\(hasKey(kind))")
        adoptEngineIfNeeded(afterSaving: kind)
    }

    func deleteKey(_ kind: APIKeyKind) {
        guard !isSample else { return }
        keychain.setKey(nil, for: kind)
        refreshKeys()
        DiagLog.log("app", "key removed kind=\(kind.rawValue)")
    }

    /// Checks `draft` if given, else the stored key. nil on success, else a user-facing message.
    /// The key is only passed to the provider's check request, never logged or shown.
    func validate(_ kind: APIKeyKind, draft: String? = nil) async -> String? {
        guard !isSample else { return nil }
        let candidate = draft?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        if let candidate, !candidate.isEmpty {
            key = candidate
        } else if let stored = keychain.key(for: kind), !stored.isEmpty {
            key = stored
        } else {
            return "還沒有可以測試的 key"
        }
        let result = await STTFactory.validateKey(kind, key: key)
        DiagLog.log("app", "key check kind=\(kind.rawValue) ok=\(result == nil)")
        return result
    }

    // MARK: Translation helpers

    var translateLanguage: TranslateLanguage { TranslateLanguage.find(translateLanguageID) }

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

    var customEngineName: String {
        let name = customSTTName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "自訂" : name
    }

    /// Who a key belongs to, as shown in the UI (the custom engine's own name for `.custom`).
    func vendor(_ kind: APIKeyKind) -> String {
        kind == .custom ? customEngineName : kind.vendor
    }

    var isCustomEngineConfigured: Bool {
        guard (try? CustomSTTEndpoint.parse(customSTTBaseURL)) != nil else { return false }
        return !customSTTModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveCustomEngine(name: String, baseURL: String, model: String) {
        customSTTName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customSTTBaseURL = (try? CustomSTTEndpoint.parse(baseURL))?.baseURL.absoluteString
            ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var fallbackSTTProvider: STTProviderKind {
        for kind in [APIKeyKind.elevenLabs, .groq] where hasKey(kind) {
            if let engine = kind.defaultSTTProvider { return engine }
        }
        return .elevenLabsScribe
    }

    // MARK: Readiness

    /// Whether `kind` can be used right now (key present, custom engine filled in).
    func isReady(_ kind: STTProviderKind) -> Bool {
        if kind == .custom, !isCustomEngineConfigured { return false }
        return hasKey(kind.requiredKey)
    }

    var isSTTReady: Bool { isReady(sttProvider) }

    /// Translate and 說話改字 work with either LLM key, whatever the polish setting.
    var hasLLMKey: Bool { hasKey(.groq) || hasKey(.anthropic) }

    var missingPolishKey: APIKeyKind? {
        guard let kind = polishProvider.requiredKey else { return nil }
        return hasKey(kind) ? nil : kind
    }

    /// After the user adds a speech key, switch to an engine that can use it if the current one can't.
    private func adoptEngineIfNeeded(afterSaving kind: APIKeyKind) {
        guard !isSTTReady, let engine = kind.defaultSTTProvider, isReady(engine) else { return }
        sttProvider = engine
    }

    var logDescription: String {
        "stt=\(sttProvider.rawValue) realtime=\(realtimeEnabled) polish=\(polishProvider.rawValue) trad=\(forceTraditional) "
            + "space=\(spaceBetweenCJKAndLatin) history=\(saveHistory) translate=\(translateLanguageID) "
            + "translateLocked=\(translateLocked) restoreClipboard=\(restoreClipboard) keys=\(storedKeys.map(\.rawValue).sorted().joined(separator: ","))"
    }
}
