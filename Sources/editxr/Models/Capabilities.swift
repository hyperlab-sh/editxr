import Foundation

/// Why a `--capabilities=<file>` could not be applied. `description` is the
/// reason `main` prints as `editxr: capabilities <path>: <reason>`.
enum CapabilitiesError: Error, Equatable, CustomStringConvertible {
    /// The file could not be read (missing, unreadable, not UTF-8).
    case unreadable(String)
    /// A line that is not blank, a comment, or `<known key> = true|false`.
    /// `line` is 1-based.
    case invalid(line: Int)

    var description: String {
        switch self {
        case .unreadable(let path): return "cannot read \(path)"
        case .invalid(let line): return "invalid entry on line \(line)"
        }
    }
}

/// Editor features a host (e.g. a read-only preview plugin) can switch off for
/// one run with `--capabilities=<toml>`. Everything is on by default; the file
/// only ever narrows the editor. Nothing here is saved to the config.
struct Capabilities: Equatable {
    var sidebar = true, statusLine = true, tabs = true, ai = true, export = true, vault = true, quickOpen = true, focusMode = true

    static let flag = "--capabilities="

    /// A TOML subset: one `key = true|false` per line (snake_case keys), `#`
    /// comments (whole-line or trailing), and blank or whitespace-only lines.
    /// Unknown keys, other values (quoted, capitalised, numbers) and anything
    /// else throw `CapabilitiesError.invalid(line:)`.
    static func parse(_ text: String) throws -> Capabilities {
        var caps = Capabilities()
        let keys: [String: WritableKeyPath<Capabilities, Bool>] = [
            "sidebar": \.sidebar,
            "status_line": \.statusLine,
            "tabs": \.tabs,
            "ai": \.ai,
            "export": \.export,
            "vault": \.vault,
            "quick_open": \.quickOpen,
            "focus_mode": \.focusMode,
        ]
        // `isNewline` matches "\r\n" as one Character, so CRLF files keep the
        // same line numbers as LF ones.
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let parts = trimmed.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let key = keys[parts[0].trimmingCharacters(in: .whitespaces)] else {
                throw CapabilitiesError.invalid(line: index + 1)
            }
            switch parts[1].trimmingCharacters(in: .whitespaces) {
            case "true": caps[keyPath: key] = true
            case "false": caps[keyPath: key] = false
            default: throw CapabilitiesError.invalid(line: index + 1)
            }
        }
        return caps
    }

    /// Read and parse the file at `path`.
    static func load(path: String) throws -> Capabilities {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw CapabilitiesError.unreadable(path)
        }
        return try parse(text)
    }
}
