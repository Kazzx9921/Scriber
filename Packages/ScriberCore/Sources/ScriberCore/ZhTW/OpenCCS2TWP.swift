import Foundation

/// Pure-Swift reimplementation of OpenCC 1.4.2 `s2twp.json` over the bundled OpenCC dictionaries.
///
/// s2twp.json, and how each part maps here:
/// ```
/// normalization:    CJK_Compatibility_Ideographs                        -> `normalize`
/// segmentation:     mmseg over union(STPhrases, STPhrases_Generated...) -> `segment`
/// conversion_chain: per segment, in order                               -> `convertSegment`
///   1. short_circuit[ union(STPhrases, STPhrases_Generated...), STCharacters ]
///   2. short_circuit[ TWPhrases, TWVariantsPhrases, TWVariants ]
/// ```
/// OpenCC semantics reproduced: every dictionary does longest-prefix matching and emits its first
/// value; `union` takes the longest match among its members (ties go to the earlier member);
/// `short_circuit` takes the first member that matches at all; conversion never crosses a segment
/// boundary; unmatched scalars pass through unchanged.
/// Not reproduced: OpenCC keeps a whole Ideographic Description Sequence (U+2FF0…) unconverted
/// when no key matches it. Here those scalars are converted one by one like any other text, so a
/// Simplified character inside an IDS is still converted.
final class OpenCCS2TWP: @unchecked Sendable {
    let compatibility: OpenCCDictionary
    let stPhrases: OpenCCDictionary
    let stPhrasesGenerated: OpenCCDictionary
    let stCharacters: OpenCCDictionary
    let twPhrases: OpenCCDictionary
    let twVariantsPhrases: OpenCCDictionary
    let twVariants: OpenCCDictionary
    /// Not part of s2twp; only used to find characters that exist only in Traditional Chinese.
    let tsCharacters: OpenCCDictionary

    /// Scalars that only exist in Simplified Chinese (see `ZhTW.containsSimplified`).
    let simplifiedOnly: ScalarBitSet
    /// Scalars that only exist in Traditional Chinese: TSCharacters keys that do not map to themselves.
    let traditionalOnly: ScalarBitSet

    /// STCharacters' default mapping for single characters (发 → 發, 后 → 後). Used to compare text
    /// regardless of script, e.g. for personal-dictionary matching; not a conversion by itself.
    let characterFold: [UInt32: UInt32]

    /// Time spent reading and indexing the dictionaries, for diagnostics.
    let loadMillis: Double

    static let resourceSubdirectory = "Resources/OpenCC"

    static let shared: OpenCCS2TWP = {
        do {
            return try OpenCCS2TWP(bundle: .module)
        } catch {
            // The data is bundled with the package; failing here is a build/packaging error.
            fatalError("ScriberCore: cannot load OpenCC dictionaries: \(error)")
        }
    }()

    struct MissingResource: Error, CustomStringConvertible {
        var name: String
        var description: String { "missing \(OpenCCS2TWP.resourceSubdirectory)/\(name).txt" }
    }

