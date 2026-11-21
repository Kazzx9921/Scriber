import Foundation

/// One OpenCC plain-text dictionary (`key<TAB>value[ value...]`), held as a flat, sorted pool of
/// Unicode scalars so lookups need no per-entry allocations.
///
/// Matching follows OpenCC's leaf dictionaries: the longest key that is a prefix of the input wins,
/// and the replacement is the entry's first (default) value.
final class OpenCCDictionary: @unchecked Sendable {
    // Entry i: key = pool[keyStart[i] ..< valueStart[i]], default value = pool[valueStart[i] ..< keyStart[i + 1]].
    // Immutable after init; the memory lives as long as the dictionary.
    private let pool: UnsafeMutableBufferPointer<UInt32>
    private let keyStart: UnsafeMutableBufferPointer<Int32>
    private let valueStart: UnsafeMutableBufferPointer<Int32>
    let count: Int
    let maxKeyLength: Int
    /// First scalar of every key, so most positions are rejected without a search.
    private let firstScalars: ScalarBitSet

    /// Single-scalar keys whose candidate list contains the key itself (e.g. 台 → 臺 檯 颱 台).
    /// Only collected when requested; used to tell variant-neutral characters from one-way ones.
    let selfListedKeys: Set<UInt32>

    struct Match {
        var length: Int
        var entry: Int
    }

    init(data: Data, collectSelfListedKeys: Bool = false) {
        var pool: [UInt32] = []
        var keyStart: [Int32] = []
        var valueStart: [Int32] = []
        var selfListed = Set<UInt32>()
        pool.reserveCapacity(data.count / 2)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = 0
            var lineKey: [UInt32] = []
            var candidate: [UInt32] = []
            while i < n {
                // Skip comment lines and blank lines.
                if bytes[i] == 0x23 /* # */ || bytes[i] == 0x0A || bytes[i] == 0x0D {
                    while i < n && bytes[i] != 0x0A { i += 1 }
                    i += 1
                    continue
                }
                lineKey.removeAll(keepingCapacity: true)
                while i < n && bytes[i] != 0x09 && bytes[i] != 0x0A && bytes[i] != 0x0D {
                    lineKey.append(Self.decodeScalar(bytes, &i))
                }
                guard i < n, bytes[i] == 0x09, !lineKey.isEmpty else {
                    // Malformed line: skip it.
                    while i < n && bytes[i] != 0x0A { i += 1 }
                    i += 1
                    continue
                }
                i += 1 // tab
                keyStart.append(Int32(pool.count))
                pool.append(contentsOf: lineKey)
                valueStart.append(Int32(pool.count))
                var isFirstValue = true
                var keyIsListed = false
                while i < n && bytes[i] != 0x0A && bytes[i] != 0x0D {
                    candidate.removeAll(keepingCapacity: true)
                    while i < n && bytes[i] != 0x20 && bytes[i] != 0x0A && bytes[i] != 0x0D {
                        candidate.append(Self.decodeScalar(bytes, &i))
                    }
                    if isFirstValue {
                        pool.append(contentsOf: candidate)
                        isFirstValue = false
                    }
                    if collectSelfListedKeys && candidate == lineKey { keyIsListed = true }
                    if i < n && bytes[i] == 0x20 { i += 1 }
                }
                if keyIsListed && lineKey.count == 1 { selfListed.insert(lineKey[0]) }
                while i < n && bytes[i] != 0x0A { i += 1 }
                i += 1
            }
        }
        keyStart.append(Int32(pool.count))

        // The bundled files are sorted by UTF-8 bytes, which is the same as scalar order.
        // Re-sort defensively if a replaced file is not, because matching relies on the order.
        if !Self.isSorted(pool: pool, keyStart: keyStart, valueStart: valueStart) {
            (pool, keyStart, valueStart) = Self.sorted(pool: pool, keyStart: keyStart, valueStart: valueStart)
        }

        var maxLen = 0
        var first = ScalarBitSet()
        for e in 0..<valueStart.count {
            maxLen = max(maxLen, Int(valueStart[e] - keyStart[e]))
            first.insert(pool[Int(keyStart[e])])
        }
        self.firstScalars = first

