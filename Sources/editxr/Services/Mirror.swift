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

    /// Write the buffer (exactly what Save would write) when it changed since
    /// the last write. Returns whether it wrote.
    @discardableResult
    func update() -> Bool {
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
