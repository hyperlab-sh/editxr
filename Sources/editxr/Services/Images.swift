import Foundation

/// Fork-only, opt-out inline graphics. No terminal probing or helper work on unsupported terminals.
enum InlineImages {
    static var enabled: Bool = !CommandLine.arguments.contains("--no-images")
        && Config.load().images != false && KittyGraphics.supported()

    struct Block {
        let range: ClosedRange<Int>
        let source: String
        let mermaid: Bool
    }

    static func blocks(lines: [String], cursorLine: Int) -> [Block] {
        var result: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = line.first!
                let count = line.prefix(while: { $0 == marker }).count
                let info = line.dropFirst(count).trimmingCharacters(in: .whitespaces)
                let start = index
                index += 1
                while index < lines.count {
                    let closing = lines[index].trimmingCharacters(in: .whitespaces)
                    if closing.prefix(while: { $0 == marker }).count >= count,
                       closing.allSatisfy({ $0 == marker }) { break }
                    index += 1
                }
                if index < lines.count, info == "mermaid", !(start...index).contains(cursorLine) {
                    result.append(Block(range: start...index,
                                        source: lines[(start + 1)..<index].joined(separator: "\n"), mermaid: true))
                }
            } else if index != cursorLine, line.hasPrefix("!["),
                      let split = line.range(of: "]("), line.hasSuffix(")") {
                var path = String(line[split.upperBound..<line.index(before: line.endIndex)])
                if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
                path = path.removingPercentEncoding ?? path
                if !path.contains("://"), path.lowercased().hasSuffix(".png") {
                    result.append(Block(range: index...index, source: path, mermaid: false))
                }
            }
            index += 1
        }
        return result
    }

    static func cacheKey(theme: String, scale: Int, source: String) -> String {
        ImageSHA256.hex(Data("\(theme)\u{0}\(scale)\u{0}\(source)".utf8))
    }
}

struct ImagePNG {
    let data: Data
    let width: Int
    let height: Int

    init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 33, Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              String(decoding: bytes[12..<16], as: UTF8.self) == "IHDR" else { return nil }
        func uint32(_ offset: Int) -> Int {
            bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let w = uint32(16), h = uint32(20)
        guard w > 0, h > 0, w <= 100000, h <= 100000 else { return nil }
        self.init(data: data, width: w, height: h)
    }

    func cellSize(width columns: Int, height rows: Int, maxRows: Int, cell: (Double, Double)) -> (columns: Int, rows: Int) {
        let scale = min(Double(max(1, columns)) * cell.0 / Double(width),
                        Double(max(1, min(rows, maxRows))) * cell.1 / Double(height))
        return (max(1, min(columns, Int(ceil(Double(width) * scale / cell.0)))),
                max(1, min(rows, min(maxRows, Int(ceil(Double(height) * scale / cell.1))))))
    }
}

