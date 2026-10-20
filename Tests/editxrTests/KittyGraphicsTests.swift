import XCTest
@testable import editxr

final class KittyGraphicsTests: XCTestCase {
    func testDeleteImageTargetsOneId() {
        XCTAssertEqual(KittyGraphics.deleteImage(id: 100), "\u{1B}_Ga=d,d=i,i=100,q=2\u{1B}\\")
        XCTAssertEqual(KittyGraphics.deleteImage(id: 1_000_000), "\u{1B}_Ga=d,d=i,i=1000000,q=2\u{1B}\\")
    }
}
