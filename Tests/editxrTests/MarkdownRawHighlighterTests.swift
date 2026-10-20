import XCTest
@testable import editxr

/// Raw-view markdown highlighting: span lists (no colours) for the highlighter,
/// plus render checks that the raw renderers actually apply them.
final class MarkdownRawHighlighterTests: XCTestCase {

    /// Non-plain spans for one line through a fresh highlighter.
    private func spans(_ line: String) -> [RawSpan] {
        var hl = MarkdownRawHighlighter()
        return hl.spans(for: line).filter { $0.kind != .plain }
    }

    private func s(_ start: Int, _ end: Int, _ kind: RawKind) -> RawSpan {
        RawSpan(start: start, end: end, kind: kind)
    }

    private func makeApp(_ content: String, cursorLine: Int, wordWrap: Bool) -> EditorApp {
        let tmp = NSTemporaryDirectory() + "editxr-raw-\(UUID().uuidString).md"
        try? content.write(toFile: tmp, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: tmp)
        state.viewMode = .raw
        state.wordWrap = wordWrap
        state.blockMode = false
        state.document.cursorLine = max(0, min(cursorLine, state.document.lines.count - 1))
        state.document.cursorColumn = 0
        return EditorApp(states: [state])
    }

    /// Rendered editor row whose visible text contains `needle`.
    private func row(_ rows: [String], containing needle: String) -> String? {
        rows.first { RenderTests.plain($0).contains(needle) }
    }

    // MARK: - Highlighter spans

    func testHeadingSplitsMarkAndText() {
        XCTAssertEqual(spans("# Title"), [s(0, 1, .headingMark), s(2, 7, .headingText)])
        XCTAssertEqual(spans("### Deep"), [s(0, 3, .headingMark), s(4, 8, .headingText)])
        XCTAssertEqual(spans("###### Six"), [s(0, 6, .headingMark), s(7, 10, .headingText)])
        XCTAssertEqual(spans("#"), [s(0, 1, .headingMark)], "bare marker is still a heading mark")
        XCTAssertEqual(spans("#nospace"), [], "no space -> not a heading")
        XCTAssertEqual(spans("####### seven"), [], "more than six hashes is not a heading")
    }

    func testFenceTogglesAndCodeLinesAreMarked() {
        var hl = MarkdownRawHighlighter()
        XCTAssertFalse(hl.inFence)
        XCTAssertEqual(hl.spans(for: "```swift"), [s(0, 8, .fenceMark)])
        XCTAssertTrue(hl.inFence)
        // Markdown syntax inside a fence is code, not a heading or emphasis.
        XCTAssertEqual(hl.spans(for: "# not a heading *x*"), [s(0, 19, .codeLine)])
        XCTAssertEqual(hl.spans(for: ""), [], "empty code line has no span")
        XCTAssertEqual(hl.spans(for: "  ```"), [s(0, 5, .fenceMark)])
        XCTAssertFalse(hl.inFence)
        XCTAssertEqual(hl.spans(for: "# back"), [s(0, 1, .headingMark), s(2, 6, .headingText)])
    }

    func testInlineCodeAndEmphasisMarks() {
        // "a `b` **c** *d*"
        //  0123456789012345
        XCTAssertEqual(spans("a `b` **c** *d*"), [
            s(2, 5, .inlineCode),
            s(6, 8, .emphasisMark), s(9, 11, .emphasisMark),
            s(12, 13, .emphasisMark), s(14, 15, .emphasisMark),
        ])
        XCTAssertEqual(spans("unclosed `code and **bold"), [])
    }

    func testLinksAndWikilinks() {
        // "[t](u)" -> "[t]" is link text, "(u)" is the url
        XCTAssertEqual(spans("[t](u)"), [s(0, 3, .linkText), s(3, 6, .linkUrl)])
        XCTAssertEqual(spans("see [[n]]"), [s(4, 9, .linkText)])
        XCTAssertEqual(spans("[[Note|alias]]"), [s(0, 14, .linkText)])
        XCTAssertEqual(spans("x [ab](http://e) y"), [s(2, 6, .linkText), s(6, 16, .linkUrl)])
    }

    func testListMarkersAndTaskBoxes() {
        XCTAssertEqual(spans("- [ ] x"), [s(0, 1, .listMark), s(2, 5, .taskBox)])
        XCTAssertEqual(spans("- [x] done"), [s(0, 1, .listMark), s(2, 5, .taskBox)])
        XCTAssertEqual(spans("1. x"), [s(0, 2, .listMark)])
        XCTAssertEqual(spans("12) x"), [s(0, 3, .listMark)])
        XCTAssertEqual(spans("  * nested"), [s(2, 3, .listMark)])
        XCTAssertEqual(spans("+ `c`"), [s(0, 1, .listMark), s(2, 5, .inlineCode)])
        XCTAssertEqual(spans("-not a list"), [])
        XCTAssertEqual(spans("**bold** start"), [s(0, 2, .emphasisMark), s(6, 8, .emphasisMark)],
                       "a leading ** is emphasis, not a list marker")
    }

