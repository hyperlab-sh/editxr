import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `--mirror=<path>`: keeps `<path>` equal to one document's buffer, saved or
/// not, so another program (a live preview, a diff) can follow unsaved edits.
/// SIGUSR1 saves that document, so the same program can save without typing
/// into the editor.
final class Mirror {
    static let flag = "--mirror="

    let path: String
    let state: EditorState
    private var written: String?
    private var writtenCursor: Int?
    private var saveSignal: AnyObject?

    init(path: String, state: EditorState) {
        self.path = path
        self.state = state
    }

    /// The `--mirror=<path>` value, if any. A bare or empty flag is ignored.
    static func path(in arguments: [String]) -> String? {
        for arg in arguments.dropFirst() where arg.hasPrefix(flag) {
            let value = String(arg.dropFirst(flag.count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Sidecar holding the 0-based cursor line, next to the mirror.
    static func cursorPath(for path: String) -> String { path + ".cursor" }

    /// The cursor line stored at `path`; nil when missing, empty or not a number.
    static func readCursor(at path: String) -> Int? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Write the buffer (exactly what Save would write) when it changed since
    /// the last write, and the cursor line to the sidecar when it changed.
    /// Returns whether the buffer was written.
    @discardableResult
    func update() -> Bool {
        defer { updateCursor() }
        let content = state.document.content
        guard content != written else { return false }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            written = content
            return true
        } catch {
            // Not fatal: the next change retries; the editor must keep working.
            return false
        }
    }

    private func updateCursor() {
        let line = state.document.cursorLine
        guard line != writtenCursor else { return }
        do {
            try "\(line)\n".write(
                toFile: Self.cursorPath(for: path), atomically: true, encoding: .utf8)
            writtenCursor = line
        } catch {
            // Retried on the next update.
        }
    }

    /// Run `onSave` on the main queue whenever the process gets SIGUSR1.
    func watchSaveSignal(_ onSave: @escaping () -> Void) {
        #if !os(Windows)
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler(handler: onSave)
        source.resume()
        saveSignal = source as AnyObject
        #endif
    }
}