/// Main-queue-owned service; only helper IO and cache writes run on the worker.
final class Images {
    struct Ready {
        let png: ImagePNG
        let id: UInt32
    }
    struct Placement {
        let image: Ready
        let row: Int
        let column: Int
        let columns: Int
        let rows: Int
    }
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "editxr.images", qos: .userInitiated)
    private var ready: [String: Ready] = [:]
    private var localFiles: [String: (stamp: String, image: Ready)] = [:]
    private var pending: Set<String> = []
    private var failed: Set<String> = []
    private var transmitted: Set<UInt32> = []
    /// What the terminal currently shows, by image id; `commands` emits only the delta.
    private var placed: [UInt32: (row: Int, column: Int, columns: Int, rows: Int)] = [:]
    private let idBase: UInt32
    private var nextID: UInt32
    private let config = Config.load()
    var maxRows: Int { max(1, min(100, config.imageMaxRows ?? 12)) }
    var scale: Int { max(1, min(4, config.imageScale ?? 2)) }

    /// `--image-id-base=<n>`: a second instance sharing the terminal (follow
    /// preview) starts its Kitty image ids elsewhere so the two never collide.
    static let imageIdBaseFlag = "--image-id-base="

    /// The id base from `arguments`, or nil when absent or invalid (0 is not a
    /// usable Kitty id).
    static func idBase(in arguments: [String]) -> UInt32? {
        guard let argument = arguments.last(where: { $0.hasPrefix(imageIdBaseFlag) }),
              let value = UInt32(argument.dropFirst(imageIdBaseFlag.count)), value > 0 else { return nil }
        return value
    }

    init(idBase: UInt32 = 100) {
        self.idBase = idBase
        self.nextID = idBase
    }

    func image(for block: InlineImages.Block, documentPath: String, theme: String) -> Ready? {
        if !block.mermaid {
            let url = URL(fileURLWithPath: documentPath).deletingLastPathComponent()
                .appendingPathComponent(block.source).standardizedFileURL
            let resolved = block.source.hasPrefix("/") ? URL(fileURLWithPath: block.source) : url
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  let length = attributes[.size] as? NSNumber, length.intValue <= 32 * 1024 * 1024 else { return nil }
            let stamp = "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(length)"
            if let cached = localFiles[resolved.path], cached.stamp == stamp { return cached.image }
            guard let data = try? Data(contentsOf: resolved), let png = ImagePNG(data) else { return nil }
            let key = ImageSHA256.hex(data)
            let value = ready[key] ?? store(png, key: key)
            localFiles[resolved.path] = (stamp, value)
            return value
        }
        let key = InlineImages.cacheKey(theme: theme, scale: scale, source: block.source)
        if let cached = ready[key] { return cached }
        guard !pending.contains(key), !failed.contains(key) else { return nil }
        pending.insert(key)
        let scale = self.scale
        queue.async { [weak self] in
            let (png, error) = Self.rasterize(source: block.source, key: key, theme: theme, scale: scale)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pending.remove(key)
                if let png = png { _ = self.store(png, key: key) }
                else { self.failed.insert(key) }
                if let error = error { self.onError?(error) }
                self.onChange?()
            }
        }
        return nil
    }

    private func store(_ png: ImagePNG, key: String) -> Ready {
        let value = Ready(png: png, id: nextID)
        // Wrap (skipping the invalid id 0) instead of trapping near UInt32.max.
        nextID = nextID == .max ? idBase : nextID + 1
        ready[key] = value
        return value
    }

    /// Test seam: store a PNG under a fresh id without touching disk or the helper.
    func register(_ png: ImagePNG) -> Ready {
        store(png, key: "test:\(nextID)")
    }

    /// The Kitty commands that turn the previous frame's placements into these:
    /// per-id deletes for placements that vanished or moved, a one-time transmit
    /// for new ids, and a place for new or moved placements. Unchanged frames
    /// emit nothing. One placement per image id.
    func commands(_ placements: [Placement]) -> String {
        var next: [UInt32: (row: Int, column: Int, columns: Int, rows: Int)] = [:]
        for placement in placements {
            next[placement.image.id] = (placement.row, placement.column, placement.columns, placement.rows)
        }
        var output = ""
        for (id, old) in placed.sorted(by: { $0.key < $1.key }) where next[id].map({ $0 != old }) ?? true {
            output += KittyGraphics.deleteImage(id: id)
        }
        for placement in placements {
            let id = placement.image.id
            guard let spot = next[id], placed[id].map({ $0 != spot }) ?? true else { continue }
            if transmitted.insert(id).inserted {
                output += KittyGraphics.transmit(placement.image.png.data, id: id)
            }
            output += KittyGraphics.place(id: id, row: spot.row, column: spot.column,
                                          columns: spot.columns, rows: spot.rows)
            placed[id] = spot
        }
        placed = next
        return output
    }

    private static func rasterize(source: String, key: String, theme: String, scale: Int) -> (ImagePNG?, String?) {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CACHE_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache").path
        let directory = URL(fileURLWithPath: base).appendingPathComponent("editxr/mermaid")
        let file = directory.appendingPathComponent(key + ".png")
        if let data = try? Data(contentsOf: file), let png = ImagePNG(data) { return (png, nil) }
        #if os(Windows)
        return (nil, "Mermaid helper is unavailable on Windows")
        #else
        let process = Process()
        let helper = env["EDITXR_MERMAID_PNG"]
        process.executableURL = URL(fileURLWithPath: helper ?? "/usr/bin/env")
        process.arguments = (helper == nil ? ["mini-md-ide"] : []) + ["mermaid-png", "--theme", theme, "--scale", String(scale)]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // The UI reports a bounded, single-line message, never raw helper output.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Concurrent write avoids pipe deadlock for large diagrams/output.
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
                try? input.fileHandleForWriting.close()
            }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            if process.terminationStatus == 2 { return (nil, nil) }
            guard process.terminationStatus == 0, let png = ImagePNG(data) else {
                return (nil, "Mermaid image failed (helper exit \(process.terminationStatus))")
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return (png, nil)
        } catch {
            return (nil, "Mermaid image helper unavailable; showing source")
        }
        #endif
    }
}

/// Small portable SHA-256 implementation: no CryptoKit dependency on Linux.
private enum ImageSHA256 {
    static func hex(_ data: Data) -> String {
        let k: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var bytes = [UInt8](data)
        let bits = UInt64(bytes.count) * 8
        bytes.append(128)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                for j in 0..<4 { w[i] = (w[i] << 8) | UInt32(bytes[offset + i * 4 + j]) }
            }
            for i in 16..<64 {
                let x = w[i - 15], y = w[i - 2]
                w[i] = w[i - 16] &+ (rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)) &+ w[i - 7]
                    &+ (rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10))
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], v = h[7]
            for i in 0..<64 {
                let t1 = v &+ (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let t2 = (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                v = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            for (i, value) in [a,b,c,d,e,f,g,v].enumerated() { h[i] = h[i] &+ value }
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
