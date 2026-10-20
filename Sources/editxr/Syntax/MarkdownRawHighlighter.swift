import Foundation

/// What a run of raw markdown text is, for colouring the raw (unrendered) view.
enum RawKind {
    case headingMark   // the leading "#"s of an ATX heading
    case headingText   // the heading's text after "# "
    case emphasisMark  // "**" / "*" around bold and italic text
    case inlineCode    // `code`, backticks included
    case fenceMark     // a ``` fence line (opening or closing, info string included)
    case codeLine      // a line inside a fenced code block
    case linkText      // "[text]" of an inline link, or a whole [[wikilink]]
    case linkUrl       // "(url)" of an inline link
    case listMark      // "-", "*", "+", "1.", "1)"
    case taskBox       // "[ ]" / "[x]" after a list marker
    case quoteMark     // each ">" of a blockquote prefix
    case rule          // a thematic break: ---, ***, ___
    case plain
}

/// A styled run on one line. Offsets are `Character` offsets into the line,
/// `start` inclusive, `end` exclusive. (Shadows the stdlib's `Swift.RawSpan`
/// inside this module.)
struct RawSpan: Equatable {
    let start: Int
    let end: Int
    let kind: RawKind
}

/// Line-based markdown highlighter for the raw view. Feed it every line of the
/// document in order (from line 0) so `inFence` tracks fenced code blocks.
///
/// Returned spans are sorted and non-overlapping; gaps between them are plain
/// text and are not emitted.
struct MarkdownRawHighlighter {
    /// True while inside a ``` fenced code block.
    var inFence = false

    /// Advance fence state past `line` without computing spans — the cheap
    /// path for lines above the viewport.
    mutating func advance(past line: String) {
        if MarkdownLineParser.isCodeBlockDelimiter(line) { inFence.toggle() }
    }

    mutating func spans(for line: String) -> [RawSpan] {
        let chars = Array(line)
        let n = chars.count

        if MarkdownLineParser.isCodeBlockDelimiter(line) {
            inFence.toggle()
            return [RawSpan(start: 0, end: n, kind: .fenceMark)]
        }
        if inFence {
            return n > 0 ? [RawSpan(start: 0, end: n, kind: .codeLine)] : []
        }

        if let heading = Self.heading(chars) { return heading }
        if Self.isRule(chars) { return [RawSpan(start: 0, end: n, kind: .rule)] }

        var out: [RawSpan] = []
        var i = 0

        // Blockquote prefix: "> > ", each ">" marked.
        while true {
            var j = i
            while j < n && chars[j] == " " { j += 1 }
            guard j < n, chars[j] == ">" else { break }
            out.append(RawSpan(start: j, end: j + 1, kind: .quoteMark))
            i = j + 1
            if i < n && chars[i] == " " { i += 1 }
        }

        // List marker, then an optional task box.
        var j = i
        while j < n && (chars[j] == " " || chars[j] == "\t") { j += 1 }
        if let markEnd = Self.listMarkerEnd(chars, at: j) {
            out.append(RawSpan(start: j, end: markEnd, kind: .listMark))
            i = markEnd
            if i < n && chars[i] == " " { i += 1 }
            if i + 2 < n, chars[i] == "[", chars[i + 2] == "]",
               chars[i + 1] == " " || chars[i + 1] == "x" || chars[i + 1] == "X",
               i + 3 == n || chars[i + 3] == " " {
                out.append(RawSpan(start: i, end: i + 3, kind: .taskBox))
                i += 3
            }
        }

        out += Self.inline(chars, from: i)
        return out
    }

