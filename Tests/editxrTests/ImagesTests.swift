import XCTest
@testable import editxr

final class ImagesTests: XCTestCase {
    func testFenceDetectionAndCursorExclusion() {
        let lines = ["before", "```mermaid", "graph TD; A-->B", "```", "after", "![alt](sample.png)"]
        XCTAssertEqual(InlineImages.blocks(lines: lines, cursorLine: 0).map(\.range), [1...3, 5...5])
        for cursor in 1...3 {
            XCTAssertEqual(InlineImages.blocks(lines: lines, cursorLine: cursor).map(\.range), [5...5])
        }
        XCTAssertEqual(InlineImages.blocks(lines: ["```swift", "![x](x.png)", "```"], cursorLine: 9).count, 0)
        XCTAssertTrue(InlineImages.blocks(lines: ["![x](https://example.com/x.png)", "```mermaid", "unfinished"], cursorLine: 9).isEmpty)
    }

    func testCacheKeyStability() {
        let key = InlineImages.cacheKey(theme: "dark", scale: 2, source: "graph TD; A-->B")
        XCTAssertEqual(key, "46d9289fb20a5ca0b936657c35e80c7e98a131739a39d45140633de40d52465d")
        XCTAssertNotEqual(key, InlineImages.cacheKey(theme: "light", scale: 2, source: "graph TD; A-->B"))
        XCTAssertNotEqual(key, InlineImages.cacheKey(theme: "dark", scale: 1, source: "graph TD; A-->B"))
    }

