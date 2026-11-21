import Foundation

/// The HUD's one message style, the same vocabulary as the iOS keyboard's `KeyboardFeedback`: an
/// SF Symbol and a label of at most about six CJK characters inside the pill, never a loose text
/// line. Same cases use the same labels as iOS. The full sentence is kept for the menu's status
/// line and VoiceOver; the diagnostic log gets `type` only.
struct HUDFeedback: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        /// Neutral confirmation.
        case info
        /// Nothing to fix (nothing heard, too short, cancelled).
        case benign
        /// A new attempt may work.
        case failure
        /// Network / server failure with the audio kept: clicking the pill (or 重試 in the menu) retries.
        case retry
        /// Must be fixed in Settings (key, permission, custom engine).
        case needsSetup
    }

    var kind: Kind
    var symbol: String
    /// ≤ 8 CJK characters where possible.
    var label: String
    /// Full sentence (menu status line, VoiceOver).
    var message: String
    /// Stable name for the diagnostic log (never the message text).
    var type: String

    var isProblem: Bool { kind == .failure || kind == .retry || kind == .needsSetup }

    /// How long the HUD shows it (iOS: benign 1.7 s, problems 2.6 s). Retry and setup messages
    /// also go away: the menu keeps 重試 and the status line.
    var duration: TimeInterval {
        // "Press ⌘V" is an instruction the user must act on, so it stays up longer than a
        // plain confirmation even though it is not a problem.
        if type == "copied-no-ax" { return 2.4 }
        switch kind {
        case .info: return 1.2
        case .benign: return 1.7
        case .failure, .retry, .needsSetup: return 2.6
        }
    }

    // MARK: Pipeline / recorder failures → short labels

    /// zh-Hant sentences from ScriberCore errors and the controller → a pill. Unknown sentences get
    /// a generic label rather than being shown whole.
    static func forFailure(message: String, retryable: Bool) -> HUDFeedback {
        guard let rule = rules.first(where: { rule in rule.keywords.contains { message.contains($0) } }) else {
            return retryable
                ? HUDFeedback(kind: .retry, symbol: retrySymbol, label: "處理失敗", message: message, type: "unknown")
                : HUDFeedback(kind: .failure, symbol: "exclamationmark.triangle", label: "出了點問題",
                              message: message, type: "unknown")
        }
        let kind: Kind = rule.kind == .failure && retryable ? .retry : rule.kind
        return HUDFeedback(kind: kind, symbol: kind == .retry ? retrySymbol : rule.symbol, label: rule.label,
                           message: message, type: rule.type)
    }

    static let retrySymbol = "arrow.clockwise"

    private struct Rule {
        var keywords: [String]
        var kind: Kind
        var symbol: String
        var label: String
        var type: String
    }

    /// Ordered: the first rule with a keyword in the message wins.
    private static let rules: [Rule] = [
        Rule(keywords: ["已取消"], kind: .benign, symbol: "xmark", label: "已取消", type: "cancelled"),
        Rule(keywords: ["說話時間太短"], kind: .benign, symbol: "timer", label: "太短了", type: "too-short"),
        Rule(keywords: ["沒有聽到聲音"], kind: .benign, symbol: "mic.slash", label: "沒聽到聲音", type: "no-sound"),
        Rule(keywords: ["沒有辨識到內容"], kind: .benign, symbol: "ear", label: "沒聽到內容", type: "empty-result"),

        Rule(keywords: ["API key 無效"], kind: .needsSetup, symbol: "key.fill", label: "API key 無效", type: "invalid-key"),
        Rule(keywords: ["Groq 或 Anthropic"], kind: .needsSetup, symbol: "key.fill", label: "需要 API key",
             type: "needs-llm-key"),
        Rule(keywords: ["API key"], kind: .needsSetup, symbol: "key.fill", label: "需要 API key", type: "missing-key"),
        Rule(keywords: ["自訂語音辨識"], kind: .needsSetup, symbol: "gearshape", label: "引擎設定有誤", type: "custom-engine"),
        Rule(keywords: ["麥克風權限"], kind: .needsSetup, symbol: "mic.slash", label: "需要麥克風", type: "mic-permission"),
        Rule(keywords: ["找不到麥克風"], kind: .failure, symbol: "mic.slash", label: "找不到麥克風", type: "no-input-device"),

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

        Rule(keywords: ["麥克風中斷"], kind: .failure, symbol: "mic.slash", label: "麥克風中斷", type: "input-lost"),
        Rule(keywords: ["讀不到錄音檔", "錄音失敗", "無法開始錄音"], kind: .failure, symbol: "exclamationmark.triangle",
             label: "錄音失敗", type: "record-failed"),
        Rule(keywords: ["處理失敗", "發生錯誤"], kind: .failure, symbol: "exclamationmark.triangle", label: "出了點問題",
             type: "generic"),
    ]

    // MARK: Mac-only outcomes

    static let cancelled = HUDFeedback(kind: .benign, symbol: "xmark", label: "已取消", message: "已取消",
                                       type: "cancelled")

    /// The text could not be pasted, so it was left on the clipboard for ⌘V.
    static func copiedNoAccessibility() -> HUDFeedback {
        HUDFeedback(kind: .info, symbol: "doc.on.clipboard", label: "請按 ⌘V 貼上",
                    message: "文字已複製，請按 ⌘V 貼上。", type: "copied-no-ax")
    }

    static func copiedSecureInput(appName: String?) -> HUDFeedback {
        let who = appName.map { "「\($0)」" } ?? "某個 App"
        return HUDFeedback(kind: .failure, symbol: "lock.fill", label: "請按 ⌘V 貼上",
                           message: "\(who)正在使用安全輸入（例如密碼欄位），無法自動貼上。文字已複製，請按 ⌘V 貼上。",
                           type: "copied-secure-input")
    }

    static func copiedPasteFailed() -> HUDFeedback {
        HUDFeedback(kind: .failure, symbol: "doc.on.clipboard", label: "請按 ⌘V 貼上",
                    message: "無法自動貼上，文字已複製，請按 ⌘V 貼上。", type: "copied-post-failed")
    }

    static func needsMicrophone() -> HUDFeedback {
        HUDFeedback(kind: .needsSetup, symbol: "mic.slash", label: "需要麥克風",
                    message: "Scriber 沒有麥克風權限，請到「系統設定 → 隱私權與安全性 → 麥克風」打開。",
                    type: "mic-permission")
    }

    static func needsSpeechKey() -> HUDFeedback {
        HUDFeedback(kind: .needsSetup, symbol: "key.fill", label: "需要 API key",
                    message: "語音辨識引擎還沒有 API key，請到設定填寫。", type: "missing-key")
    }

    static func needsLLMKey(for variant: HotkeyVariant) -> HUDFeedback {
        let what = variant == .edit ? "說話改字" : "翻譯"
        return HUDFeedback(kind: .needsSetup, symbol: "key.fill", label: "需要 API key",
                           message: "\(what)需要 Groq 或 Anthropic 的 API key，請到設定填入。", type: "needs-llm-key")
    }

    static let micGranted = HUDFeedback(kind: .info, symbol: "mic", label: "再按一次開始",
                                        message: "已允許麥克風，再按一次快捷鍵開始說話。", type: "mic-granted")

    static func translateOn(languageName: String) -> HUDFeedback {
        HUDFeedback(kind: .info, symbol: "translate", label: "翻譯成\(languageName)",
                    message: "翻譯成\(languageName)", type: "translate-on")
    }
}
