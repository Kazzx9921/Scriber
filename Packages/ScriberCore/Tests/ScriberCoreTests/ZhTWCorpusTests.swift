import XCTest
@testable import ScriberCore

/// Compares against a large corpus converted by the real `opencc -c s2twp` (OpenCC 1.4.2).
/// Skipped unless both files are given, e.g.
/// `SCRIBER_OPENCC_INPUT=in.txt SCRIBER_OPENCC_GOLDEN=out.txt swift test --filter ZhTWCorpusTests`
/// (one input per line; produce the golden file with `opencc -c s2twp -i in.txt -o out.txt`).
final class ZhTWCorpusTests: XCTestCase {
    private func corpus() throws -> [(input: String, golden: String)] {
        let env = ProcessInfo.processInfo.environment
        guard let inputPath = env["SCRIBER_OPENCC_INPUT"], let goldenPath = env["SCRIBER_OPENCC_GOLDEN"] else {
            throw XCTSkip("Set SCRIBER_OPENCC_INPUT and SCRIBER_OPENCC_GOLDEN to run the corpus comparison.")
        }
        let inputs = try String(contentsOfFile: inputPath, encoding: .utf8).components(separatedBy: "\n")
        let goldens = try String(contentsOfFile: goldenPath, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(inputs.count, goldens.count, "line counts differ")
        return Array(zip(inputs, goldens))
    }

    func testExactS2TWPMatchesOpenCC() throws {
        let pairs = try corpus()
        var mismatches = 0
        for (index, pair) in pairs.enumerated() {
            let output = ZhTW.openCCS2TWP(pair.input)
            if output != pair.golden {
                mismatches += 1
                if mismatches <= 20 {
                    print("MISMATCH line \(index + 1)\n  in:     \(pair.input)\n  opencc: \(pair.golden)\n  ours:   \(output)")
                }
            }
        }
        print("ZhTWCorpus exact s2twp: \(mismatches) mismatches in \(pairs.count) lines")
        XCTAssertEqual(mismatches, 0)
    }

    func testScriptAwareConversionOnCorpus() throws {
        let pairs = try corpus()
        var differsFromOpenCC = 0, notIdempotent = 0, leaks = 0, unexplained = 0, settled = 0
        // Optional: SCRIBER_OPENCC_DIFF=path writes every line that deviates from s2twp, for review.
        var diffReport = ""
        for pair in pairs {
            let output = ZhTW.toTraditionalTaiwan(pair.input)
            if ZhTW.containsSimplified(output) { leaks += 1 }
            let again = ZhTW.toTraditionalTaiwan(output)
            if again != output {
                notIdempotent += 1
                if notIdempotent <= 10 { print("NOT IDEMPOTENT\n  in:  \(pair.input)\n  1st: \(output)\n  2nd: \(again)") }
            }
            if output != pair.golden {
                differsFromOpenCC += 1
                diffReport += "in:     \(pair.input)\nopencc: \(pair.golden)\nours:   \(output)\n\n"
                // Only text with Traditional-only characters may deviate from s2twp, plus text where
                // s2twp is not idempotent on its own output (settled to a fixed point instead).
                let traditional = pair.input.unicodeScalars.contains {
                    OpenCCS2TWP.shared.traditionalOnly.contains($0.value)
                }
                if !traditional && ZhTW.openCCS2TWP(pair.golden) != pair.golden {
                    settled += 1
                } else if !traditional {
                    unexplained += 1
                    if unexplained <= 10 { print("UNEXPLAINED\n  in:     \(pair.input)\n  opencc: \(pair.golden)\n  ours:   \(output)") }
                }
            }
            if ZhTW.containsSimplified(pair.golden) { print("OPENCC LEAK: \(pair.golden)") }
        }
        print("ZhTWCorpus script-aware: \(pairs.count) lines, \(differsFromOpenCC) differ from s2twp "
              + "(\(settled) settled because s2twp is not idempotent there, the rest on input with "
              + "Traditional characters; unexplained: \(unexplained)), "
              + "\(notIdempotent) not idempotent, \(leaks) Simplified leaks")
        if let path = ProcessInfo.processInfo.environment["SCRIBER_OPENCC_DIFF"] {
            try diffReport.write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(leaks, 0)
        XCTAssertEqual(notIdempotent, 0)
        XCTAssertEqual(unexplained, 0)
    }
}