    /// Theme style for a kind. Mapping (Theme tokens only):
    /// - headingMark  -> textMuted      (the "#"s recede)
    /// - headingText  -> heading1       (bold accent)
    /// - emphasisMark -> textMuted
    /// - inlineCode   -> string         (same colour as code in the rendered view)
    /// - fenceMark    -> textMuted
    /// - codeLine     -> codeBlock
    /// - linkText     -> accent
    /// - linkUrl      -> textSecondary
    /// - listMark     -> accent
    /// - taskBox      -> accent
    /// - quoteMark    -> textMuted
    /// - rule         -> textMuted
    /// - plain        -> textPrimary
    static func style(_ kind: RawKind) -> String {
        switch kind {
        case .headingMark: return Theme.textMuted
        case .headingText: return Theme.heading1
        case .emphasisMark: return Theme.textMuted
        case .inlineCode: return Theme.string
        case .fenceMark: return Theme.textMuted
        case .codeLine: return Theme.codeBlock
        case .linkText: return Theme.accent
        case .linkUrl: return Theme.textSecondary
        case .listMark: return Theme.accent
        case .taskBox: return Theme.accent
        case .quoteMark: return Theme.textMuted
        case .rule: return Theme.textMuted
        case .plain: return Theme.textPrimary
        }
    }

    // MARK: - Block constructs

    /// ATX heading: 1-6 "#" then a space (or end of line).
    private static func heading(_ chars: [Character]) -> [RawSpan]? {
        var level = 0
        while level < chars.count && chars[level] == "#" { level += 1 }
        guard (1...6).contains(level) else { return nil }
        if level == chars.count { return [RawSpan(start: 0, end: level, kind: .headingMark)] }
        guard chars[level] == " " else { return nil }
        var out = [RawSpan(start: 0, end: level, kind: .headingMark)]
        if level + 1 < chars.count {
            out.append(RawSpan(start: level + 1, end: chars.count, kind: .headingText))
        }
        return out
    }

    /// Thematic break: 3+ of the same "-", "*" or "_", spaces allowed.
    private static func isRule(_ chars: [Character]) -> Bool {
        let marks = chars.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// End offset of a list marker starting at `j` ("-", "*", "+", or digits
    /// followed by "." / ")"), which must be followed by a space or the end.
    private static func listMarkerEnd(_ chars: [Character], at j: Int) -> Int? {
        let n = chars.count
        guard j < n else { return nil }
        var end: Int
        if chars[j] == "-" || chars[j] == "*" || chars[j] == "+" {
            end = j + 1
        } else {
            var k = j
            while k < n && k - j < 9 && chars[k].isASCII && chars[k].isNumber { k += 1 }
            guard k > j, k < n, chars[k] == "." || chars[k] == ")" else { return nil }
            end = k + 1
        }
        guard end == n || chars[end] == " " || chars[end] == "\t" else { return nil }
        return end
    }

    // MARK: - Inline constructs

    /// Inline spans of `chars[from...]` via `MarkdownLineParser.parseInline`, shifted back
    /// to line offsets.
    private static func inline(_ chars: [Character], from: Int) -> [RawSpan] {
        guard from < chars.count else { return [] }
        let rest = String(chars[from...])
        var out: [RawSpan] = []
        // Inline-only: a list/quote remainder starting with "# " must not be
        // swallowed by heading detection.
        let base = from
        for sp in MarkdownLineParser.parseInline(rest).sorted(by: { $0.rawStart < $1.rawStart }) {
            let rs = base + sp.rawStart, re = base + sp.rawEnd
            let cs = base + sp.contentStart, ce = base + sp.contentEnd
            switch sp.kind {
            case .bold, .italic:
                out.append(RawSpan(start: rs, end: cs, kind: .emphasisMark))
                out.append(RawSpan(start: ce, end: re, kind: .emphasisMark))
            case .code:
                out.append(RawSpan(start: rs, end: re, kind: .inlineCode))
            case .link:
                if rs + 1 < chars.count && chars[rs + 1] == "[" {
                    out.append(RawSpan(start: rs, end: re, kind: .linkText))      // [[wiki]]
                } else {
                    out.append(RawSpan(start: rs, end: ce + 1, kind: .linkText))  // [text]
                    out.append(RawSpan(start: ce + 1, end: re, kind: .linkUrl))   // (url)
                }
            case .heading1, .heading2, .heading3:
                continue   // parseInline never produces headings
            }
        }
        return out
    }
}
