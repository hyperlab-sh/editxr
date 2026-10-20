import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum KittyGraphics {
    /// Deletes the placements of one image id only (lowercase i keeps its data),
    /// so a second editxr instance sharing the terminal keeps its own images.
    static func deleteImage(id: UInt32) -> String {
        "\u{1B}_Ga=d,d=i,i=\(id),q=2\u{1B}\\"
    }

    /// Deletes one image id's placements and frees its data (uppercase I), so
    /// exiting never frees another instance's images.
    static func freeImage(id: UInt32) -> String {
        "\u{1B}_Ga=d,d=I,i=\(id),q=2\u{1B}\\"
    }

    static func supported(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let program = environment["TERM_PROGRAM", default: ""].lowercased()
        return ["kitty", "wezterm", "ghostty"].contains(program)
            || environment["KITTY_WINDOW_ID"] != nil
            || environment["WEZTERM_EXECUTABLE"] != nil
            || environment["GHOSTTY_RESOURCES_DIR"] != nil
            || environment["TERM"] == "xterm-kitty"
    }

    static func transmit(_ png: Data, id: UInt32) -> String {
        let bytes = Array(png.base64EncodedString().utf8)
        var output = ""
        for offset in stride(from: 0, to: bytes.count, by: 4096) {
            let end = min(offset + 4096, bytes.count)
            let prefix = offset == 0 ? "a=t,f=100,t=d,i=\(id),q=2," : ""
            output += "\u{1B}_G\(prefix)m=\(end < bytes.count ? 1 : 0);"
                + String(decoding: bytes[offset..<end], as: UTF8.self) + "\u{1B}\\"
        }
        return output
    }

    /// Re-sending the same `i`+`p` replaces that placement in place (no flicker).
    /// `crop` shows only a horizontal band of the source image (`y`/`h` in
    /// source pixels) in the `columns`×`rows` cell rectangle, for an image
    /// partly scrolled out of view.
    static func place(id: UInt32, placement: Int, row: Int, column: Int, columns: Int, rows: Int,
                      crop: (y: Int, height: Int)? = nil) -> String {
        let source = crop.map { ",y=\($0.y),h=\($0.height)" } ?? ""
        // C=1 prevents the placement moving the terminal cursor.
        return "\u{1B}[\(row);\(column)H\u{1B}_Ga=p,i=\(id),p=\(placement),c=\(columns),r=\(rows)\(source),C=1,q=2\u{1B}\\"
    }

    static func cellPixels() -> (Double, Double) {
        #if !os(Windows)
        var size = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0,
           size.ws_col > 0, size.ws_row > 0, size.ws_xpixel > 0, size.ws_ypixel > 0 {
            return (Double(size.ws_xpixel) / Double(size.ws_col), Double(size.ws_ypixel) / Double(size.ws_row))
        }
        #endif
        return (8, 16)
    }
}
