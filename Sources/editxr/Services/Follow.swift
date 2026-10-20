import Foundation

/// `--follow=<mirror>`: run as a read-only preview of another editxr's
/// `--mirror=<mirror>` file. The preview reloads whenever the mirror or its
/// `<mirror>.cursor` sidecar changes and centres the editor's cursor line.
/// `--follow-base=<file>` names the real document, so relative image links
/// resolve against its folder instead of the mirror's.
struct Follow {
    static let flag = "--follow=", baseFlag = "--follow-base="

    let mirrorPath: String
    let basePath: String?

    /// How often the watcher stats the two files.
    static let pollInterval: TimeInterval = 0.05

    /// The follow request in `arguments`, or nil without a non-empty
    /// `--follow=<path>`. An empty `--follow-base=` is ignored.
    static func parse(_ arguments: [String]) -> Follow? {
        func value(_ prefix: String) -> String? {
            guard let arg = arguments.dropFirst().last(where: { $0.hasPrefix(prefix) }) else { return nil }
            let v = String(arg.dropFirst(prefix.count))
            return v.isEmpty ? nil : v
        }
        guard let mirror = value(flag) else { return nil }
        return Follow(mirrorPath: mirror, basePath: value(baseFlag))
    }

    /// Call `onChange` on the main queue whenever the mirror or the cursor
    /// sidecar is created, replaced, rewritten or removed. Polls the two
    /// files' identity (inode, size, mtime) every 50 ms on a background queue:
    /// portable (no kqueue/inotify split) and it coalesces a burst of writes
    /// that lands inside one tick into one call. The editor writes the mirror
    /// then the sidecar, so a second call a tick later is expected.
    /// Watching stops when the returned token is released.
    func watch(onChange: @escaping () -> Void) -> AnyObject {
        FollowWatch(paths: [mirrorPath, Mirror.cursorPath(for: mirrorPath)],
                    interval: Self.pollInterval, onChange: onChange)
    }
}

/// The polling timer behind `Follow.watch`; cancelled on deinit.
private final class FollowWatch {
    private let timer: DispatchSourceTimer

    init(paths: [String], interval: TimeInterval, onChange: @escaping () -> Void) {
        let queue = DispatchQueue(label: "editxr.follow", qos: .userInitiated)
        timer = DispatchSource.makeTimerSource(queue: queue)
        var last = paths.map(Self.stamp)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler {
            let now = paths.map(Self.stamp)
            guard now != last else { return }
            last = now
            DispatchQueue.main.async(execute: onChange)
        }
        timer.resume()
    }

    deinit { timer.cancel() }

    /// What identifies one version of a file: an atomic replace changes the
    /// inode, an in-place write the size or mtime. Nil while it doesn't exist.
    private static func stamp(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(inode):\(size):\(mtime)"
    }
}
