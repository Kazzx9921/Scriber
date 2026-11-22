import Foundation

/// Implementation of `RuleBasedCleanup.clean`.
///
/// Design rule: every step only fires on patterns that are almost never meaningful in written
/// zh-TW / English. Anything ambiguous (疊字 like 謝謝、看看, agreement like 對對對、好好好,
/// sentence-final particles like 好啊) is left alone. If cleanup would leave nothing but
/// punctuation, the original text is returned.
enum CleanupRules {

    static func clean(_ text: String) -> String {
        let original = normalizeWhitespace(text)
        guard !original.isEmpty else { return "" }

        var s = original
        s = removeLatinFillers(s)
        s = collapseStutters(s)
        s = replace(separatedStutter, in: s, with: "$1")
        s = replace(repeatedFillerWord, in: s, with: "$1")
        s = replace(restartedPhrase, in: s, with: "$1")
        s = replace(repeatedLatinWord, in: s, with: "$1")
        s = removeClauseStartFillers(s)
        s = tidyPunctuation(s)
        s = normalizeWhitespace(s)

        return hasContent(s) ? s : original
    }

    // MARK: Whitespace

    static func normalizeWhitespace(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = replace(horizontalSpace, in: s, with: " ")
        s = replace(spaceAroundNewline, in: s, with: "\n")
        s = replace(manyNewlines, in: s, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let horizontalSpace = regex("[ \\t\\u00A0\\u3000\\u2000-\\u200B]+")
    private static let spaceAroundNewline = regex(" ?\\n ?")
    private static let manyNewlines = regex("\\n{3,}")

    // MARK: Latin fillers (um, uh, erm) — anywhere, as whole words

    private static let latinFiller = regex(
        "[ \\t]*(?<![A-Za-z0-9'\\-])(?:um+|uh+|uhm+|erm+)(?![A-Za-z0-9'\\-])[ \\t]*(?:[,，][ \\t]*)?",
        options: [.caseInsensitive])

    static func removeLatinFillers(_ text: String) -> String {
        var s = text as NSString
        var guardCount = 0
        while guardCount < 64, let match = latinFiller.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length)) {
            guardCount += 1
            let left = match.range.location > 0 ? s.substring(with: NSRange(location: match.range.location - 1, length: 1)) : nil
            let end = match.range.location + match.range.length
            let right = end < s.length ? s.substring(with: NSRange(location: end, length: 1)) : nil
            s = s.replacingCharacters(in: match.range, with: latinFillerReplacement(left: left, right: right)) as NSString
        }
        return s as String
    }

    /// What goes where the filler was: nothing next to CJK, edges or punctuation; one space between words.
    private static func latinFillerReplacement(left: String?, right: String?) -> String {
        guard let left, let right else { return "" }
        if left == "\n" || right == "\n" { return "" }
        if isFullWidthPunctuation(left) || isPunctuation(right) { return "" }
        if isCJK(left) && isCJK(right) { return "" }
        return " "
    }

    // MARK: Single-character stutters (我我我 → 我)

    /// Pronouns and demonstratives whose doubling is never legitimate written Chinese.
    /// 在、要、會、想、是、好、對… are excluded on purpose: 現在在、需要要求、開會會、想想、是是是、好好.
    private static let stutterCharacters: Set<Character> = ["我", "你", "妳", "您", "他", "她", "它", "這", "这", "那", "就"]
    /// Words that end in a stutter character, so "其他他們" or "成就就是" are not stutters.
    private static let stutterBlockers: Set<String> = [
        "其他", "吉他", "其它", "迷你", "自我", "忘我", "唯我", "本我", "無我", "超我", "大我", "小我",
        "剎那", "刹那", "支那", "成就", "造就", "遷就", "將就", "屈就", "高就", "去就",
    ]

