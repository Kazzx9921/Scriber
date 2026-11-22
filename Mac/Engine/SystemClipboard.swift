import AppKit

/// The general pasteboard as a `ClipboardSource` (情境 → 剪貼簿). Only used when a mode asks for
/// the clipboard; the gate (`ClipboardContext.read`) checks the types before any content is read.
struct SystemClipboard: ClipboardSource {
    var pasteboard: NSPasteboard = .general

    var typeIdentifiers: Set<String> {
        var types = Set((pasteboard.types ?? []).map(\.rawValue))
        for item in pasteboard.pasteboardItems ?? [] {
            types.formUnion(item.types.map(\.rawValue))
        }
        return types
    }

    func plainText() -> String? {
        pasteboard.string(forType: .string)
    }
}