    func testQuoteAndRule() {
        XCTAssertEqual(spans("> q"), [s(0, 1, .quoteMark)])
        XCTAssertEqual(spans("> > *q*"), [s(0, 1, .quoteMark), s(2, 3, .quoteMark),
                                         s(4, 5, .emphasisMark), s(6, 7, .emphasisMark)])
        XCTAssertEqual(spans("> - item"), [s(0, 1, .quoteMark), s(2, 3, .listMark)])
        XCTAssertEqual(spans("---"), [s(0, 3, .rule)])
        XCTAssertEqual(spans("* * *"), [s(0, 5, .rule)])
        XCTAssertEqual(spans("___"), [s(0, 3, .rule)])
        XCTAssertEqual(spans("--"), [], "two dashes are not a rule")
    }

    func testSpansAreSortedAndNonOverlapping() {
        var hl = MarkdownRawHighlighter()
        for line in ["> - [ ] **a** `b` [c](d) [[e]] *f*", "# h", "1. [x] *i*", "plain"] {
            let out = hl.spans(for: line)
            for (a, b) in zip(out, out.dropFirst()) {
                XCTAssertLessThanOrEqual(a.end, b.start, "overlap in \(line): \(out)")
            }
            for sp in out {
                XCTAssertLessThan(sp.start, sp.end)
                XCTAssertLessThanOrEqual(sp.end, line.count)
            }
        }
    }

    // MARK: - Renderer wiring

    // The cursor sits on line 0 so the render does not scroll the rows under
    // test out of view.
    func testRawModeRendersStyledLines() {
        let app = makeApp("cursor here\n# T\nbody `x`", cursorLine: 0, wordWrap: false)
        let rows = app.renderEditorLinesForTest(width: 60, height: 10)
        let heading = row(rows, containing: "# T")
        XCTAssertNotNil(heading)
        XCTAssertTrue(heading?.contains(Theme.heading1) ?? false, "heading text styled with heading1")
        XCTAssertTrue(heading?.contains("# T") == false, "mark and text are styled separately")
        let body = row(rows, containing: "body")
        XCTAssertTrue(body?.contains(Theme.string + "`x`") ?? false, "inline code styled")
        // Cursor line keeps renderLineRaw: no markdown styling applied.
        let cursor = row(rows, containing: "ursor here")
        XCTAssertNotNil(cursor)
        XCTAssertFalse(cursor?.contains(Theme.textPrimary + "ursor") ?? true)
    }

    func testRawModeWrappedStylesBothFragments() {
        // A heading long enough to wrap at width 30: both rows carry heading1.
        let app = makeApp("cursor\n# aaaa bbbb cccc dddd eeee ffff", cursorLine: 0, wordWrap: true)
        let rows = app.renderEditorLinesForTest(width: 30, height: 10)
        let first = row(rows, containing: "aaaa")
        let second = row(rows, containing: "ffff")
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "heading must wrap for this test")
        XCTAssertTrue(first?.contains(Theme.heading1) ?? false)
        XCTAssertTrue(second?.contains(Theme.heading1) ?? false)
    }

    func testFenceOpenedAboveViewportStillMarksCode() {
        // Fence opens on line 0; scroll so it is off-screen. "# inside" must be
        // code, not a heading.
        var lines = ["```"]
        for i in 0..<30 { lines.append("code \(i)") }
        lines.append("# inside")
        lines.append("```")
        lines.append("cursor")
        for wrap in [false, true] {
            let app = makeApp(lines.joined(separator: "\n"), cursorLine: lines.count - 1, wordWrap: wrap)
            app.statesForTest[0].scrollOffset = 25
            let rows = app.renderEditorLinesForTest(width: 60, height: 12)
            XCTAssertNil(row(rows, containing: "code 0"), "opening fence must be above the viewport (wrap=\(wrap))")
            let inside = row(rows, containing: "# inside")
            XCTAssertNotNil(inside, "wrap=\(wrap)")
            XCTAssertTrue(inside?.contains(Theme.codeBlock + "# inside") ?? false, "wrap=\(wrap)")
            XCTAssertFalse(inside?.contains(Theme.heading1) ?? true, "wrap=\(wrap)")
        }
    }
}
