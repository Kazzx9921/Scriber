import Foundation

/// Applies personal-dictionary `soundsLike → term` replacements in one left-to-right pass.
///
/// - Longest pattern first at each position; replaced text is never scanned again.
/// - Latin letters compare case-insensitively. A pattern that starts (ends) with a Latin letter or
///   digit only matches at a word start (end), so "pr" never fires inside "prompt".
/// - CJK compares as plain substrings, and regardless of script: both sides are folded through
///   OpenCC's STCharacters, so an entry written as 克勞德 also catches 克劳德 from Whisper.
/// - A space in a pattern matches one or more spaces in the text, or none next to CJK
///   ("克勞德 code" matches "克勞德code").
struct DictionaryReplacer {
    private enum Token: Equatable {
        case scalar(UInt32)
        /// `optional` when a CJK character is on either side.
        case space(optional: Bool)
    }

    private struct Pattern {
        var tokens: [Token]
        var replacement: String
        var needsWordStart: Bool
        var needsWordEnd: Bool
        var length: Int
    }

    private let patternsByFirstScalar: [UInt32: [Pattern]]
    private let fold: [UInt32: UInt32]

    init(entries: [DictionaryEntry]) {
        let terms = entries.map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
        let needsScriptFold = zip(entries, terms).contains { entry, term in
            !term.isEmpty && entry.soundsLike.contains { $0.unicodeScalars.contains { !$0.isASCII } }
        }
        fold = needsScriptFold ? OpenCCS2TWP.shared.characterFold : [:]

        var all: [Pattern] = []
        for (entry, term) in zip(entries, terms) where !term.isEmpty {
            for raw in entry.soundsLike {
                let spoken = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !spoken.isEmpty else { continue }
                let scalars = Array(spoken.unicodeScalars)
                var tokens: [Token] = []
                for (i, c) in scalars.enumerated() {
                    if Self.isSpace(c.value) {
                        if case .space = tokens.last { continue }
                        let left = scalars[..<i].last { !Self.isSpace($0.value) }
                        let right = scalars[(i + 1)...].first { !Self.isSpace($0.value) }
                        let optional = left.map { Self.isCJK($0.value) } == true || right.map { Self.isCJK($0.value) } == true
                        tokens.append(.space(optional: optional))
                    } else {
                        tokens.append(.scalar(Self.fold(c.value, fold)))
                    }
                }
                guard case .scalar? = tokens.first else { continue }
                all.append(Pattern(tokens: tokens, replacement: term,
                                   needsWordStart: Self.isWordScalar(scalars.first!.value),
                                   needsWordEnd: Self.isWordScalar(scalars.last!.value),
                                   length: tokens.count))
            }
        }
        // Longest first; equal lengths keep dictionary order.
        let ordered = all.enumerated().sorted { a, b in
            a.element.length != b.element.length ? a.element.length > b.element.length : a.offset < b.offset
        }.map(\.element)
        var byFirst: [UInt32: [Pattern]] = [:]
        for pattern in ordered {
            guard case .scalar(let first) = pattern.tokens[0] else { continue }
            byFirst[first, default: []].append(pattern)
        }
        patternsByFirstScalar = byFirst
    }

    var isEmpty: Bool { patternsByFirstScalar.isEmpty }

    func apply(to text: String) -> String {
        guard !patternsByFirstScalar.isEmpty else { return text }
        let scalars = Array(text.unicodeScalars)
        let folded = scalars.map { Self.fold($0.value, fold) }
        var output = String.UnicodeScalarView()
        var changed = false
        var i = 0
        var copiedUpTo = 0
        while i < scalars.count {
            if let candidates = patternsByFirstScalar[folded[i]] {
                var replaced = false
                for pattern in candidates {
                    if pattern.needsWordStart, i > 0, Self.continuesWord(scalars[i - 1].value) { continue }
                    guard let end = match(pattern, folded, at: i) else { continue }
                    if pattern.needsWordEnd, end < scalars.count, Self.continuesWord(scalars[end].value) { continue }
                    output.append(contentsOf: scalars[copiedUpTo..<i])
                    output.append(contentsOf: pattern.replacement.unicodeScalars)
                    if !changed { changed = !scalars[i..<end].elementsEqual(pattern.replacement.unicodeScalars) }
                    i = end
                    copiedUpTo = end
                    replaced = true
                    break
                }
                if replaced { continue }
            }
            i += 1
        }
        guard changed else { return text }
        output.append(contentsOf: scalars[copiedUpTo...])
        return String(output)
    }

    /// End index of `pattern` matched at `start`, or nil.
    private func match(_ pattern: Pattern, _ text: [UInt32], at start: Int) -> Int? {
        var j = start
        for token in pattern.tokens {
            switch token {
            case .scalar(let c):
                guard j < text.count, text[j] == c else { return nil }
                j += 1
            case .space(let optional):
                var spaces = 0
                while j < text.count, Self.isSpace(text[j]) { j += 1; spaces += 1 }
                if spaces == 0 && !optional { return nil }
            }
        }
        return j
    }

    // MARK: - Character classes

    private static func fold(_ c: UInt32, _ map: [UInt32: UInt32]) -> UInt32 {
        if c < 0x80 { return (c >= 0x41 && c <= 0x5A) ? c + 32 : c }
        if let mapped = map[c] { return mapped }
        if let scalar = Unicode.Scalar(c), scalar.properties.changesWhenLowercased {
            let lower = scalar.properties.lowercaseMapping.unicodeScalars
            if lower.count == 1 { return lower.first!.value }
        }
        return c
    }

    static func isSpace(_ c: UInt32) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 || c == 0x3000 }

    /// Latin letters and digits: the characters a word boundary is about.
    static func isWordScalar(_ c: UInt32) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            || (c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7)
    }

    /// Characters that would make a match part of a longer Latin word.
    static func continuesWord(_ c: UInt32) -> Bool {
        isWordScalar(c) || c == 0x5F /* _ */ || (c >= 0x300 && c <= 0x36F) /* combining marks */
    }

    static func isCJK(_ c: UInt32) -> Bool {
        (c >= 0x3040 && c <= 0x30FF) || (c >= 0x3100 && c <= 0x312F) || (c >= 0x3400 && c <= 0x4DBF)
            || (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF) || (c >= 0xF900 && c <= 0xFAFF)
            || (c >= 0x20000 && c <= 0x3FFFF)
    }
}
