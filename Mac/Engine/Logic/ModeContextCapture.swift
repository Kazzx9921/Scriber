import Foundation
import ScriberCore

/// The clipboard as 情境 (docs/PRD-模式.md §7.6): read only for a mode that asks for it, at the press
/// of the hotkey. Text only, capped like every context; nothing is read when the pasteboard is
/// marked sensitive or temporary (password managers mark copied passwords with the nspasteboard.org
/// types; Scriber marks its own temporary paste the same way), when macOS denies reading it, or when
/// it holds files rather than text.
///
/// The gate is pure over a `ClipboardSource`, so it is tested with fakes; the app passes the general
/// pasteboard (`SystemClipboard`).
protocol ClipboardSource {
    /// Every type on the pasteboard (all items). Reading types does not read any content.
    var typeIdentifiers: Set<String> { get }
    /// The plain-text representation. This is the read macOS 15.4+ may ask the user about.
    func plainText() -> String?
}

enum ClipboardContext {
    enum Outcome: Equatable {
        case text(String)
        case skipped(Skip)

        var text: String? {
            if case .text(let text) = self { return text }
            return nil
        }

        /// Content-free: "chars=123" or "skipped=concealed".
        var logDescription: String {
            switch self {
            case .text(let text): "chars=\(text.count)"
            case .skipped(let skip): "skipped=\(skip.rawValue)"
            }
        }
    }

    enum Skip: String, Equatable {
        /// "Sensitive, do not show or keep" (password managers).
        case concealed
        /// "Temporary, do not record" (including Scriber's own paste in progress).
        case transient
        /// macOS does not allow Scriber to read the pasteboard (Privacy & Security → 貼上).
        case accessDenied = "access-denied"
        /// Files, images or anything without plain text.
        case notText = "not-text"
        case empty
    }

    static let concealedType = "org.nspasteboard.ConcealedType"
    static let transientType = "org.nspasteboard.TransientType"
    static let plainTextTypes: Set<String> = ["public.utf8-plain-text", "public.plain-text", "NSStringPboardType"]
    /// Copied files carry their names as text; that is not text the user copied.
    static let fileURLType = "public.file-url"

    /// `canRead`: macOS allows Scriber to read the pasteboard (`Permissions.canReadPasteboard`).
    static func read(_ source: ClipboardSource, canRead: Bool,
                     limit: Int = ModeContextLimit.characters) -> Outcome {
        let types = source.typeIdentifiers
        if types.contains(concealedType) { return .skipped(.concealed) }
        if types.contains(transientType) { return .skipped(.transient) }
        guard canRead else { return .skipped(.accessDenied) }
        guard !types.isDisjoint(with: plainTextTypes), !types.contains(fileURLType) else { return .skipped(.notText) }
        guard let text = source.plainText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .skipped(.empty)
        }
        return .text(text.count > limit ? String(text.prefix(limit)) : text)
    }
}
