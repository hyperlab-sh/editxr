import XCTest
@testable import editxr

final class EditorStateTests: XCTestCase {
    func testViewFlagDoesNotPersistRenderMarkdown() throws {
        let saved = Config.configPath
        let path = NSTemporaryDirectory() + "editxr-cfg-\(UUID().uuidString)/config.json"
        Config.configPath = path
        defer { Config.configPath = saved }

        var config = Config()
        config.renderMarkdown = true
        config.save()

        let state = EditorState(filePath: NSTemporaryDirectory() + "editxr-view-\(UUID().uuidString).md")
        state.viewMode = .normal
        state.viewModePinned = true
        state.toggleViewMode()
        XCTAssertEqual(state.viewMode, .raw)
        XCTAssertTrue(Config.load().renderMarkdown)
        state.toggleViewMode()
        XCTAssertEqual(state.viewMode, .normal)
        XCTAssertTrue(Config.load().renderMarkdown)
    }

    func testUnpinnedToggleStillPersists() {
        let saved = Config.configPath
        Config.configPath = NSTemporaryDirectory() + "editxr-cfg-\(UUID().uuidString)/config.json"
        defer { Config.configPath = saved }

        var config = Config()
        config.renderMarkdown = true
        config.save()
        let state = EditorState(filePath: NSTemporaryDirectory() + "editxr-view-\(UUID().uuidString).md")
        state.toggleViewMode()
        XCTAssertFalse(Config.load().renderMarkdown)
    }
}
