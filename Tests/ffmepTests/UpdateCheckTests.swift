import XCTest
@testable import ffmep

final class UpdateCheckTests: XCTestCase {
    func testNewerVersionWins() {
        XCTAssertTrue(UpdateCheck.isNewer("1.1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateCheck.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.1", than: "1.0.0"))
    }

    func testSameOrOlderVersionStaysQuiet() {
        XCTAssertFalse(UpdateCheck.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0.0", than: "1.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.9.0", than: "1.0.0"))
    }

    func testNumbersCompareAsNumbers() {
        // The whole reason not to compare the strings: "1.10.0" < "1.9.0" alphabetically.
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.9.0", than: "1.10.0"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(UpdateCheck.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.1", than: "1.0"))
    }

    func testUnparsableVersionsStayQuiet() {
        // A `swift run` build reports "dev", and a pre-release tag isn't a plain run of numbers.
        XCTAssertFalse(UpdateCheck.isNewer("1.0.0", than: "dev"))
        XCTAssertFalse(UpdateCheck.isNewer("1.1.0-beta", than: "1.0.0"))
        XCTAssertFalse(UpdateCheck.isNewer("", than: "1.0.0"))
    }
}
