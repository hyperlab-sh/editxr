import XCTest
@testable import editxr

/// `--capabilities=<toml>` switches editor features off for one run: the
/// parser, the palette pruning, and the gates on rows, keys and chrome.
final class CapabilitiesTests: XCTestCase {

    private var savedConfigPath = ""

    override func setUp() {
        super.setUp()
        // A fresh config per test, so a saved sidebar / view preference on the
        // machine can't leak into the assertions.
        savedConfigPath = Config.configPath
        Config.configPath = NSTemporaryDirectory() + "editxr-caps-cfg-\(UUID().uuidString)/config.json"
    }

    override func tearDown() {
        Config.configPath = savedConfigPath
        super.tearDown()
    }

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "editxr-caps-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeApp(_ content: String = "# Title\n\nbody", files: Int = 1,
                         capabilities: Capabilities = Capabilities()) -> (EditorApp, [EditorState], String) {
        let dir = tempDir()
        var states: [EditorState] = []
        for i in 0..<files {
            let path = dir + "/doc\(i).md"
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
            let st = EditorState(filePath: path)
            st.showLineNumbers = false
            st.leftMargin = 0
            states.append(st)
        }
        let app = EditorApp(states: states)
        app.capabilities = capabilities
        return (app, states, dir)
    }

    private func visible(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    // MARK: - parse / load

    func testParseDefaultsAndOverrides() throws {
        XCTAssertEqual(try Capabilities.parse(""), Capabilities())
        let all = try Capabilities.parse("")
        XCTAssertTrue(all.sidebar && all.statusLine && all.tabs && all.ai && all.export
                      && all.vault && all.quickOpen && all.focusMode)

        let caps = try Capabilities.parse("sidebar = false\n# c\nstatus_line=false")
        var expected = Capabilities()
        expected.sidebar = false
        expected.statusLine = false
        XCTAssertEqual(caps, expected)
    }

    func testParseEveryKeyBlankLinesAndComments() throws {
        let text = """
        # a preview run
           \t
        sidebar = false
        status_line = false
        tabs = false   # trailing comment
          ai=false
        export = false
        vault = false
        quick_open = false
        focus_mode = false
        sidebar = true
        """
        let caps = try Capabilities.parse(text)
        XCTAssertEqual(caps, Capabilities(sidebar: true, statusLine: false, tabs: false, ai: false,
                                          export: false, vault: false, quickOpen: false, focusMode: false),
                       "every key parses; a later assignment wins")
        XCTAssertEqual(try Capabilities.parse("\n\n   \n# only comments\n"), Capabilities())
        XCTAssertEqual(try Capabilities.parse("tabs = true\r\n"), Capabilities(), "CRLF files parse")
    }

    func testUnknownKeyIsAnError() {
        XCTAssertThrowsError(try Capabilities.parse("bogus = true")) {
            XCTAssertEqual($0 as? CapabilitiesError, .invalid(line: 1))
        }
        XCTAssertThrowsError(try Capabilities.parse("tabs = yes")) {
            XCTAssertEqual($0 as? CapabilitiesError, .invalid(line: 1))
        }
        for bad in ["sidebar = \"false\"", "sidebar = False", "sidebar", "sidebar =", "= true",
                    "statusLine = false", "sidebar = false = true", "[section]"] {
            XCTAssertThrowsError(try Capabilities.parse(bad), bad)
        }
        XCTAssertThrowsError(try Capabilities.parse("sidebar = true\n\n# x\nfoo = 1")) {
            XCTAssertEqual($0 as? CapabilitiesError, .invalid(line: 4), "1-based line number")
        }
    }

    func testUnreadableFileIsAnError() throws {
        XCTAssertThrowsError(try Capabilities.load(path: "/nonexistent")) {
            XCTAssertEqual($0 as? CapabilitiesError, .unreadable("/nonexistent"))
        }
        let path = tempDir() + "/caps.toml"
        try "export = false\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertFalse(try Capabilities.load(path: path).export)
        XCTAssertTrue(try Capabilities.load(path: path).sidebar)
    }

    func testErrorDescriptionsNameTheProblem() {
        XCTAssertEqual(CapabilitiesError.invalid(line: 3).description, "invalid entry on line 3")
        XCTAssertEqual(CapabilitiesError.unreadable("/x").description, "cannot read /x")
    }

    func testLaunchArgumentsParseTheCapabilitiesPath() {
        let parse = LaunchArguments.parse(arguments: ["editxr", "--capabilities=/tmp/c.toml", "--view=raw", "a.md"],
                                          vaultArgIndex: nil)
        XCTAssertEqual(parse.capabilitiesPath, "/tmp/c.toml")
        XCTAssertEqual(parse.view, .raw, "--view stays independent")
        XCTAssertEqual(parse.filePaths, ["a.md"])
        XCTAssertNil(LaunchArguments.parse(arguments: ["editxr", "a.md"], vaultArgIndex: nil).capabilitiesPath)
        XCTAssertNil(LaunchArguments.parse(arguments: ["editxr", "--capabilities="], vaultArgIndex: nil).capabilitiesPath)
    }

    // MARK: - pruned

    func testPrunedDropsEmptySections() {
        let row = PaletteCommand(title: "row", shortcut: "", action: {})
        let out = CommandPanel.pruned([.header("A"), .spacer, .header("B"), row])
        XCTAssertEqual(out.map(\.title), ["B", "row"])
        XCTAssertEqual(out.map(\.isHeader), [true, false])
    }

    func testPrunedDropsTrailingEmptySectionAndItsSpacer() {
        let a = PaletteCommand(title: "a", shortcut: "", action: {})
        let b = PaletteCommand(title: "b", shortcut: "", action: {})
        let out = CommandPanel.pruned([.header("A"), a, .spacer, .header("Mid"), .spacer, .header("B"), b,
                                       .spacer, .header("Empty")])
        XCTAssertEqual(out.map(\.title), ["A", "a", "", "B", "b"])
        XCTAssertEqual(out.map(\.isSpacer), [false, false, true, false, false])
    }

    func testPrunedKeepsFullListsUntouched() {
        let a = PaletteCommand(title: "a", shortcut: "", action: {})
        let sub = PaletteCommand(title: "sub", shortcut: "→", submenu: { [] }, action: {})
        let list: [PaletteCommand] = [.header("A"), a, .spacer, sub, .spacer, .header("B"), a]
        XCTAssertEqual(CommandPanel.pruned(list).map(\.title), list.map(\.title))
        XCTAssertTrue(CommandPanel.pruned([]).isEmpty)
    }

    // MARK: - gates

    func testDisabledSidebarRemovesItsRowsAndKey() {
        var caps = Capabilities()
        caps.sidebar = false
        let (app, states, _) = makeApp(capabilities: caps)

        XCTAssertFalse(app.shortcutsHelpTitlesForTest().contains("Focus sidebar"))
        XCTAssertFalse(app.paletteTitlesForTest().contains("Focus sidebar"))
        let menu = app.editorMenuTitlesForTest()
        XCTAssertFalse(menu.contains("Outline sidebar"))
        XCTAssertFalse(menu.contains("File explorer sidebar"))

        app.handleInputForTest("\u{1B}s")   // alt+s
        XCTAssertEqual(states[0].sidebarMode, .off)
        XCTAssertFalse(app.sidebarFocusedForTest)

        app.toggleSidebarModeForTest(.outline)
        XCTAssertEqual(states[0].sidebarMode, .off, "the toggle is gated too")

        // A mode loaded from the saved config is never drawn.
        states[0].sidebarMode = .outline
        _ = app.renderEditorLinesForTest(width: 100, height: 20)
        XCTAssertFalse(app.sidebarRenderedForTest, "no sidebar column beside the content")
        app.handleInputForTest("\u{1B}s")
        XCTAssertFalse(app.sidebarFocusedForTest)

        let dir = tempDir()
        try? "hi".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
        let parse = LaunchArguments.parse(arguments: ["editxr", dir], vaultArgIndex: nil)
        let off = LaunchArguments.makeStates(from: parse, sidebarAllowed: false)
        XCTAssertEqual(off.map(\.sidebarMode), [.off])
        XCTAssertEqual(LaunchArguments.makeStates(from: parse).map(\.sidebarMode), [.files])
    }

    func testEnabledSidebarKeepsItsRowsAndKey() {
        let (app, states, _) = makeApp()
        XCTAssertTrue(app.shortcutsHelpTitlesForTest().contains("Focus sidebar"))
        XCTAssertTrue(app.editorMenuTitlesForTest().contains("Outline sidebar"))
        app.handleInputForTest("\u{1B}s")
        XCTAssertEqual(states[0].sidebarMode, .outline)
        _ = app.renderEditorLinesForTest(width: 100, height: 20)
        XCTAssertTrue(app.sidebarRenderedForTest)
        XCTAssertTrue(app.paletteTitlesForTest().contains("Export to HTML"))
        XCTAssertTrue(app.paletteTitlesForTest().contains("Open file"))
        XCTAssertTrue(app.shortcutsHelpTitlesForTest().contains("Cycle focus mode"))
    }

    func testDisabledStatusLineFreesTheRows() {
        var caps = Capabilities()
        caps.statusLine = false
        let (app, states, _) = makeApp(capabilities: caps)
        XCTAssertEqual(app.chromeRows, 1)

        let lines = app.renderEditorLinesForTest(width: 80, height: 20).map(visible)
        XCTAssertEqual(lines.count, 20)
        XCTAssertFalse(lines.contains { $0.contains("ctrl+p commands") })
        XCTAssertFalse(lines.contains { $0.contains("words | Ln") }, "no status bar")
        let contentRows = lines.count - 1   // everything but the top bar
        XCTAssertEqual(contentRows, 20 - 1)
        XCTAssertTrue(lines[1].contains("Title"), "content starts right under the top bar")

        // The big status box is gone as well.
        states[0].statusBarBig = true
        XCTAssertEqual(app.renderEditorLinesForTest(width: 80, height: 20).count, 20)
    }

    func testEnabledStatusLineKeepsThreeChromeRows() {
        let (app, _, _) = makeApp()
        XCTAssertEqual(app.chromeRows, 3)
        let lines = app.renderEditorLinesForTest(width: 80, height: 20).map(visible)
        XCTAssertEqual(lines.count, 20)
        XCTAssertTrue(lines.last?.contains("ctrl+p commands") ?? false)
    }

    func testDisabledExportIgnoresCtrlE() {
        var caps = Capabilities()
        caps.export = false
        let (app, _, dir) = makeApp(capabilities: caps)
        app.handleInputForTest("\u{05}")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/doc0.html"))
        XCTAssertFalse(app.paletteTitlesForTest().contains("Export to HTML"))
        XCTAssertFalse(app.shortcutsHelpTitlesForTest().contains("Export to HTML"))
    }

    func testDisabledFocusModeIgnoresCtrlB() {
        var caps = Capabilities()
        caps.focusMode = false
        let (app, states, _) = makeApp(capabilities: caps)
        app.handleInputForTest("\u{02}")
        XCTAssertEqual(states[0].focusMode, .off)
        XCTAssertFalse(app.editorMenuTitlesForTest().contains("Focus mode (^B)"))
        XCTAssertFalse(app.shortcutsHelpTitlesForTest().contains("Cycle focus mode"))
    }

    func testDisabledVaultAndQuickOpenDropTheirRows() {
        var caps = Capabilities()
        caps.vault = false
        caps.quickOpen = false
        let (app, _, _) = makeApp(capabilities: caps)
        let palette = app.paletteTitlesForTest()
        XCTAssertFalse(palette.contains("Vault"))
        XCTAssertFalse(palette.contains("Search vault"))
        XCTAssertFalse(palette.contains("Open file"))
        let help = app.shortcutsHelpTitlesForTest()
        XCTAssertFalse(help.contains("Vault"))
        XCTAssertFalse(help.contains("Open file"))

        app.handleInputForTest("\u{0B}")   // ctrl+k
        XCTAssertFalse(app.commandPanelVisibleForTest)
        app.handleInputForTest("\u{0F}")   // ctrl+o
        XCTAssertFalse(app.commandPanelVisibleForTest)
    }

    func testDisabledAIDropsItsRows() {
        var caps = Capabilities()
        caps.ai = false
        let (app, _, _) = makeApp(capabilities: caps)
        XCTAssertFalse(app.paletteTitlesForTest().contains("AI assist"))
        XCTAssertFalse(app.shortcutsHelpTitlesForTest().contains("AI assist"))
    }

    func testDisabledTabsKeepsEveryFileButHidesTheStripAndKeys() {
        var caps = Capabilities()
        caps.tabs = false
        let (app, _, _) = makeApp(files: 2, capabilities: caps)
        XCTAssertEqual(app.tabCountForTest, 2, "startup files still open")

        let lines = app.renderEditorLinesForTest(width: 80, height: 20).map(visible)
        XCTAssertEqual(lines.count, 20)
        XCTAssertFalse(lines[0].contains("doc1"), "no tab strip")

        app.handleInputForTest("\u{0E}")   // ctrl+n
        XCTAssertEqual(app.activeTabForTest, 0)
        app.handleInputForTest("\u{0A}")   // ctrl+j (close tab)
        XCTAssertEqual(app.tabCountForTest, 2)
        XCTAssertFalse(app.paletteTitlesForTest().contains("Next tab"))
        XCTAssertFalse(app.shortcutsHelpTitlesForTest().contains("Next tab"))
    }
}
