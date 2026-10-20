import XCTest
@testable import editxr

/// `--follow=<mirror>`: a read-only preview that reloads the editor's mirror
/// file and centres the editor's cursor line (from `<mirror>.cursor`).
final class FollowTests: XCTestCase {

    private var savedConfigPath = ""

    override func setUp() {
        super.setUp()
        // Fresh defaults (wrap on, scroll-past-end on, no sidebar) regardless of
        // the machine's saved preferences.
        savedConfigPath = Config.configPath
        Config.configPath = NSTemporaryDirectory() + "editxr-follow-cfg-\(UUID().uuidString)/config.json"
    }

    override func tearDown() {
        Config.configPath = savedConfigPath
        super.tearDown()
    }

    // MARK: - Helpers

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "editxr-follow-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, _ path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func numbered(_ n: Int) -> String {
        (0..<n).map { "line \($0)" }.joined(separator: "\n")
    }

    /// A follow-mode app on a mirror holding `content`, with `cursor` in the
    /// sidecar (nil: no sidecar). Returns the app and the mirror path.
    private func makeFollowApp(_ content: String?, cursor: String?, base: String? = nil) -> (EditorApp, String) {
        let mirror = tempDir() + "/mirror.md"
        if let content { write(content, mirror) }
        if let cursor { write(cursor, Mirror.cursorPath(for: mirror)) }
        let app = EditorApp(follow: Follow(mirrorPath: mirror, basePath: base))
        app.inlineImagesEnabledForTest = false
        app.terminalOutputForTest = false
        return (app, mirror)
    }

    private func state(_ app: EditorApp) -> EditorState { app.statesForTest[0] }

    private func plainLines(_ app: EditorApp, width: Int, height: Int) -> [String] {
        app.renderEditorLinesForTest(width: width, height: height).map { RenderTests.plain($0) }
    }

    private var fixturesDir: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("agent/fixtures").path
    }

    // MARK: - Parsing

    func testParseFollowFlags() {
        let f = Follow.parse(["editxr", "--follow=/m", "--follow-base=/f.md"])
        XCTAssertEqual(f?.mirrorPath, "/m")
        XCTAssertEqual(f?.basePath, "/f.md")
        XCTAssertNil(Follow.parse(["editxr", "a.md"]), "no flag")
        XCTAssertNil(Follow.parse(["editxr", "--follow="]), "empty value")
        XCTAssertNil(Follow.parse(["editxr", "--follow", "/m"]), "needs =<path>")
        XCTAssertNil(Follow.parse(["--follow=/m"]), "argv[0] is the program")
        XCTAssertNil(Follow.parse(["editxr", "--follow-base=/f.md"]), "base alone is not follow mode")
        let noBase = Follow.parse(["editxr", "--follow=/m", "--follow-base="])
        XCTAssertEqual(noBase?.mirrorPath, "/m")
        XCTAssertNil(noBase?.basePath, "empty base is ignored")
    }

    func testFollowFlagsAreNotOpenedAsFiles() {
        let parse = LaunchArguments.parse(
            arguments: ["editxr", "--follow=/tmp/m.md", "--follow-base=/tmp/f.md", "--image-id-base=1000000"],
            vaultArgIndex: nil)
        XCTAssertEqual(parse.filePaths, [])
        XCTAssertNil(parse.directoryRoot)
    }

    // MARK: - Centring

    func testCenterOnPutsTheLineMidViewport() {
        let dir = tempDir()
        write(numbered(50), dir + "/doc.md")
        let st = EditorState(filePath: dir + "/doc.md")
        st.centerOn(line: 30, viewportHeight: 20, viewportWidth: 80)
        XCTAssertEqual(st.scrollOffset, 30 - 9)
        // Odd height: the exact middle row.
        st.centerOn(line: 30, viewportHeight: 21, viewportWidth: 80)
        XCTAssertEqual(st.scrollOffset, 30 - 10)
        // Unwrapped path (document-line units) centres the same way.
        st.wordWrap = false
        st.centerOn(line: 30, viewportHeight: 20, viewportWidth: 80)
        XCTAssertEqual(st.scrollOffset, 21)
    }

    func testCenterOnClampsAtTheEdges() {
        let dir = tempDir()
        write(numbered(50), dir + "/doc.md")
        let st = EditorState(filePath: dir + "/doc.md")
        st.centerOn(line: 0, viewportHeight: 20, viewportWidth: 80)
        XCTAssertEqual(st.scrollOffset, 0)
        st.centerOn(line: 3, viewportHeight: 20, viewportWidth: 80)
        XCTAssertEqual(st.scrollOffset, 0, "near the top clamps to 0")
        // 50 text lines plus the document's trailing empty line.
        XCTAssertEqual(st.document.lines.count, 51)
        let last = st.document.lines.count - 1
        let maxScroll = st.maxScrollOffset(viewportHeight: 20, viewportWidth: 80)
        XCTAssertEqual(maxScroll, 51 - 20 + 10, "scroll-past-end leaves half a viewport")
        st.centerOn(line: last, viewportHeight: 20, viewportWidth: 80)
        XCTAssertEqual(st.scrollOffset, maxScroll)
        st.centerOn(line: 500, viewportHeight: 20, viewportWidth: 80)
        XCTAssertEqual(st.scrollOffset, maxScroll, "a line past the end clamps")
        st.scrollPastEnd = false
        XCTAssertEqual(st.maxScrollOffset(viewportHeight: 20, viewportWidth: 80), 31)
        st.centerOn(line: 45, viewportHeight: 20, viewportWidth: 80)
        XCTAssertEqual(st.scrollOffset, 31, "clamped below the centring target 36")
    }

    func testCenterOnCountsWrappedVisualRows() {
        let dir = tempDir()
        // Line 0 wraps to several rows at width 20, so line 10's first visual
        // row sits below its document index.
        let long = String(repeating: "word ", count: 20)
        write(([long] + (1..<40).map { "line \($0)" }).joined(separator: "\n"), dir + "/doc.md")
        let st = EditorState(filePath: dir + "/doc.md")
        st.wordWrap = true
        st.centerOn(line: 10, viewportHeight: 10, viewportWidth: 20)
        let extra = st.scrollOffset - (10 - 4)
        XCTAssertGreaterThan(extra, 0, "wrapped rows of line 0 push the offset down")
    }

    // MARK: - Reload

    func testCursorBeyondEndClamps() {
        // Four text lines + the trailing empty line: a 5-line document.
        let (app, _) = makeFollowApp("a\nb\nc\nd", cursor: "99\n")
        app.reloadFollowForTest()
        XCTAssertEqual(state(app).document.lines.count, 5)
        XCTAssertEqual(app.followLineForTest, 4)
        _ = app.renderEditorLinesForTest(width: 40, height: 3)
        // Height 3: line 4 belongs on row 1 → offset 3 (also the max scroll).
        XCTAssertEqual(state(app).scrollOffset, 3)
    }

    func testNegativeCursorClampsToTheTop() {
        let (app, _) = makeFollowApp(numbered(50), cursor: "-7\n")
        app.reloadFollowForTest()
        XCTAssertEqual(app.followLineForTest, 0)
        _ = app.renderEditorLinesForTest(width: 40, height: 10)
        XCTAssertEqual(state(app).scrollOffset, 0)
    }

    func testBadCursorFileIsIgnored() {
        let (app, mirror) = makeFollowApp(numbered(50), cursor: "30\n")
        app.reloadFollowForTest()
        _ = app.renderEditorLinesForTest(width: 40, height: 10)
        let centred = state(app).scrollOffset
        XCTAssertEqual(centred, 30 - 4)

        try? FileManager.default.removeItem(atPath: Mirror.cursorPath(for: mirror))
        app.reloadFollowForTest()
        _ = app.renderEditorLinesForTest(width: 40, height: 10)
        XCTAssertEqual(state(app).scrollOffset, centred, "missing sidecar keeps the last line")
        XCTAssertEqual(app.followLineForTest, 30)

        write("x\n", Mirror.cursorPath(for: mirror))
        app.reloadFollowForTest()
        _ = app.renderEditorLinesForTest(width: 40, height: 10)
        XCTAssertEqual(state(app).scrollOffset, centred, "garbage sidecar keeps the last line")
    }

    func testReloadFollowsTheMirror() {
        let (app, mirror) = makeFollowApp("first version", cursor: "0\n")
        app.reloadFollowForTest()
        XCTAssertTrue(plainLines(app, width: 40, height: 11).joined().contains("first version"))

        write(numbered(30), mirror)
        write("15\n", Mirror.cursorPath(for: mirror))
        app.reloadFollowForTest()
        let lines = plainLines(app, width: 40, height: 11)
        XCTAssertEqual(lines.count, 11)
        XCTAssertFalse(lines.joined().contains("first version"))
        // Height 11: the middle row is index 5.
        XCTAssertTrue(lines[5].contains("line 15"), lines.joined(separator: "\n"))
        XCTAssertFalse(state(app).isDirty)
    }

    func testMissingMirrorShowsAnEmptyDocument() {
        let (app, mirror) = makeFollowApp(nil, cursor: nil)
        app.reloadFollowForTest()
        let lines = plainLines(app, width: 30, height: 5)
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty },
                      "no splash, no chrome: \(lines)")
        write("arrived", mirror)
        app.reloadFollowForTest()
        XCTAssertTrue(plainLines(app, width: 30, height: 5).joined().contains("arrived"))
    }

    func testManualScrollHoldsUntilTheNextReload() {
        let (app, _) = makeFollowApp(numbered(60), cursor: "30\n")
        app.reloadFollowForTest()
        _ = app.renderEditorLinesForTest(width: 40, height: 10)
        XCTAssertEqual(state(app).scrollOffset, 26)
        app.handleInputForTest("\u{1B}[B")       // down arrow: one row
        _ = app.renderEditorLinesForTest(width: 40, height: 10)
        XCTAssertEqual(state(app).scrollOffset, 27, "arrow scrolls; no cursor-follow snaps it back")
        app.handleInputForTest("\u{1B}[<65;5;5M") // wheel down: three rows
        _ = app.renderEditorLinesForTest(width: 40, height: 10)
        XCTAssertEqual(state(app).scrollOffset, 30)
        app.handleInputForTest("\u{1B}[H")       // Home
        XCTAssertEqual(state(app).scrollOffset, 0)
        app.reloadFollowForTest()
        _ = app.renderEditorLinesForTest(width: 40, height: 10)
        XCTAssertEqual(state(app).scrollOffset, 26, "the next change re-centres")
    }

    // MARK: - Rendering

    func testFollowModeRendersImagesOnTheCursorBlock() {
        // Relative link resolved against --follow-base, not the mirror's folder.
        let (app, _) = makeFollowApp("before\n![alt](sample.png)\nafter\n", cursor: "1\n",
                                     base: fixturesDir + "/sample.md")
        app.inlineImagesEnabledForTest = true
        app.reloadFollowForTest()
        let lines = plainLines(app, width: 80, height: 30)
        XCTAssertGreaterThan(state(app).imageRowCounts[1] ?? 0, 0, "cursor block still shows its image")
        XCTAssertFalse(lines.joined().contains("![alt]"), "no raw source on the cursor line")
    }

    func testCursorLineRendersAsPreviewNotRaw() {
        let table = "intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        let (app, _) = makeFollowApp(table, cursor: "2\n")
        app.reloadFollowForTest()
        let text = plainLines(app, width: 40, height: 10).joined(separator: "\n")
        XCTAssertTrue(text.contains("│"), "table under the cursor still renders boxed:\n\(text)")
        XCTAssertFalse(text.contains("|---|"))
    }

    func testFollowModeHasNoChrome() {
        let (app, _) = makeFollowApp("# Title\n\nbody", cursor: "0\n")
        app.reloadFollowForTest()
        XCTAssertEqual(app.chromeRows, 0)
        let lines = plainLines(app, width: 40, height: 10)
        XCTAssertEqual(lines.count, 10)
        XCTAssertFalse(lines.contains { $0.contains("ctrl+p") })
        XCTAssertFalse(lines.contains { $0.contains("mirror.md") }, "no top bar")
        XCTAssertTrue(lines[0].contains("Title"), "content starts on the first row: \(lines)")
        XCTAssertEqual(app.lastContentHeightForTest, 10)
    }

    func testFollowModeForcesRenderedViewAndNoSidebar() {
        let (app, _) = makeFollowApp("# Title", cursor: "0\n")
        XCTAssertEqual(state(app).viewMode, .normal)
        XCTAssertTrue(state(app).viewModePinned)
        XCTAssertEqual(state(app).sidebarMode, .off)
        app.handleInputForTest(String(Key.ctrlR))
        XCTAssertEqual(state(app).viewMode, .normal, "ctrl+r is ignored")
        app.handleInputForTest(String(Key.ctrlP))
        XCTAssertFalse(app.commandPanelVisibleForTest, "no palette")
    }

    func testFollowModeIgnoresTyping() {
        let (app, mirror) = makeFollowApp("hello\nworld", cursor: "0\n")
        app.reloadFollowForTest()
        let before = state(app).document.content
        app.handleInputForTest("abc")
        app.handleInputForTest("\r")
        app.handleInputForTest("\u{7F}")
        app.handleInputForTest("\u{1B}[200~pasted\u{1B}[201~")
        app.handleInputForTest(String(Key.ctrlU))
        app.handleInputForTest(String(Key.tab))
        XCTAssertEqual(state(app).document.content, before)
        XCTAssertFalse(state(app).isDirty)
        XCTAssertEqual(try? String(contentsOfFile: mirror, encoding: .utf8), "hello\nworld",
                       "the mirror file is never written by the preview")
    }

    func testUnlimitedMaxRows() {
        let images = Images()
        XCTAssertEqual(images.maxRows(unlimited: true), Int.max)
        XCTAssertLessThanOrEqual(images.maxRows(), 100)
        XCTAssertEqual(images.maxRows(unlimited: false), images.maxRows())
    }

    // MARK: - Watcher

    func testWatchFiresWhenTheMirrorOrSidecarChanges() {
        let dir = tempDir()
        let mirror = dir + "/mirror.md"
        write("one", mirror)
        let follow = Follow(mirrorPath: mirror, basePath: nil)

        let first = expectation(description: "mirror change")
        var fired = 0
        var pending: [XCTestExpectation] = [first]
        let token = follow.watch {
            fired += 1
            if !pending.isEmpty { pending.removeFirst().fulfill() }
        }
        write("two, longer", mirror)
        wait(for: [first], timeout: 2)

        let second = expectation(description: "sidecar created")
        pending = [second]
        write("3\n", Mirror.cursorPath(for: mirror))
        wait(for: [second], timeout: 2)
        XCTAssertGreaterThanOrEqual(fired, 2)
        withExtendedLifetime(token) {}
    }
}