    func testKittyChunkingAndPlacement() {
        let encoded = KittyGraphics.transmit(Data(repeating: 42, count: 7000), id: 7)
        let chunks = encoded.components(separatedBy: "\u{1B}\\").filter { !$0.isEmpty }
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks[0].hasPrefix("\u{1B}_Ga=t,f=100,t=d,i=7,q=2,m=1;"))
        XCTAssertTrue(chunks[1].contains("m=1;"))
        XCTAssertTrue(chunks[2].contains("m=0;"))
        XCTAssertTrue(chunks.allSatisfy { $0.components(separatedBy: ";").last!.utf8.count <= 4096 })
        XCTAssertTrue(KittyGraphics.place(id: 7, row: 4, column: 2, columns: 20, rows: 8).contains("\u{1B}[4;2H"))
        XCTAssertTrue(KittyGraphics.deletePlacements.contains("a=d,d=a"))
    }

    func testLayoutContributionAndCursorReveal() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = directory.appendingPathComponent("agent/fixtures/sample.png").path
        let file = NSTemporaryDirectory() + "images-\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: file) }
        try "before\n![alt](\(path))\nafter\n".write(toFile: file, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: file)
        state.wordWrap = true
        state.sidebarMode = .off
        state.document.cursorLine = 0
        let app = EditorApp(states: [state])
        app.inlineImagesEnabledForTest = true
        _ = app.renderEditorLinesForTest(width: 80, height: 30)
        XCTAssertGreaterThan(state.imageRowCounts[1] ?? 0, 1)
        state.document.cursorLine = 1
        let raw = app.renderEditorLinesForTest(width: 80, height: 30).joined(separator: "\n")
        XCTAssertTrue(state.imageRowCounts.isEmpty)
        XCTAssertTrue(RenderTests.plain(raw).contains("![alt]"))
        app.inlineImagesEnabledForTest = false
        state.document.cursorLine = 0
        _ = app.renderEditorLinesForTest(width: 80, height: 30)
        XCTAssertTrue(state.imageRowCounts.isEmpty)
        app.inlineImagesEnabledForTest = true
        state.wordWrap = false
        _ = app.renderEditorLinesForTest(width: 80, height: 30)
        XCTAssertGreaterThan(state.imageRowCounts[1] ?? 0, 1)
        state.document.lines[2] = String(repeating: "x", count: 200)
        state.document.cursorLine = 2
        state.document.cursorColumn = 200
        let scrolled = app.renderEditorLinesForTest(width: 80, height: 30).joined(separator: "\n")
        XCTAssertGreaterThan(state.scrollX, 0)
        XCTAssertTrue(scrolled.contains(Theme.inverse))
        state.viewMode = .raw
        _ = app.renderEditorLinesForTest(width: 80, height: 30)
        XCTAssertTrue(state.imageRowCounts.isEmpty)
    }

    func testCapabilities() {
        XCTAssertFalse(KittyGraphics.supported(environment: ["TERM_PROGRAM": "Apple_Terminal"]))
        XCTAssertTrue(KittyGraphics.supported(environment: ["TERM": "xterm-kitty"]))
        XCTAssertTrue(KittyGraphics.supported(environment: ["TERM_PROGRAM": "WezTerm"]))
        XCTAssertTrue(KittyGraphics.supported(environment: ["GHOSTTY_RESOURCES_DIR": "/resources"]))
    }

    func testPlacementsTransmitOnceAndReuseID() {
        let service = Images()
        let ready = Images.Ready(png: ImagePNG(data: Data([1, 2, 3]), width: 1, height: 1), id: 99)
        let placement = Images.Placement(image: ready, row: 3, column: 2, columns: 10, rows: 5)
        let first = service.commands([placement])
        XCTAssertTrue(first.contains("a=t"))
        XCTAssertTrue(first.contains("a=p,i=99"))
        // Removed, then shown again: placed anew but never re-transmitted.
        XCTAssertEqual(service.commands([]), KittyGraphics.deleteImage(id: 99))
        let again = service.commands([placement])
        XCTAssertFalse(again.contains("a=t"))
        XCTAssertTrue(again.contains("a=p,i=99"))
    }

    func testIdsStartAtTheBase() {
        let png = ImagePNG(data: Data([1, 2, 3]), width: 1, height: 1)
        let service = Images(idBase: 1_000_000)
        XCTAssertEqual(service.register(png).id, 1_000_000)
        XCTAssertEqual(service.register(png).id, 1_000_001)
        XCTAssertEqual(Images().register(png).id, 100)
    }

    func testIdBaseFlagParsing() {
        XCTAssertEqual(Images.imageIdBaseFlag, "--image-id-base=")
        XCTAssertEqual(Images.idBase(in: ["editxr", "--image-id-base=1000000", "a.md"]), 1_000_000)
        XCTAssertNil(Images.idBase(in: ["editxr", "a.md"]))
        XCTAssertNil(Images.idBase(in: ["editxr", "--image-id-base="]))
        XCTAssertNil(Images.idBase(in: ["editxr", "--image-id-base=abc"]))
        XCTAssertNil(Images.idBase(in: ["editxr", "--image-id-base=-5"]))
        XCTAssertNil(Images.idBase(in: ["editxr", "--image-id-base=0"]))
        XCTAssertNil(Images.idBase(in: ["editxr", "--image-id-base=99999999999"]))
    }

    func testCommandsEmitOnlyTheDelta() {
        let service = Images(idBase: 500)
        let image = service.register(ImagePNG(data: Data([1, 2, 3]), width: 1, height: 1))
        let delete = KittyGraphics.deleteImage(id: image.id)
        let at = { (row: Int) in Images.Placement(image: image, row: row, column: 2, columns: 10, rows: 5) }

        let frame1 = service.commands([at(3)])
        XCTAssertTrue(frame1.contains("a=t,f=100,t=d,i=500"))
        XCTAssertTrue(frame1.contains(KittyGraphics.place(id: 500, row: 3, column: 2, columns: 10, rows: 5)))
        XCTAssertFalse(frame1.contains("a=d"))

        XCTAssertEqual(service.commands([at(3)]), "")

        let frame3 = service.commands([at(4)])
        XCTAssertFalse(frame3.contains("a=t"))
        let place = KittyGraphics.place(id: 500, row: 4, column: 2, columns: 10, rows: 5)
        XCTAssertEqual(frame3, delete + place)

        // Same row, resized: also a move.
        let resized = Images.Placement(image: image, row: 4, column: 2, columns: 8, rows: 4)
        XCTAssertEqual(service.commands([resized]),
                       delete + KittyGraphics.place(id: 500, row: 4, column: 2, columns: 8, rows: 4))

        XCTAssertEqual(service.commands([]), delete)
        XCTAssertEqual(service.commands([]), "")
    }

    func testDeleteUsesIdsNotDeleteAll() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = directory.appendingPathComponent("agent/fixtures/sample.png").path
        let file = NSTemporaryDirectory() + "images-delete-\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: file) }
        try "before\n![alt](\(path))\nafter\n".write(toFile: file, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: file)
        state.sidebarMode = .off
        state.document.cursorLine = 0
        let app = EditorApp(states: [state], images: Images(idBase: 2_000_000))
        app.inlineImagesEnabledForTest = true
        let first = app.renderOutputForTest(width: 80, height: 30)
        XCTAssertTrue(first.contains("a=p,i=2000000"))
        XCTAssertFalse(first.contains("a=d,d=a"))
        let second = app.renderOutputForTest(width: 80, height: 30)
        XCTAssertFalse(second.contains("a=d,d=a"))
        XCTAssertFalse(second.contains("a=p"))
        state.document.cursorLine = 1
        let revealed = app.renderOutputForTest(width: 80, height: 30)
        XCTAssertFalse(revealed.contains("a=d,d=a"))
        XCTAssertTrue(revealed.contains(KittyGraphics.deleteImage(id: 2_000_000)))
    }

    func testExpandedRowsMapMouseAndScroll() throws {
        let file = NSTemporaryDirectory() + "images-scroll-\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: file) }
        try "before\nimage\nafter\nlast".write(toFile: file, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: file)
        state.wordWrap = true
        state.scrollMargin = 0
        state.scrollPastEnd = false
        state.setImageRowCounts([1: 8])
        state.document.cursorLine = 3
        state.adjustScroll(viewportHeight: 5, viewportWidth: 80)
        XCTAssertEqual(state.scrollOffset, 6)
        state.scrollOffset = 0
        state.mousePress(row: 5, col: 2, viewportWidth: 80)
        XCTAssertEqual(state.document.cursorLine, 1)
        state.document.clearSelection()
        state.wordWrap = false
        state.document.cursorLine = 3
        state.adjustScroll(viewportHeight: 5, viewportWidth: 80)
        XCTAssertEqual(state.scrollOffset, 6)
    }

    func testMermaidHelperAsyncCacheAndUnsupportedFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cache = NSTemporaryDirectory() + "images-cache-\(UUID().uuidString)"
        let oldHelper = ProcessInfo.processInfo.environment["EDITXR_MERMAID_PNG"]
        let oldCache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
        setenv("EDITXR_MERMAID_PNG", root.appendingPathComponent("agent/stub-mermaid-png.sh").path, 1)
        setenv("XDG_CACHE_HOME", cache, 1)
        defer {
            if let old = oldHelper { setenv("EDITXR_MERMAID_PNG", old, 1) } else { unsetenv("EDITXR_MERMAID_PNG") }
            if let old = oldCache { setenv("XDG_CACHE_HOME", old, 1) } else { unsetenv("XDG_CACHE_HOME") }
            try? FileManager.default.removeItem(atPath: cache)
        }
        let service = Images()
        let block = InlineImages.Block(range: 1...3, source: "graph TD; A-->B", mermaid: true)
        let complete = expectation(description: "PNG asynchronously ready")
        service.onChange = { complete.fulfill() }
        service.onError = { XCTFail($0) }
        XCTAssertNil(service.image(for: block, documentPath: "sample.md", theme: "dark"))
        wait(for: [complete], timeout: 5)
        XCTAssertNotNil(service.image(for: block, documentPath: "sample.md", theme: "dark"))
        let key = InlineImages.cacheKey(theme: "dark", scale: service.scale, source: block.source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache + "/editxr/mermaid/\(key).png"))
        let unsupported = InlineImages.Block(range: 1...3, source: "pie title Example", mermaid: true)
        let fallback = expectation(description: "unsupported falls back silently")
        service.onChange = { fallback.fulfill() }
        XCTAssertNil(service.image(for: unsupported, documentPath: "sample.md", theme: "dark"))
        wait(for: [fallback], timeout: 5)
        XCTAssertNil(service.image(for: unsupported, documentPath: "sample.md", theme: "dark"))
    }

    func testSizingPreservesAspectAndFits() {
        let size = ImagePNG(data: Data(), width: 800, height: 400).cellSize(width: 40, height: 20, maxRows: 12, cell: (8, 16))
        XCTAssertEqual(size.columns, 40)
        XCTAssertEqual(size.rows, 10)
    }
}
