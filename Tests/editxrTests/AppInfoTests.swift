import XCTest
@testable import editxr

final class AppInfoTests: XCTestCase {
    func testTaskTabFixReleaseIdentity() {
        XCTAssertEqual(AppInfo.version, "1.8.1")
        XCTAssertTrue(AppInfo.helpText.hasPrefix("editxr 1.8.1 —"))
    }
}
