import XCTest
@testable import editxr

/// `--mirror=<path>`: the buffer follows to a file on every change; SIGUSR1 saves.
final class MirrorTests: XCTestCase {

    private func tempPath(_ name: String) -> String {
        NSTemporaryDirectory() + "editxr-mirror-\(name)-\(UUID().uuidString).md"
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    func testPathComesFromTheFlagOnly() {
        XCTAssertEqual(Mirror.path(in: ["editxr", "--mirror=/tmp/m.md", "a.md"]), "/tmp/m.md")
        XCTAssertEqual(Mirror.path(in: ["editxr", "a.md", "--mirror=rel/m.md"]), "rel/m.md")
        XCTAssertNil(Mirror.path(in: ["editxr", "--mirror=", "a.md"]), "empty value")
        XCTAssertNil(Mirror.path(in: ["editxr", "--mirror", "a.md"]), "needs =<path>")
        XCTAssertNil(Mirror.path(in: ["editxr", "a.md"]))
        XCTAssertNil(Mirror.path(in: ["--mirror=/x"]), "argv[0] is the program")
    }

    func testTheFlagIsNotOpenedAsAFile() {
        let parse = LaunchArguments.parse(
            arguments: ["editxr", "--mirror=/tmp/m.md", "a.md"], vaultArgIndex: nil)
        XCTAssertEqual(parse.filePaths, ["a.md"])
    }

    func testUpdateWritesOnlyWhenTheBufferChanged() {
        let file = tempPath("file")
        try? "hello\n".write(toFile: file, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: file)
        let mirror = Mirror(path: tempPath("out"), state: state)

        XCTAssertTrue(mirror.update(), "first update writes the loaded buffer")
        XCTAssertEqual(read(mirror.path), "hello\n")
        XCTAssertFalse(mirror.update(), "unchanged buffer: no write")

        state.document.lines[0] = "changed"
        XCTAssertTrue(mirror.update())
        XCTAssertEqual(read(mirror.path), "changed\n")
        XCTAssertEqual(read(file), "hello\n", "the file itself is untouched")

        state.save()
        XCTAssertEqual(read(file), read(mirror.path), "mirror is exactly what Save writes")
    }

    func testUpdateWritesCursorSidecarWhenTheCursorLineChanges() {
        let file = tempPath("file")
        try? "a\nb\nc".write(toFile: file, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: file)
        state.document.cursorLine = 0
        let mirror = Mirror(path: tempPath("out"), state: state)
        let sidecar = Mirror.cursorPath(for: mirror.path)
        XCTAssertEqual(sidecar, mirror.path + ".cursor")

        mirror.update()
        XCTAssertEqual(read(sidecar), "0\n")

        state.document.cursorLine = 2
        mirror.update()
        XCTAssertEqual(read(sidecar), "2\n")

        XCTAssertFalse(mirror.update(), "buffer unchanged")
        XCTAssertEqual(read(sidecar), "2\n")
    }

    func testReadCursorRejectsGarbage() {
        let p = tempPath("cur")
        XCTAssertNil(Mirror.readCursor(at: p), "missing")
        for (text, want) in [("", nil), ("x\n", nil), ("7\n", 7), ("7", 7)] as [(String, Int?)] {
            try? text.write(toFile: p, atomically: true, encoding: .utf8)
            XCTAssertEqual(Mirror.readCursor(at: p), want, "\(text.debugDescription)")
        }
    }

    func testAFailedWriteIsRetriedOnTheNextUpdate() {
        let state = EditorState(filePath: tempPath("file"))
        let dir = NSTemporaryDirectory() + "editxr-mirror-missing-\(UUID().uuidString)"
        let mirror = Mirror(path: dir + "/out.md", state: state)
        XCTAssertFalse(mirror.update(), "directory does not exist")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertTrue(mirror.update(), "same buffer is written once the path works")
    }

    func testTypingUpdatesTheMirrorThroughRender() {
        let file = tempPath("file")
        try? "\n".write(toFile: file, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: file)
        let app = EditorApp(states: [state])
        let mirror = Mirror(path: tempPath("out"), state: state)
        app.mirror = mirror

        app.handleInputForTest("abc")
        XCTAssertEqual(read(mirror.path), state.document.content)
        XCTAssertTrue(read(mirror.path)?.hasPrefix("abc") ?? false, String(describing: read(mirror.path)))
        XCTAssertTrue(state.isDirty, "mirroring does not save")
    }

    #if !os(Windows)
    func testSigusr1RunsTheSaveHandler() {
        let mirror = Mirror(path: tempPath("out"), state: EditorState(filePath: tempPath("file")))
        let saved = expectation(description: "save handler ran")
        mirror.watchSaveSignal { saved.fulfill() }
        kill(getpid(), SIGUSR1)
        wait(for: [saved], timeout: 2)
    }
    #endif
}
