import XCTest
@testable import ScriberCore

final class ZhTWPreferTaiTests: XCTestCase {
    func testSimplifiedInputEndsUpWithCommonTai() {
        let out = ZhTW.preferCommonTai(ZhTW.toTraditionalTaiwan("我住在台湾台北，这个平台的后台很好用"))
        XCTAssertEqual(out, "我住在台灣台北，這個平臺的後臺很好用".replacingOccurrences(of: "臺", with: "台"))
        XCTAssertFalse(out.contains("臺"))
    }
    func testTraditionalInputWithFormalTaiIsRewritten() {
        XCTAssertEqual(ZhTW.preferCommonTai("臺灣的舞臺"), "台灣的舞台")
    }
    func testIdempotentAndLeavesOtherTextAlone() {
        let s = "颱風天在台中用 Claude Code"
        XCTAssertEqual(ZhTW.preferCommonTai(s), s)
        XCTAssertEqual(ZhTW.preferCommonTai(ZhTW.preferCommonTai("臺北")), "台北")
    }
}