    static func collapseStutters(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var j = i
            while j < chars.count, chars[j] == c { j += 1 }
            let run = j - i
            guard run >= 2, stutterCharacters.contains(c) else {
                out.append(contentsOf: repeatElement(c, count: run))
                i = j
                continue
            }
            let blocked = out.last.map { stutterBlockers.contains(String([$0, c])) } ?? false
            // AABB reduplication (e.g. 的的確確) — never collapse a pair that sits next to another pair.
            let pairBefore = out.count >= 2 && out[out.count - 1] == out[out.count - 2]
            let pairAfter = j + 1 < chars.count && chars[j] == chars[j + 1]
            if run == 2, blocked || pairBefore || pairAfter {
                out.append(contentsOf: [c, c])
            } else {
                out.append(c)
                if blocked { out.append(c) } // 其他他他們 → 其他他們
            }
            i = j
        }
        return String(out)
    }

    /// "我，我，我覺得" → "我覺得". Needs three occurrences: "是我，我來" is legitimate.
    private static let separatedStutter = regex("([我你妳您他她它這这那])(?:[，,、…\\s]+\\1){2,}")

    // MARK: Repeated words and restarted phrases

    /// Function words and fillers that are only ever doubled by hesitation (那個那個、然後然後、就是就是).
    /// The doubled form collapses to one; content words like 謝謝你謝謝你 are untouched.
    private static let repeatedFillerWord = regex(
        "(那[個个]|[這这][個个]|就是|然[後后]|所以|因[為为]|但是|可是|不[過过]|而且|我[們们]|你[們们]|他[們们]|她[們们]|其[實实]|反正|如果|那[麼么])(?:[，,、…\\s]*\\1)+")

    /// A restart: the speaker repeats the first words of a clause ("我覺得我覺得", "我們明天我們明天").
    /// Only phrases that begin with a pronoun or connective and are at least 3 characters long,
    /// so short emphatic repeats (你看你看、我來我來、你好你好) stay.
    private static let restartedPhrase = regex(
        "((?:我[們们]|你[們们]|他[們们]|她[們们]|然[後后]|所以|因[為为]|但是|可是|如果|就是|那[個个]|[這这][個个]|其[實实])\\p{Han}{1,4}|[我你他她]\\p{Han}{2,4})(?:[，,、\\s]*\\1)+")

    /// "the the" → "the". Limited to words whose doubling is not grammatical
    /// ("that that", "had had", "is is", "log in in", "so so" are legitimate and excluded).
    private static let repeatedLatinWord = regex(
        "(?<![A-Za-z'\\-])(the|a|an|i|we|you|he|she|they|to|and|of|for|but|my|this|with|at)(?:\\s+\\1)+(?![A-Za-z'\\-])",
        options: [.caseInsensitive])

    // MARK: Clause-start fillers (嗯、呃、啊、欸)

    private static let clauseBoundary = "(?:^|(?<=[。！？!?；;：:，,、\\n]))[ \\t]*"

    /// Interjection at a clause start, followed by a pause, a space, or the clause itself.
    /// Not removed when it carries tone ("嗯？", "啊！") or starts another interjection ("嗯哼", "啊哈").
    private static let clauseStartInterjection = regex(
        clauseBoundary
            + "(?:嗯++|呃++|啊++|欸++|誒++|诶++|(?:额|額)(?=[，,、…\\s]))"
            + "(?:[，,、…]+[ \\t]*|[ \\t]+|(?![！？!?。．.～~哼哈呵嘿喔哦噢唷呀啦了]))")

    /// "那個，" used as a hesitation at a clause start, followed by more content.
    private static let clauseStartNage = regex(
        clauseBoundary + "那[個个][，,、…]+[ \\t]*(?=[^\\s，,、…。！？!?])")

    static func removeClauseStartFillers(_ text: String) -> String {
        var s = text
        for _ in 0..<4 { // "嗯，那個，我想問" needs more than one pass
            let next = replace(clauseStartNage, in: replace(clauseStartInterjection, in: s, with: ""), with: "")
            if next == s { break }
            s = next
        }
        return s
    }

    // MARK: Punctuation

    private static let spaceBeforeFullWidth = regex("[ \\t]+(?=[，。！？、；：」』）])")
    private static let spaceAfterFullWidth = regex("(?<=[，。！？、；：「『（])[ \\t]+")
    private static let repeatedFullWidthComma = regex("([，、；])(?:[ \\t]*[，、,；])+")
    private static let repeatedAsciiComma = regex(",(?:[ \\t]*,)+")
    private static let commaBeforeTerminal = regex("[，、,；;：:]+[ \\t]*([。！？!?])")
    private static let commaAfterTerminal = regex("([。！？])[ \\t]*[，、,；]+")
    private static let repeatedFullStop = regex("。(?:[ \\t]*[。.](?!\\.))+")
    private static let stopAfterMark = regex("([！？!?])[ \\t]*。")
    private static let leadingPunctuation = regex("(?m)^[ \\t]*[，,、。；：]+[ \\t]*")
    private static let trailingFullWidthComma = regex("(?m)[ \\t]*[，、；]+[ \\t]*$")
    private static let trailingCommaAfterCJK = regex("(?m)(?<=\\p{Han}),+[ \\t]*$")

    static func tidyPunctuation(_ text: String) -> String {
        var s = text
        s = replace(spaceBeforeFullWidth, in: s, with: "")
        s = replace(spaceAfterFullWidth, in: s, with: "")
        s = replace(repeatedFullWidthComma, in: s, with: "$1")
        s = replace(repeatedAsciiComma, in: s, with: ",")
        s = replace(commaBeforeTerminal, in: s, with: "$1")
        s = replace(commaAfterTerminal, in: s, with: "$1")
        s = replace(repeatedFullStop, in: s, with: "。")
        s = replace(stopAfterMark, in: s, with: "$1")
        s = replace(leadingPunctuation, in: s, with: "")
        s = replace(trailingFullWidthComma, in: s, with: "")
        s = replace(trailingCommaAfterCJK, in: s, with: "")
        return s
    }

    // MARK: Helpers

    static func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isCJK(_ s: String) -> Bool {
        guard let scalar = s.unicodeScalars.first else { return false }
        return (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
            || (0x20000...0x2FFFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value)
    }

    private static func isFullWidthPunctuation(_ s: String) -> Bool {
        "，。！？、；：「」『』（）…".contains(s)
    }

    private static func isPunctuation(_ s: String) -> Bool {
        isFullWidthPunctuation(s) || ",.!?;:)".contains(s)
    }

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programming error caught by tests.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
