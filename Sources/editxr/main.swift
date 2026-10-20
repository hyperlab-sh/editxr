import Foundation

let arguments = CommandLine.arguments

if arguments.contains("--version") || arguments.contains("-v") {
    print("\(AppInfo.name) \(AppInfo.version)")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(AppInfo.helpText)
    exit(0)
}

// Diagnostic: ask the live terminal how wide each symbol renders and compare it
// to the built-in heuristic. Handy when a table looks misaligned on a terminal.
if arguments.contains("--probe-widths") {
    let symbols = ["★", "☆", "✓", "✔", "➡", "♻", "☀", "⚠", "⚠️", "✅", "⛔",
                   "⏰", "☑", "☐", "▶️", "❤️", "🎭", "你", "→", "—", "…"]
    PlatformTerminal.enableRawMode()
    let measured = PlatformTerminal.probeWidths(symbols)
    PlatformTerminal.disableRawMode()
    print("\u{1B}[H\u{1B}[2J", terminator: "")   // undo the probe's scratch draw
    print("symbol  measured  heuristic")
    for s in symbols {
        let m = measured[s].map(String.init) ?? "—"
        let h = s.first.map { displayWidth($0) } ?? 0
        print("  \(s)       \(m)         \(h)")
    }
    // Refresh the on-disk cache from this fresh run, so the flag doubles as
    // "re-calibrate" after changing a terminal setting that alters emoji width.
    var fresh: [Character: Int] = [:]
    for (s, w) in measured { if let c = s.first { fresh[c] = w } }
    registerMeasuredWidths(fresh)
    GlyphWidthCache.save()
    print("cache: \(GlyphWidthCache.path)")
    exit(0)
}

// --vault <path> pins the vault root for this run, overriding the config. Its
// value is a bare path, so it has to be pulled out before the file list is read.
// A bare `--vault` (no value) instead opens the configured vault.
var vaultArgIndex: Int?
if let i = arguments.firstIndex(of: "--vault"), i + 1 < arguments.count {
    Vault.commandLineRoot = Vault.standardized(arguments[i + 1])
    vaultArgIndex = i + 1
}

// Every non-flag argument is a file to open; the first one is focused. A
// positional argument that names a directory (e.g. `editxr .`) is not a file:
// it becomes the project root for this run, and the file-explorer sidebar
// opens on it (see LaunchArguments).
let launch = LaunchArguments.parse(arguments: arguments, vaultArgIndex: vaultArgIndex)
if let root = launch.directoryRoot {
    Vault.commandLineRoot = root
}

// A bare `--vault` opens the configured vault. Resolve it from the config here
// (the same precedence Vault uses) so `makeStates` can open its primary file;
// when nothing is configured the states stay empty and help is printed below.
var configuredVaultRoot: String?
if launch.openVault, let path = Config.load().vaultPath, !path.isEmpty {
    configuredVaultRoot = Vault.standardized(path)
}

// --capabilities=<toml> switches editor features off for this run. A file that
// can't be read or parsed is a hard error: silently running with everything on
// would defeat a host that relies on the gates (e.g. a read-only preview).
var capabilities = Capabilities()
if let path = launch.capabilitiesPath {
    do {
        capabilities = try Capabilities.load(path: path)
    } catch {
        FileHandle.standardError.write(Data("editxr: capabilities \(path): \(error)\n".utf8))
        exit(2)
    }
}

let states = LaunchArguments.makeStates(from: launch, vaultRoot: configuredVaultRoot,
                                        sidebarAllowed: capabilities.sidebar)
guard !states.isEmpty else {
    print(AppInfo.helpText)
    exit(1)
}

// --view=raw|rendered picks the starting view for this run only: ctrl+r still
// toggles it, but nothing is written to the saved preference.
if let view = launch.view {
    for st in states { st.viewMode = view; st.viewModePinned = true }
}

// --image-id-base=<n> lets a second instance (follow preview) share the
// terminal without colliding on Kitty image ids; invalid values are ignored.
let app = EditorApp(states: states, images: Images.idBase(in: arguments).map { Images(idBase: $0) } ?? Images())
if let path = Mirror.path(in: arguments) {
    app.mirror = Mirror(path: path, state: states[0])
}
app.capabilities = capabilities
app.start()
