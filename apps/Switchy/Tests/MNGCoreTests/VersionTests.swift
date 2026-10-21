import XCTest
@testable import MNGCore

final class VersionTests: XCTestCase {
    func testNewerTags() {
        XCTAssertTrue(SemanticVersion.isNewer("v1.1.0", than: "1.0.0"))
        XCTAssertTrue(SemanticVersion.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(SemanticVersion.isNewer("2", than: "1.9.9"))
        XCTAssertTrue(SemanticVersion.isNewer("1.0.1", than: "1.0"))
    }

    func testSameOrOlderTags() {
        XCTAssertFalse(SemanticVersion.isNewer("v1.0.0", than: "1.0.0"))
        XCTAssertFalse(SemanticVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(SemanticVersion.isNewer("0.9.9", than: "1.0.0"))
        XCTAssertFalse(SemanticVersion.isNewer("", than: "1.0.0"))
    }
}
