import Foundation
import ScriberShared

/// Applies the user's `PunctuationRule` to finished text. Pure and deterministic.
public enum PunctuationStyler {
    /// CJK sentence punctuation that the "remove" and "space" rules act on. Quotes and brackets
    /// (「」（）《》) are kept: they mark structure, not pauses.
    private static let cjkMarks: Set<Character> = ["，", "。", "、", "；", "：", "？", "！", "．", "…", "⋯", "—"]
    /// ASCII marks act as punctuation only where they end a clause (see `isClauseMark`).
    private static let asciiMarks: Set<Character> = [",", ".", ";", ":", "?", "!"]

    public static func apply(_ text: String, rule: PunctuationRule, limit: Int) -> String {
        guard rule != .keep, !text.isEmpty else { return text }
        guard limit <= 0 || DictationPipeline.unitCount(text) <= limit else { return text }
        switch rule {
        case .keep: return text
        case .dropFinalPeriod: return droppingFinalPeriod(text)
        case .removeAll: return replacingMarks(in: text, with: nil)
        case .spaces: return replacingMarks(in: text, with: " ")
        }
    }

    /// Removes one trailing full stop (。 or .). Question and exclamation marks and ellipses stay.
    static func droppingFinalPeriod(_ text: String) -> String {
        guard let last = text.last, last == "。" || last == "．" || last == "." else { return text }
        let body = text.dropLast()
        // "..." / "。。" / "…。" are deliberate trailing-off, not a sentence end.
        if let previous = body.last, previous == "." || previous == "。" || previous == "…" { return text }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? text : trimmed
    }

    /// Removes sentence punctuation (`replacement` nil) or turns each run of it into one space.
    /// Line breaks are preserved; decimals, times, thousands separators, URLs, e-mail addresses
    /// and abbreviations keep their dots, colons and commas.
    static func replacingMarks(in text: String, with replacement: Character?) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let chars = Array(line)
            var out: [Character] = []
            out.reserveCapacity(chars.count)
            for (i, c) in chars.enumerated() {
                guard isClauseMark(c, at: i, in: chars) else {
                    out.append(c)
                    continue
                }
                guard let replacement else { continue }
                // One space per run of marks, never doubled next to existing whitespace.
                if let last = out.last, last != " " { out.append(replacement) }
            }
            // Collapse double spaces left where a mark sat next to a space, and trim the ends.
            var collapsed: [Character] = []
            for c in out where !(c == " " && collapsed.last == " ") { collapsed.append(c) }
            return String(collapsed).trimmingCharacters(in: .whitespaces)
        }
        let joined = lines.joined(separator: "\n")
        // If the whole text was punctuation, keep the original rather than returning nothing.
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : joined
    }

    private static func isClauseMark(_ c: Character, at i: Int, in chars: [Character]) -> Bool {
        if cjkMarks.contains(c) { return true }
        guard asciiMarks.contains(c) else { return false }
        let previous = i > 0 ? chars[i - 1] : nil
        let next = i + 1 < chars.count ? chars[i + 1] : nil
        // Inside a token (3.14, 10:30, 1,000, example.com, v1.2, a.m.) it is not punctuation.
        if let previous, let next, isTokenCharacter(previous), isTokenCharacter(next) { return false }
        // A leading mark (".env", ":)") is part of a token as well.
        if previous == nil || previous == " " { return next == nil || next == " " }
        return true
    }

    private static func isTokenCharacter(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        return c.isLetter || c.isNumber || c == "/" || c == "@" || c == "_" || c == "-"
    }
}