    init(bundle: Bundle) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        func load(_ name: String, selfListed: Bool = false) throws -> OpenCCDictionary {
            guard let url = bundle.url(forResource: name, withExtension: "txt", subdirectory: Self.resourceSubdirectory)
                ?? bundle.url(forResource: name, withExtension: "txt") else {
                throw MissingResource(name: name)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return OpenCCDictionary(data: data, collectSelfListedKeys: selfListed)
        }
        compatibility = try load("CJK_Compatibility_Ideographs")
        stPhrases = try load("STPhrases")
        stPhrasesGenerated = try load("STPhrases_GeneratedFromRegionalPhrases")
        stCharacters = try load("STCharacters", selfListed: true)
        twPhrases = try load("TWPhrases")
        twVariantsPhrases = try load("TWVariantsPhrases")
        twVariants = try load("TWVariants")
        tsCharacters = try load("TSCharacters", selfListed: true)

        // Simplified-only: an STCharacters key that is not among its own candidates, is not a
        // Traditional character with a Simplified form of its own (a TSCharacters key), and is never
        // emitted by s2twp (not the default value of any entry in the chain). The last rule keeps
        // Taiwan-standard forms that Simplified shares, such as 群 秘 床 峰 恒, out of the set, and
        // guarantees that s2twp output never tests positive.
        var simplified = ScalarBitSet()
        let stCharacters = self.stCharacters
        let tsCharacters = self.tsCharacters
        stCharacters.forEachEntry { key, _ in
            guard key.count == 1, !stCharacters.selfListedKeys.contains(key[0]) else { return }
            simplified.insert(key[0])
        }
        tsCharacters.forEachEntry { key, _ in
            if key.count == 1 { simplified.remove(key[0]) }
        }
        for dict in [stPhrases, stPhrasesGenerated, stCharacters, twPhrases, twVariantsPhrases, twVariants] {
            dict.forEachEntry { _, value in
                for s in value { simplified.remove(s) }
            }
        }
        simplifiedOnly = simplified

        var traditional = ScalarBitSet()
        tsCharacters.forEachEntry { key, _ in
            guard key.count == 1, !tsCharacters.selfListedKeys.contains(key[0]) else { return }
            traditional.insert(key[0])
        }
        traditionalOnly = traditional

        var fold: [UInt32: UInt32] = [:]
        fold.reserveCapacity(stCharacters.count)
        stCharacters.forEachEntry { key, value in
            if key.count == 1, value.count == 1, key[0] != value[0] { fold[key[0]] = value[0] }
        }
        characterFold = fold

        loadMillis = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    // MARK: - Exact s2twp

    /// Converts `input[range]` exactly like `opencc -c s2twp` and appends the result.
    func convertExact(_ input: UnsafeBufferPointer<UInt32>, _ range: Range<Int>, into output: inout [UInt32]) {
        let normalized = normalize(input, range)
        normalized.withUnsafeBufferPointer { text in
            for segment in segment(text) {
                convertSegment(text, segment.range, into: &output)
            }
        }
    }

    /// Repairs Traditional text that has a few Simplified-only characters, without reinterpreting
    /// the correct Traditional words around them (plain s2twp would turn 這份文件的内容 into 這份檔案的內容).
    /// Uses s2twp's segmentation:
    /// - a matched phrase containing a Simplified-only character is converted like s2twp does;
    /// - in unmatched runs, only Simplified-only characters are converted (STCharacters), and the
    ///   Taiwan phrase/variant step is applied only where its match covers one of them;
    /// - everything else is copied from the input unchanged.
    func convertSimplifiedSegments(_ input: UnsafeBufferPointer<UInt32>, _ range: Range<Int>,
                                   into output: inout [UInt32]) {
        let normalized = normalize(input, range)
        // Normalization maps one scalar to one scalar, so ranges line up with the input.
        let base = range.lowerBound
        normalized.withUnsafeBufferPointer { text in
            for segment in segment(text) {
                let r = segment.range
                if !text[r].contains(where: simplifiedOnly.contains) {
                    output.append(contentsOf: input[(base + r.lowerBound)..<(base + r.upperBound)])
                } else if segment.isPhrase {
                    convertSegment(text, r, into: &output)
                } else {
                    repairRun(text, r, original: UnsafeBufferPointer(rebasing: input[(base + r.lowerBound)..<(base + r.upperBound)]),
                              into: &output)
                }
            }
        }
    }

    private func repairRun(_ text: UnsafeBufferPointer<UInt32>, _ run: Range<Int>,
                           original: UnsafeBufferPointer<UInt32>, into output: inout [UInt32]) {
        var step1: [UInt32] = []
        var converted: [Bool] = []
        step1.reserveCapacity(run.count)
        converted.reserveCapacity(run.count)
        for (offset, i) in run.enumerated() {
            let before = step1.count
            if simplifiedOnly.contains(text[i]), let m = stCharacters.longestMatch(in: text, from: i, to: i + 1) {
                stCharacters.appendValue(of: m.entry, to: &step1)
            }
            if step1.count == before + 1 {
                converted.append(true)
            } else {
                // STCharacters values are single scalars; anything else is left unconverted.
                step1.removeSubrange(before...)
                step1.append(original[offset])
                converted.append(false)
            }
        }
        step1.withUnsafeBufferPointer { s in
            var j = 0
            while j < s.count {
                var match: (dict: OpenCCDictionary, m: OpenCCDictionary.Match)?
                for dict in [twPhrases, twVariantsPhrases, twVariants] {
                    if let m = dict.longestMatch(in: s, from: j, to: s.count) { match = (dict, m); break }
                }
                if let match, converted[j..<(j + match.m.length)].contains(true) {
                    match.dict.appendValue(of: match.m.entry, to: &output)
                    j += match.m.length
                } else {
                    output.append(s[j])
                    j += 1
                }
            }
        }
    }

    /// normalization: CJK compatibility ideographs → unified ideographs (one scalar each).
    private func normalize(_ input: UnsafeBufferPointer<UInt32>, _ range: Range<Int>) -> [UInt32] {
        var normalized: [UInt32] = []
        normalized.reserveCapacity(range.count)
        var i = range.lowerBound
        while i < range.upperBound {
            if let m = compatibility.longestMatch(in: input, from: i, to: range.upperBound) {
                compatibility.appendValue(of: m.entry, to: &normalized)
                i += m.length
            } else {
                normalized.append(input[i])
                i += 1
            }
        }
        return normalized
    }

    /// mmseg: greedy longest match with union(STPhrases, STPhrases_Generated...) over the whole text.
    /// Matched keys become their own segments; runs of unmatched scalars are merged into one segment.
    private func segment(_ text: UnsafeBufferPointer<UInt32>) -> [(range: Range<Int>, isPhrase: Bool)] {
        var segments: [(range: Range<Int>, isPhrase: Bool)] = []
        var runStart = 0
        var i = 0
        let end = text.count
        while i < end {
            if let m = unionPhraseMatch(text, i, end) {
                if runStart < i { segments.append((runStart..<i, false)) }
                segments.append((i..<(i + m.length), true))
                i += m.length
                runStart = i
            } else {
                i += 1
            }
        }
        if runStart < end { segments.append((runStart..<end, false)) }
        return segments
    }

    @inline(__always)
    private func unionPhraseMatch(_ text: UnsafeBufferPointer<UInt32>, _ i: Int, _ end: Int)
        -> (dict: OpenCCDictionary, length: Int, entry: Int)? {
        let a = stPhrases.longestMatch(in: text, from: i, to: end)
        let b = stPhrasesGenerated.longestMatch(in: text, from: i, to: end)
        switch (a, b) {
        case let (a?, b?): return b.length > a.length ? (stPhrasesGenerated, b.length, b.entry) : (stPhrases, a.length, a.entry)
        case let (a?, nil): return (stPhrases, a.length, a.entry)
        case let (nil, b?): return (stPhrasesGenerated, b.length, b.entry)
        case (nil, nil): return nil
        }
    }

    /// Runs both conversion steps on one segment. Matching never looks past the segment's end.
    private func convertSegment(_ text: UnsafeBufferPointer<UInt32>, _ segment: Range<Int>,
                                into output: inout [UInt32]) {
        // Step 1: short_circuit[ union(STPhrases, Generated), STCharacters ].
        var step1: [UInt32] = []
        step1.reserveCapacity(segment.count + 4)
        var i = segment.lowerBound
        while i < segment.upperBound {
            if let m = unionPhraseMatch(text, i, segment.upperBound) {
                m.dict.appendValue(of: m.entry, to: &step1)
                i += m.length
            } else if let m = stCharacters.longestMatch(in: text, from: i, to: segment.upperBound) {
                stCharacters.appendValue(of: m.entry, to: &step1)
                i += m.length
            } else {
                step1.append(text[i])
                i += 1
            }
        }

        // Step 2: short_circuit[ TWPhrases, TWVariantsPhrases, TWVariants ] on step 1's output.
        step1.withUnsafeBufferPointer { s in
            var j = 0
            while j < s.count {
                if let m = twPhrases.longestMatch(in: s, from: j, to: s.count) {
                    twPhrases.appendValue(of: m.entry, to: &output)
                    j += m.length
                } else if let m = twVariantsPhrases.longestMatch(in: s, from: j, to: s.count) {
                    twVariantsPhrases.appendValue(of: m.entry, to: &output)
                    j += m.length
                } else if let m = twVariants.longestMatch(in: s, from: j, to: s.count) {
                    twVariants.appendValue(of: m.entry, to: &output)
                    j += m.length
                } else {
                    output.append(s[j])
                    j += 1
                }
            }
        }
    }

    // MARK: - Script-aware conversion

    /// How one sentence is treated by `convertScriptAware`.
    enum SentencePlan: Equatable {
        /// Traditional (or neutral text inside a Traditional document): copied unchanged.
        case keep
        /// Simplified, Simplified-dominant, or neutral: exact s2twp.
        case exact
        /// Traditional with a few Simplified characters: only segments containing them are converted.
        case repairSimplifiedSegments
    }

    /// Sentence boundaries. No OpenCC key or value contains these, so splitting here cannot change
    /// what s2twp does.
    @inline(__always)
    static func isSentenceBoundary(_ c: UInt32) -> Bool {
        switch c {
        case 0x0A, 0x0D, 0x21, 0x3F, 0x3B, 0x3002, 0xFF01, 0xFF1F, 0xFF1B: return true // \n \r ! ? ; 。！？；
        default: return false
        }
    }

    /// Converts Simplified to Traditional (Taiwan) without reinterpreting text that is already Traditional.
    ///
    /// The text is split into sentences. A sentence containing Traditional-only characters and no
    /// Simplified-only ones is kept as is. One with Simplified-only characters and no more
    /// Traditional-only than Simplified-only characters gets exact s2twp. One with more
    /// Traditional-only characters only has the segments holding Simplified-only characters
    /// converted. A sentence with neither kind follows the whole document: kept if the document has
    /// more Traditional-only characters than Simplified-only ones, exact s2twp otherwise.
    ///
    /// The output never contains a Simplified-only character. A second pass changes nothing: every
    /// sentence then has no Simplified-only characters, so it is either kept, or it is script-neutral
    /// and was already settled to an s2twp fixed point (see `settle`).
    func convertScriptAware(_ text: String) -> String {
        let scalars = text.unicodeScalars.map(\.value)
        var output: [UInt32] = []
        output.reserveCapacity(scalars.count + scalars.count / 8)
        var changed = false
        scalars.withUnsafeBufferPointer { input in
            var sentences: [(range: Range<Int>, simplified: Int, traditional: Int)] = []
            var documentSimplified = 0, documentTraditional = 0
            var start = 0, simplified = 0, traditional = 0
            for i in 0..<input.count {
                let c = input[i]
                if simplifiedOnly.contains(c) { simplified += 1 } else if traditionalOnly.contains(c) { traditional += 1 }
                if Self.isSentenceBoundary(c) || i == input.count - 1 {
                    sentences.append((start..<(i + 1), simplified, traditional))
                    documentSimplified += simplified
                    documentTraditional += traditional
                    start = i + 1
                    simplified = 0
                    traditional = 0
                }
            }
            let documentIsTraditional = documentTraditional > documentSimplified
            for sentence in sentences {
                let plan = Self.plan(simplified: sentence.simplified, traditional: sentence.traditional,
                                     documentIsTraditional: documentIsTraditional)
                let before = output.count
                switch plan {
                case .keep:
                    output.append(contentsOf: input[sentence.range])
                case .exact:
                    convertExact(input, sentence.range, into: &output)
                case .repairSimplifiedSegments:
                    convertSimplifiedSegments(input, sentence.range, into: &output)
                }
                if plan != .keep { settle(&output, from: before) }
                if !changed && !output[before...].elementsEqual(input[sentence.range]) { changed = true }
            }
        }
        return changed ? Self.makeString(output) : text
    }

    /// A converted sentence with no Traditional-only character would be converted again on a second
    /// pass, and s2twp is not idempotent on its own output (三征七辟 → 三徵七辟 → 三徵七闢, 伙夫 → 伙伕 → 夥伕).
    /// Re-apply s2twp until the sentence is stable or gains a Traditional-only character (then a
    /// second pass keeps it). Only rare, script-neutral text ever takes more than one round.
    private func settle(_ output: inout [UInt32], from start: Int) {
        guard !output[start...].contains(where: traditionalOnly.contains) else { return }
        var current = Array(output[start...])
        for _ in 0..<8 {
            var next: [UInt32] = []
            next.reserveCapacity(current.count + 4)
            current.withUnsafeBufferPointer { convertExact($0, 0..<$0.count, into: &next) }
            if next == current { break }
            current = next
            if current.contains(where: traditionalOnly.contains) { break }
        }
        output.removeSubrange(start...)
        output.append(contentsOf: current)
    }

    static func plan(simplified: Int, traditional: Int, documentIsTraditional: Bool) -> SentencePlan {
        if simplified == 0 {
            if traditional > 0 { return .keep }
            return documentIsTraditional ? .keep : .exact
        }
        return traditional > simplified ? .repairSimplifiedSegments : .exact
    }

    func containsSimplified(_ text: String) -> Bool {
        text.unicodeScalars.contains { simplifiedOnly.contains($0.value) }
    }

    func exactString(_ text: String) -> String {
        let scalars = text.unicodeScalars.map(\.value)
        var output: [UInt32] = []
        output.reserveCapacity(scalars.count + scalars.count / 8)
        scalars.withUnsafeBufferPointer { convertExact($0, 0..<$0.count, into: &output) }
        return Self.makeString(output)
    }

    static func makeString(_ scalars: [UInt32]) -> String {
        var view = String.UnicodeScalarView()
        for s in scalars {
            if let scalar = Unicode.Scalar(s) { view.append(scalar) }
        }
        return String(view)
    }
}
