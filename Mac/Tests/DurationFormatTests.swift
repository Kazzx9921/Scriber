import XCTest

final class DurationFormatTests: XCTestCase {
    func testParts() {
        XCTAssertEqual(DurationFormat.text(seconds: 0), "0 秒")
        XCTAssertEqual(DurationFormat.text(seconds: 42.4), "42 秒")
        XCTAssertEqual(DurationFormat.text(seconds: 125), "2 分 5 秒")
        XCTAssertEqual(DurationFormat.text(seconds: 180), "3 分")
        XCTAssertEqual(DurationFormat.text(seconds: 754), "12 分")
        XCTAssertEqual(DurationFormat.text(seconds: 8_040), "2 小時 14 分")
        XCTAssertEqual(DurationFormat.text(seconds: 7_200), "2 小時")
        XCTAssertEqual(DurationFormat.text(seconds: 400_000), "111 小時")
        XCTAssertEqual(DurationFormat.text(seconds: -5), "0 秒")
    }
}
