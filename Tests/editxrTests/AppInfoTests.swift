import XCTest
@testable import editxr

final class AppInfoTests: XCTestCase {
    func testTaskTabFixReleaseIdentity() {
        XCTAssertEqual(AppInfo.version, "1.9.0")
        XCTAssertTrue(AppInfo.helpText.hasPrefix("editxr 1.9.0 —"))
    }

    func testHelpDocumentsBareVault() {
        XCTAssertTrue(AppInfo.helpText.contains("--vault         Open the configured vault"),
                      "the bare --vault form must be discoverable in the help")
    }

    func testHelpListsHostFlags() {
        for flag in ["--follow=<mirror>", "--follow-base=<file>", "--capabilities=<file>",
                     "--view=raw|rendered", "--image-id-base=<n>", "--no-images"] {
            XCTAssertTrue(AppInfo.helpText.contains(flag), "help must list \(flag)")
        }
    }
}
