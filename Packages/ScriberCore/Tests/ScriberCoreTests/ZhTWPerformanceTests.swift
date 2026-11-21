import XCTest
@testable import ScriberCore

/// Timing numbers for the zh-TW conversion. Prints results; thresholds are loose because tests
/// usually run unoptimized. Measure with `swift test -c release -Xswiftc -enable-testing`.
final class ZhTWPerformanceTests: XCTestCase {
    private static let sample500: String = {
        let paragraph = "我今天用Claude Code写了一个iOS的app，然后把项目deploy到Railway上面。数据库用的是Supabase，"
            + "视频和软件的信息都存在里面。后来我发现鼠标坏了，内存也不够，只好先把头发剪了再说。"
            + "这个网络服务器的响应时间太长了，我们需要优化一下算法的性能，顺便修复几个bug。"
        var text = ""
        while text.count < 500 { text += paragraph }
        return String(text.prefix(500))
    }()

    private static func millis(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testColdLoadTime() throws {
        var loads: [Double] = []
        for _ in 0..<3 {
            let converter = try OpenCCS2TWP(bundle: .module)
            loads.append(converter.loadMillis)
        }
        print(String(format: "ZhTWPerf load (fresh parse of all dictionaries): %.1f / %.1f / %.1f ms", loads[0], loads[1], loads[2]))
        XCTAssertLessThan(loads.min()!, 2_000)
    }

    func testConversionSpeed() {
        ZhTW.prewarm()
        let text = Self.sample500
        XCTAssertEqual(text.count, 500)
        _ = ZhTW.toTraditionalTaiwan(text)
        let rounds = 50
        let simplified = Self.millis { for _ in 0..<rounds { _ = ZhTW.toTraditionalTaiwan(text) } } / Double(rounds)
        let converted = ZhTW.toTraditionalTaiwan(text)
        let traditional = Self.millis { for _ in 0..<rounds { _ = ZhTW.toTraditionalTaiwan(converted) } } / Double(rounds)
        let exact = Self.millis { for _ in 0..<rounds { _ = ZhTW.openCCS2TWP(text) } } / Double(rounds)
        let normalize = Self.millis {
            for _ in 0..<rounds { _ = ZhTW.normalize(converted, spaceBetweenCJKAndLatin: true) }
        } / Double(rounds)
        print(String(format: "ZhTWPerf 500 chars: toTraditionalTaiwan(simplified) %.3f ms, "
                     + "toTraditionalTaiwan(traditional) %.3f ms, openCCS2TWP %.3f ms, normalize %.3f ms",
                     simplified, traditional, exact, normalize))
        XCTAssertLessThan(simplified, 100)
    }

    /// Everything this slice adds after STT/LLM: dictionary replacements → zh-TW → normalize.
    func testPostProcessingSpeed() {
        ZhTW.prewarm()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        for entry in DictionaryStore.builtInEntries { store.add(entry) }
        let text = Self.sample500
        func run() -> String {
            ZhTW.normalize(ZhTW.toTraditionalTaiwan(store.applyReplacements(to: text)), spaceBetweenCJKAndLatin: true)
        }
        _ = run()
        let rounds = 50
        let total = Self.millis { for _ in 0..<rounds { _ = run() } } / Double(rounds)
        let replace = Self.millis { for _ in 0..<rounds { _ = store.applyReplacements(to: text) } } / Double(rounds)
        print(String(format: "ZhTWPerf 500 chars post-processing (%d built-in entries): total %.3f ms, "
                     + "applyReplacements %.3f ms", store.snapshot().count, total, replace))
        print("ZhTWPerf sample output: \(run().prefix(80))")
        XCTAssertLessThan(total, 200)
    }
}
