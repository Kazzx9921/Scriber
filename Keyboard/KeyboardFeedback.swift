import Foundation

/// The keyboard's one message style: an icon and a very short label shown inside the mic pill
/// (never a loose text line, never a layout shift). Failures from both recording paths and the
/// keyboard's own hints (translate language, translate unavailable) all go through here. The
/// full sentence is kept for VoiceOver; the diagnostics log gets `type` only.
struct KeyboardFeedback: Hashable {
    enum Kind: String, Hashable {
        /// Neutral confirmation (e.g. the translate language). Tapping the pill dictates as usual.
        case info
        /// Nothing to fix (nothing heard, too short, cancelled): goes away by itself.
        case benign
        /// A new attempt may work: goes away by itself; tapping the pill starts over.
        case failure
        /// Network / server failure with the audio kept: the pill shows a retry glyph and tapping
        /// it retries; the left round key dismisses.
        case retry
        /// Must be fixed in Scriber (key, AI polish, permission, custom engine): tapping the pill
        /// opens the app; the left round key dismisses.
        case needsSetup
    }

    var kind: Kind
    /// SF Symbol (iOS 17-safe names only).
    var symbol: String
    /// ≤ 6 CJK characters where possible.
    var label: String
    /// Full sentence for VoiceOver.
    var spoken: String
    /// Stable name for the diagnostics log (never the message text).
    var type: String
    /// nil = stays until the user acts (retry, open the app, or the left key).
    var dismissAfter: TimeInterval?

    init(kind: Kind, symbol: String, label: String, spoken: String, type: String, dismissAfter: TimeInterval? = nil) {
        self.kind = kind
        self.symbol = symbol
        self.label = label
        self.spoken = spoken
        self.type = type
        self.dismissAfter = dismissAfter ?? Self.defaultDuration(kind)
    }

    /// Shake + error haptic for these; benign outcomes only get a light warning tick.
    var isProblem: Bool { kind == .failure || kind == .retry || kind == .needsSetup }

    static func defaultDuration(_ kind: Kind) -> TimeInterval? {
        switch kind {
        case .info: return 1.2
        case .benign: return 1.7
        case .failure: return 2.6
        case .retry, .needsSetup: return nil
        }
    }

    // MARK: Failures → short labels (the one place that maps them)

    /// The app (and the in-keyboard pipeline) send zh-Hant sentences; this turns them into a
    /// pill. Unknown sentences get a generic label rather than being shown whole.
    static func forFailure(message: String, retryable: Bool) -> KeyboardFeedback {
        guard let rule = rules.first(where: { rule in rule.keywords.contains { message.contains($0) } }) else {
            return retryable
                ? KeyboardFeedback(kind: .retry, symbol: retrySymbol, label: "處理失敗", spoken: message, type: "unknown")
                : KeyboardFeedback(kind: .failure, symbol: "exclamationmark.triangle", label: "出了點問題",
                                   spoken: message, type: "unknown")
        }
        // Only a retryable request has audio kept for 重試.
        let kind: Kind = rule.kind == .failure && retryable ? .retry : rule.kind
        return KeyboardFeedback(kind: kind, symbol: kind == .retry ? retrySymbol : rule.symbol, label: rule.label,
                                spoken: message, type: rule.type)
    }

    static let retrySymbol = "arrow.clockwise"

    private struct Rule {
        /// Any of these substrings selects the rule.
        var keywords: [String]
        /// `.benign`, `.needsSetup` or `.failure` (which becomes `.retry` for retryable requests).
        var kind: Kind
        var symbol: String
        var label: String
        var type: String
    }

