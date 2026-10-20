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

    func testOpenedTabInheritsPinnedView() throws {
        let saved = Config.configPath
        Config.configPath = NSTemporaryDirectory() + "editxr-cfg-\(UUID().uuidString)/config.json"
        defer { Config.configPath = saved }
        var config = Config()
        config.renderMarkdown = true
        config.save()

        let dir = NSTemporaryDirectory() + "editxr-open-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "a".write(toFile: dir + "/a.md", atomically: true, encoding: .utf8)
        try "b".write(toFile: dir + "/b.md", atomically: true, encoding: .utf8)

        let first = EditorState(filePath: dir + "/a.md")
        first.viewMode = .raw
        first.viewModePinned = true
        let app = EditorApp(states: [first])
        app.openFileForTest(dir + "/b.md")

        let opened = try XCTUnwrap(app.statesForTest.last)
        XCTAssertEqual(app.statesForTest.count, 2)
        XCTAssertEqual(opened.viewMode, .raw)
        XCTAssertTrue(opened.viewModePinned)
        opened.toggleViewMode()
        XCTAssertTrue(Config.load().renderMarkdown, "toggle in an opened tab must not persist")
    }
}
