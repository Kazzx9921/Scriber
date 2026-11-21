import Foundation

/// Punctuation and spacing cleanup for mixed Chinese/English text. See `ZhTW.normalize`.
///
/// Steps, each designed so that a second run changes nothing:
/// 1. Collapse runs of spaces/tabs, trim every line and the whole text.
/// 2. Find URLs and emails; nothing inside them is touched.
/// 3. Turn `, . ? ! : ; ( )` into `，。？！：；（）` where they belong to Chinese text (rules below).
/// 4. Drop spaces next to full-width punctuation.
/// 5. Insert (or remove) one space between CJK and Latin letters/digits.
///
/// Neighbors are looked up skipping spaces, so the spacing steps never change a punctuation decision.
enum ZhTWNormalizer {
    static func normalize(_ text: String, spaceBetweenCJKAndLatin: Bool) -> String {
        var s = collapseWhitespace(Array(text.unicodeScalars))
        let protected = protectedMask(s)
        // Conversions only go half-width → full-width, and one can enable another
        // ("(API),我" → the comma first, then the parentheses), so repeat until nothing changes.
        for _ in 0..<8 {
            let parentheses = convertParentheses(&s, protected)
            let others = convertPunctuation(&s, protected)
            if !parentheses && !others { break }
        }
        s = removeSpacesNextToFullWidthPunctuation(s)
        s = spaceBetweenCJKAndLatin ? insertCJKLatinSpaces(s) : removeCJKLatinSpaces(s)
        s = collapseWhitespace(s)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s)
        let result = String(view)
        return result == text ? text : result
    }

    // MARK: - Character classes

    /// Han ideographs, kana, bopomofo and Hangul syllables (letters, not punctuation).
    static func isCJKLetter(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x2E80...0x2FDF, 0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303B,
             0x3040...0x309F, 0x30A1...0x30FA, 0x30FC...0x30FF, 0x3100...0x312F, 0x31A0...0x31BF, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    /// Full-width / CJK punctuation such as ，。、；：？！（）「」『』《》【】.
    static func isFullWidthPunctuation(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x3001...0x3004, 0x3008...0x3020, 0x3030, 0x303D, 0x30FB,
             0xFE10...0xFE19, 0xFE30...0xFE4F,
             0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65:
            return true
        default:
            return false
        }
    }

    /// A neighbor that makes ASCII punctuation part of Chinese text.
    static func isCJKContext(_ c: Unicode.Scalar?) -> Bool {
        guard let c else { return false }
        return isCJKLetter(c) || isFullWidthPunctuation(c)
    }

    static func isLatinAlphanumeric(_ c: Unicode.Scalar?) -> Bool {
        guard let c else { return false }
        switch c.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0xC0...0x24F: return c.value != 0xD7 && c.value != 0xF7 // Latin-1 / Extended-A/B letters
        case 0x370...0x3FF, 0x400...0x4FF: return c.properties.isAlphabetic // Greek, Cyrillic
        default: return false
        }
    }

    static func isASCIIDigit(_ c: Unicode.Scalar?) -> Bool {
        guard let c else { return false }
        return c.value >= 0x30 && c.value <= 0x39
    }

    /// Can sit right before CJK as the end of a Latin token: letters, digits, `%`, closing brackets.
    static func isLatinTokenEnd(_ c: Unicode.Scalar) -> Bool {
        isLatinAlphanumeric(c) || "%)]}°".unicodeScalars.contains(c)
    }

    /// Can sit right after CJK as the start of a Latin token: letters, digits, `$ # @`, opening brackets.
    static func isLatinTokenStart(_ c: Unicode.Scalar) -> Bool {
        isLatinAlphanumeric(c) || "$#@([{".unicodeScalars.contains(c)
    }

    static func isHorizontalSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }
    static func isLineBreak(_ c: Unicode.Scalar) -> Bool { c == "\n" || c == "\r" }

    // MARK: - Step 1: whitespace

    /// Collapses runs of spaces/tabs into one space, trims each line, trims the whole text.
    static func collapseWhitespace(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        var pendingSpace = false
        for c in s {
            if isHorizontalSpace(c) {
                pendingSpace = true
                continue
            }
            if isLineBreak(c) {
                while let last = out.last, isHorizontalSpace(last) { out.removeLast() }
                out.append(c)
                pendingSpace = false
                continue
            }
            if pendingSpace, let last = out.last, !isLineBreak(last) { out.append(" ") }
            pendingSpace = false
            out.append(c)
        }
        // Trim leading and trailing whitespace of the whole text.
        var start = 0, end = out.count
        while start < end, isHorizontalSpace(out[start]) || isLineBreak(out[start]) { start += 1 }
        while end > start, isHorizontalSpace(out[end - 1]) || isLineBreak(out[end - 1]) { end -= 1 }
        return Array(out[start..<end])
    }

    // MARK: - Step 2: URLs and emails

    /// Marks URLs (`scheme://…`, `www.…`) and email addresses. A span stops at whitespace, CJK or
    /// full-width punctuation, and gives up trailing sentence punctuation.
    static func protectedMask(_ s: [Unicode.Scalar]) -> [Bool] {
        var mask = [Bool](repeating: false, count: s.count)
        func isSpanChar(_ c: Unicode.Scalar) -> Bool {
            !(isHorizontalSpace(c) || isLineBreak(c) || isCJKLetter(c) || isFullWidthPunctuation(c))
        }
        func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
            (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A)
        }
        func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
            (c.value >= 0x41 && c.value <= 0x5A) ? Unicode.Scalar(c.value + 32)! : c
        }
        func hasPrefix(_ p: String, at i: Int) -> Bool {
            let p = Array(p.unicodeScalars)
            guard i + p.count <= s.count else { return false }
            for k in 0..<p.count where lower(s[i + k]) != p[k] { return false }
            return true
        }
        func mark(_ from: Int, _ to: Int) {
            var end = to
            // Trailing punctuation belongs to the sentence, not the URL. Keep a ")" that closes a "(" in the span.
            while end > from, ".,;:!?'\"".unicodeScalars.contains(s[end - 1])
                    || (s[end - 1] == ")" && s[from..<end].filter { $0 == "(" }.count < s[from..<end].filter { $0 == ")" }.count) {
                end -= 1
            }
            for k in from..<end { mask[k] = true }
        }

        var i = 0
        while i < s.count {
            let atWordStart = i == 0 || !isLatinAlphanumeric(s[i - 1])
            // scheme://
            if atWordStart, isASCIILetter(s[i]) {
                var j = i
                while j < s.count, isLatinAlphanumeric(s[j]) || "+.-".unicodeScalars.contains(s[j]) { j += 1 }
                if j + 2 < s.count, s[j] == ":", s[j + 1] == "/", s[j + 2] == "/" {
                    var k = j + 3
                    while k < s.count, isSpanChar(s[k]) { k += 1 }
                    mark(i, k)
                    i = k
                    continue
                }
                if hasPrefix("www.", at: i) {
                    var k = i + 4
                    while k < s.count, isSpanChar(s[k]) { k += 1 }
                    mark(i, k)
                    i = k
                    continue
                }
            }
            // local@domain.tld
            if s[i] == "@", i > 0 {
                func isLocal(_ c: Unicode.Scalar) -> Bool {
                    (c.isASCII && isLatinAlphanumeric(c)) || "._%+-".unicodeScalars.contains(c)
                }
                func isDomain(_ c: Unicode.Scalar) -> Bool { (c.isASCII && isLatinAlphanumeric(c)) || c == "." || c == "-" }
                var a = i
                while a > 0, isLocal(s[a - 1]) { a -= 1 }
                var b = i + 1
                while b < s.count, isDomain(s[b]) { b += 1 }
                while b > i + 1, s[b - 1] == "." || s[b - 1] == "-" { b -= 1 }
                if a < i, b > i + 1, s[(i + 1)..<b].contains(".") {
                    for k in a..<b { mask[k] = true }
                    i = b
                    continue
                }
            }
            i += 1
        }
        return mask
    }

    // MARK: - Step 3: punctuation

    private static func previousNonSpace(_ s: [Unicode.Scalar], before i: Int) -> Unicode.Scalar? {
        var j = i - 1
        while j >= 0 {
            if isLineBreak(s[j]) { return nil }
            if !isHorizontalSpace(s[j]) { return s[j] }
            j -= 1
        }
        return nil
    }

    private static func nextNonSpace(_ s: [Unicode.Scalar], after i: Int) -> Unicode.Scalar? {
        var j = i + 1
        while j < s.count {
            if isLineBreak(s[j]) { return nil }
            if !isHorizontalSpace(s[j]) { return s[j] }
            j += 1
        }
        return nil
    }

    /// True if the sentence that ends at `i` contains CJK: scans back to the line start or the
    /// previous full-width sentence end.
    private static func sentenceHasCJK(_ s: [Unicode.Scalar], before i: Int) -> Bool {
        var j = i - 1
        while j >= 0 {
            let c = s[j]
            if isLineBreak(c) || c == "。" || c == "？" || c == "！" { return false }
            if isCJKLetter(c) { return true }
            j -= 1
        }
        return false
    }

    private static let fullWidth: [Unicode.Scalar: Unicode.Scalar] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；", "(": "（", ")": "）",
    ]

    /// Parentheses go full-width as a pair when the content has CJK, or the pair is attached to CJK
    /// outside. `foo(bar)` and `Claude(Anthropic)的` stay half-width: a Latin word right before "("
    /// with Latin-only content reads as code or an English aside.
    @discardableResult
    static func convertParentheses(_ s: inout [Unicode.Scalar], _ protected: [Bool]) -> Bool {
        var stack: [Int] = []
        var pairs: [(Int, Int)] = []
        var unpaired: [Int] = []
        for i in s.indices where !protected[i] {
            if isLineBreak(s[i]) {
                unpaired += stack
                stack.removeAll()
            } else if s[i] == "(" {
                stack.append(i)
            } else if s[i] == ")" {
                if let open = stack.popLast() { pairs.append((open, i)) } else { unpaired.append(i) }
            }
        }
        unpaired += stack
        var convert = Set<Int>()
        for (open, close) in pairs {
            let before = previousNonSpace(s, before: open)
            let after = nextNonSpace(s, after: close)
            let contentHasCJK = s[(open + 1)..<close].contains(where: isCJKLetter)
            if contentHasCJK || isCJKContext(before) || (isCJKContext(after) && !isLatinAlphanumeric(before)) {
                convert.insert(open)
                convert.insert(close)
            }
        }
        for i in unpaired where isCJKContext(previousNonSpace(s, before: i)) || isCJKContext(nextNonSpace(s, after: i)) {
            convert.insert(i)
        }
        for i in convert { s[i] = fullWidth[s[i]]! }
        return !convert.isEmpty
    }

    /// One left-to-right pass over `, . ? ! : ;`. Returns true if anything changed.
    @discardableResult
    static func convertPunctuation(_ s: inout [Unicode.Scalar], _ protected: [Bool]) -> Bool {
        var changed = false
        for i in s.indices where !protected[i] {
            let c = s[i]
            guard c == "," || c == "." || c == "?" || c == "!" || c == ":" || c == ";" else { continue }
            let rawBefore: Unicode.Scalar? = i > 0 ? s[i - 1] : nil
            let rawAfter: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
            // 3.14, 10:30, 1,299
            if isASCIIDigit(rawBefore) && isASCIIDigit(rawAfter) { continue }
            let before = previousNonSpace(s, before: i)
            let after = nextNonSpace(s, after: i)
            let convert: Bool
            switch c {
            case ".":
                // Ellipses ("...", "..") stay as they are.
                if rawBefore == "." || rawAfter == "." { continue }
                convert = isCJKContext(before) || endsChineseSentence(s, i, after)
            case "?", "!":
                convert = isCJKContext(before) || endsChineseSentence(s, i, after)
            case ":":
                if rawAfter == "/" { continue }
                convert = isCJKContext(before) || isCJKContext(after)
            default: // , ;
                convert = isCJKContext(before) || isCJKContext(after)
            }
            if convert {
                s[i] = fullWidth[c]!
                changed = true
            }
        }
        return changed
    }

    /// `我用 Claude Code.` → the period ends a Chinese sentence: it is followed by the line end or
    /// by CJK, and the sentence it closes contains CJK. `Mr. Smith`, `Node.js`, `v2.3.1` do not qualify.
    private static func endsChineseSentence(_ s: [Unicode.Scalar], _ i: Int, _ after: Unicode.Scalar?) -> Bool {
        (after == nil || isCJKContext(after)) && sentenceHasCJK(s, before: i)
    }

    // MARK: - Steps 4 and 5: spacing

    static func removeSpacesNextToFullWidthPunctuation(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        for (i, c) in s.enumerated() {
            if isHorizontalSpace(c) {
                let before = out.last
                let after: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
                if (before.map(isFullWidthPunctuation) ?? false) || (after.map(isFullWidthPunctuation) ?? false) { continue }
            }
            out.append(c)
        }
        return out
    }

    static func insertCJKLatinSpaces(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count + s.count / 8)
        for c in s {
            if let last = out.last,
               (isCJKLetter(last) && isLatinTokenStart(c)) || (isLatinTokenEnd(last) && isCJKLetter(c)) {
                out.append(" ")
            }
            out.append(c)
        }
        return out
    }

    static func removeCJKLatinSpaces(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        for (i, c) in s.enumerated() {
            if isHorizontalSpace(c), let before = out.last, i + 1 < s.count {
                let after = s[i + 1]
                if (isCJKLetter(before) && isLatinTokenStart(after)) || (isLatinTokenEnd(before) && isCJKLetter(after)) {
                    continue
                }
            }
            out.append(c)
        }
        return out
    }
}