        self.count = valueStart.count
        self.maxKeyLength = maxLen
        self.selfListedKeys = selfListed
        self.pool = .allocate(capacity: max(pool.count, 1))
        _ = self.pool.initialize(from: pool)
        self.keyStart = .allocate(capacity: keyStart.count)
        _ = self.keyStart.initialize(from: keyStart)
        self.valueStart = .allocate(capacity: max(valueStart.count, 1))
        _ = self.valueStart.initialize(from: valueStart)
    }

    deinit {
        pool.deallocate()
        keyStart.deallocate()
        valueStart.deallocate()
    }

    /// Longest key that is a prefix of `text[start..<end]`.
    @inline(__always)
    func longestMatch(in text: UnsafeBufferPointer<UInt32>, from start: Int, to end: Int) -> Match? {
        guard start < end, firstScalars.contains(text[start]) else { return nil }
        // Invariant: every entry in lo..<hi starts with text[start ..< start + depth].
        var lo = 0
        var hi = count
        var best: Match?
        var depth = 0
        let pool = self.pool
        let keyStart = self.keyStart
        let valueStart = self.valueStart
        while lo < hi {
            // Keys are unique and sorted, so an entry equal to the current prefix sorts first.
            if depth > 0 && Int(valueStart[lo] - keyStart[lo]) == depth {
                best = Match(length: depth, entry: lo)
                lo += 1
                if lo >= hi { break }
            }
            let position = start + depth
            if position >= end { break }
            let c = text[position]
            // Every remaining entry has a scalar at `depth`; narrow to those where it equals c.
            var a = lo, b = hi
            while a < b {
                let m = (a &+ b) >> 1
                if pool[Int(keyStart[m]) + depth] < c { a = m + 1 } else { b = m }
            }
            let newLo = a
            b = hi
            while a < b {
                let m = (a &+ b) >> 1
                if pool[Int(keyStart[m]) + depth] <= c { a = m + 1 } else { b = m }
            }
            lo = newLo
            hi = a
            depth += 1
        }
        return best
    }

    @inline(__always)
    func appendValue(of entry: Int, to output: inout [UInt32]) {
        let from = Int(valueStart[entry])
        let to = Int(keyStart[entry + 1])
        output.append(contentsOf: UnsafeBufferPointer(rebasing: pool[from..<to]))
    }

    /// Calls `body` with each entry's key and default value.
    func forEachEntry(_ body: (UnsafeBufferPointer<UInt32>, UnsafeBufferPointer<UInt32>) -> Void) {
        for e in 0..<count {
            let k = Int(keyStart[e]), v = Int(valueStart[e]), end = Int(keyStart[e + 1])
            body(UnsafeBufferPointer(rebasing: pool[k..<v]), UnsafeBufferPointer(rebasing: pool[v..<end]))
        }
    }

    // MARK: - Parsing helpers

    /// Decodes one UTF-8 scalar and advances `i`. Never reads past the buffer; malformed bytes become U+FFFD.
    @inline(__always)
    private static func decodeScalar(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> UInt32 {
        let n = b.count
        let b0 = UInt32(b[i])
        if b0 < 0x80 { i += 1; return b0 }
        let length: Int
        var scalar: UInt32
        if b0 & 0xE0 == 0xC0 { length = 2; scalar = b0 & 0x1F }
        else if b0 & 0xF0 == 0xE0 { length = 3; scalar = b0 & 0x0F }
        else if b0 & 0xF8 == 0xF0 { length = 4; scalar = b0 & 0x07 }
        else { i += 1; return 0xFFFD }
        guard i + length <= n else { i = n; return 0xFFFD }
        for k in 1..<length { scalar = (scalar << 6) | (UInt32(b[i + k]) & 0x3F) }
        i += length
        return scalar
    }

    private static func compareKeys(_ pool: [UInt32], _ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Int {
        var i = a0, j = b0
        while i < a1 && j < b1 {
            if pool[i] != pool[j] { return pool[i] < pool[j] ? -1 : 1 }
            i += 1; j += 1
        }
        return (a1 - a0) - (b1 - b0)
    }

    private static func isSorted(pool: [UInt32], keyStart: [Int32], valueStart: [Int32]) -> Bool {
        guard valueStart.count > 1 else { return true }
        for e in 1..<valueStart.count where
            compareKeys(pool, Int(keyStart[e - 1]), Int(valueStart[e - 1]), Int(keyStart[e]), Int(valueStart[e])) >= 0 {
            return false
        }
        return true
    }

    private static func sorted(pool: [UInt32], keyStart: [Int32], valueStart: [Int32])
        -> ([UInt32], [Int32], [Int32]) {
        let order = (0..<valueStart.count).sorted {
            compareKeys(pool, Int(keyStart[$0]), Int(valueStart[$0]), Int(keyStart[$1]), Int(valueStart[$1])) < 0
        }
        var newPool: [UInt32] = []
        var newKeyStart: [Int32] = []
        var newValueStart: [Int32] = []
        newPool.reserveCapacity(pool.count)
        var previous: Int?
        for e in order {
            // Keep the first of duplicate keys, like OpenCC's lexicon.
            if let p = previous,
               compareKeys(pool, Int(keyStart[p]), Int(valueStart[p]), Int(keyStart[e]), Int(valueStart[e])) == 0 {
                continue
            }
            previous = e
            newKeyStart.append(Int32(newPool.count))
            newPool.append(contentsOf: pool[Int(keyStart[e])..<Int(valueStart[e])])
            newValueStart.append(Int32(newPool.count))
            newPool.append(contentsOf: pool[Int(valueStart[e])..<Int(keyStart[e + 1])])
        }
        newKeyStart.append(Int32(newPool.count))
        return (newPool, newKeyStart, newValueStart)
    }
}

/// Fixed-size bit set over Unicode scalars below U+40000 (all CJK planes OpenCC uses). 32 KB.
struct ScalarBitSet: Sendable {
    static let limit: UInt32 = 0x40000
    private var words = [UInt64](repeating: 0, count: Int(limit) / 64)

    @inline(__always)
    func contains(_ scalar: UInt32) -> Bool {
        guard scalar < Self.limit else { return false }
        return words[Int(scalar >> 6)] & (1 << UInt64(scalar & 63)) != 0
    }

    mutating func insert(_ scalar: UInt32) {
        guard scalar < Self.limit else { return }
        words[Int(scalar >> 6)] |= 1 << UInt64(scalar & 63)
    }

    mutating func remove(_ scalar: UInt32) {
        guard scalar < Self.limit else { return }
        words[Int(scalar >> 6)] &= ~(1 << UInt64(scalar & 63))
    }
}