    /// Ordered: the first rule with a keyword in the message wins, so specific rules come first.
    /// Sources: ScriberCore `ProviderError` / `PolishError` / `CustomSTTError`, the app's
    /// `DictationEngine.fail(…)` messages, and this keyboard's own `.failed` messages.
    private static let rules: [Rule] = [
        Rule(keywords: ["已取消"], kind: .benign, symbol: "xmark", label: "已取消", type: "cancelled"),
        Rule(keywords: ["說話時間太短"], kind: .benign, symbol: "timer", label: "太短了", type: "too-short"),
        Rule(keywords: ["沒有聽到聲音"], kind: .benign, symbol: "mic.slash", label: "沒聽到聲音", type: "no-sound"),
        Rule(keywords: ["沒有辨識到內容"], kind: .benign, symbol: "ear", label: "沒聽到內容", type: "empty-result"),

        Rule(keywords: ["API key 無效"], kind: .needsSetup, symbol: "key.fill", label: "API key 無效", type: "invalid-key"),
        Rule(keywords: ["API key"], kind: .needsSetup, symbol: "key.fill", label: "需要 API key", type: "missing-key"),
        Rule(keywords: ["需要開啟 AI 潤飾"], kind: .needsSetup, symbol: "sparkles", label: "需要 AI 潤飾", type: "needs-polish"),
        Rule(keywords: ["自訂語音辨識"], kind: .needsSetup, symbol: "gearshape", label: "引擎設定有誤", type: "custom-engine"),
        Rule(keywords: ["麥克風權限"], kind: .needsSetup, symbol: "mic.slash", label: "需要麥克風", type: "mic-permission"),

        Rule(keywords: ["額度不足"], kind: .failure, symbol: "creditcard", label: "額度不足", type: "quota"),
        Rule(keywords: ["頻率超過上限"], kind: .failure, symbol: "hourglass", label: "用量超限", type: "rate-limit"),
        Rule(keywords: ["沒有網路"], kind: .failure, symbol: "wifi.slash", label: "沒有網路", type: "offline"),
        Rule(keywords: ["逾時"], kind: .failure, symbol: "clock", label: "連線逾時", type: "timeout"),
        Rule(keywords: ["網路連線失敗"], kind: .failure, symbol: "wifi.slash", label: "連線失敗", type: "network"),
        Rule(keywords: ["服務暫時無法使用"], kind: .failure, symbol: "icloud.slash", label: "服務異常", type: "server"),
        Rule(keywords: ["找不到指定的模型"], kind: .failure, symbol: "questionmark", label: "找不到服務", type: "not-found"),
        Rule(keywords: ["錄音檔太大"], kind: .failure, symbol: "timer", label: "錄音太長", type: "too-large"),
        Rule(keywords: ["服務無法處理", "服務回應錯誤"], kind: .failure, symbol: "exclamationmark.triangle",
             label: "服務錯誤", type: "service-error"),
        Rule(keywords: ["AI 潤飾拒絕"], kind: .failure, symbol: "sparkles", label: "AI 拒絕處理", type: "polish-refused"),
        Rule(keywords: ["AI 潤飾"], kind: .failure, symbol: "sparkles", label: "AI 出錯了", type: "polish-failed"),

        Rule(keywords: ["通話或其他 App", "無法啟動麥克風"], kind: .failure, symbol: "mic.slash", label: "麥克風忙碌",
             type: "mic-busy"),
        Rule(keywords: ["沒有收到這段錄音"], kind: .failure, symbol: "waveform", label: "沒收到錄音", type: "lost-audio"),
        Rule(keywords: ["讀不到錄音檔", "錄音失敗", "無法開始錄音"], kind: .failure, symbol: "exclamationmark.triangle",
             label: "錄音失敗", type: "record-failed"),
        Rule(keywords: ["無法自動打開"], kind: .failure, symbol: "arrow.up.forward.app", label: "請手動開啟",
             type: "open-failed"),
        Rule(keywords: ["這次要打開 Scriber", "沒有開始錄音", "沒有回應", "已停止", "重新啟動"], kind: .failure,
             symbol: "hand.tap", label: "再點一次", type: "tap-again"),
        Rule(keywords: ["處理失敗", "發生錯誤"], kind: .failure, symbol: "exclamationmark.triangle", label: "出了點問題",
             type: "generic"),
    ]

    // MARK: Keyboard hints

    static func translateOn(languageName: String) -> KeyboardFeedback {
        KeyboardFeedback(kind: .info, symbol: "translate", label: "翻譯成\(languageName)",
                         spoken: "翻譯成\(languageName)", type: "translate-on")
    }

    /// Tapped the translate key while it cannot work. Transient, but tapping it opens Scriber.
    static func translateNeedsPolish() -> KeyboardFeedback {
        KeyboardFeedback(kind: .needsSetup, symbol: "sparkles", label: "需要 AI 潤飾",
                         spoken: "翻譯需要開啟 AI 潤飾。點一下可打開 Scriber 設定。", type: "translate-needs-polish",
                         dismissAfter: 2.6)
    }

    static func translateNeedsKey() -> KeyboardFeedback {
        KeyboardFeedback(kind: .needsSetup, symbol: "key.fill", label: "需要 API key",
                         spoken: "AI 潤飾還沒有 API key。點一下可打開 Scriber 設定。", type: "translate-needs-key",
                         dismissAfter: 2.6)
    }

    static let openAppFailed = KeyboardFeedback(kind: .failure, symbol: "arrow.up.forward.app", label: "請手動開啟",
                                                spoken: "無法自動打開 Scriber，請手動開啟 Scriber App", type: "open-failed")
}
