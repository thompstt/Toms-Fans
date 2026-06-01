import XCTest

final class HelperVersionCheckTests: XCTestCase {

    func testNilInstalledIsUnknown() {
        XCTAssertEqual(HelperVersionCheck.evaluate(installed: nil, expected: "1.0.1"), .unknown)
    }

    func testEmptyInstalledIsUnknown() {
        XCTAssertEqual(HelperVersionCheck.evaluate(installed: "", expected: "1.0.1"), .unknown)
    }

    func testEqualVersionsMatch() {
        XCTAssertEqual(HelperVersionCheck.evaluate(installed: "1.0.1", expected: "1.0.1"),
                       .matched("1.0.1"))
    }

    func testDifferentVersionsMismatch() {
        XCTAssertEqual(HelperVersionCheck.evaluate(installed: "1.0.0", expected: "1.0.1"),
                       .mismatched(installed: "1.0.0", expected: "1.0.1"))
    }

    /// Comparison is exact: a newer installed helper than the app expects is still a
    /// mismatch (e.g. app downgraded while an old daemon lingers).
    func testNewerInstalledIsStillMismatch() {
        XCTAssertEqual(HelperVersionCheck.evaluate(installed: "2.0.0", expected: "1.0.1"),
                       .mismatched(installed: "2.0.0", expected: "1.0.1"))
    }
}
