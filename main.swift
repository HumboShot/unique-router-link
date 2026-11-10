import AppKit

struct Rule: Decodable {
    let browser: String
    let hosts: [String]?
    let urlPrefixes: [String]?
    let sourceApps: [String]?
}

struct Config: Decodable {
    let defaultBrowser: String
    let rules: [Rule]
}

struct SourceApp {
    let bundleID: String?
    let name: String?

    var label: String { bundleID ?? name ?? "unknown" }

    init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }

    init?(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            self.init(bundleID: app.bundleIdentifier, name: app.localizedName)
            return
        }
        // Not a registered app, e.g. a helper process: fall back to its executable name.
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        self.init(bundleID: nil, name: URL(fileURLWithPath: String(cString: buffer)).lastPathComponent)
    }
}

let fallbackConfig = Config(defaultBrowser: "com.google.Chrome", rules: [])

let configURL: URL = {
    if let path = ProcessInfo.processInfo.environment["UNIQUE_ROUTER_LINK_CONFIG"] {
        return URL(fileURLWithPath: path)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/unique-router-link/rules.json")
}()

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/UniqueRouterLink.log")

// Records hosts only: full URLs often carry tokens.
func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: logURL)
    }
}

// Read on every link so edits apply without a restart.
func loadConfig() -> Config {
    do {
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
    } catch {
        log("config error, using \(fallbackConfig.defaultBrowser): \(error)")
        return fallbackConfig
    }
}

func hostMatches(_ host: String, _ pattern: String) -> Bool {
    let pattern = pattern.lowercased()
    return host == pattern || host.hasSuffix("." + pattern)
}

func stripWWW(_ value: String) -> String {
    value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
}

func prefixMatches(_ url: URL, _ prefix: String) -> Bool {
    var pattern = prefix.lowercased()
    for scheme in ["https://", "http://"] where pattern.hasPrefix(scheme) {
        pattern = String(pattern.dropFirst(scheme.count))
    }
    pattern = stripWWW(pattern)
    while pattern.hasSuffix("/") { pattern.removeLast() }

    let target = stripWWW(url.host?.lowercased() ?? "") + url.path.lowercased()
    return target == pattern || target.hasPrefix(pattern + "/")
}

func sourceMatches(_ source: SourceApp?, _ pattern: String) -> Bool {
    let pattern = pattern.lowercased()
    return source?.bundleID?.lowercased() == pattern || source?.name?.lowercased() == pattern
}

// First matching rule wins. Within a rule, any one match is enough.
func route(_ url: URL, from source: SourceApp?, config: Config) -> (browser: String, reason: String) {
    let host = url.host?.lowercased() ?? ""
    for rule in config.rules {
        if let hit = rule.sourceApps?.first(where: { sourceMatches(source, $0) }) {
            return (rule.browser, "sourceApp \(hit)")
        }
        if let hit = rule.urlPrefixes?.first(where: { prefixMatches(url, $0) }) {
            return (rule.browser, "urlPrefix \(hit)")
        }
        if let hit = rule.hosts?.first(where: { hostMatches(host, $0) }) {
            return (rule.browser, "host \(hit)")
        }
    }
    return (config.defaultBrowser, "default")
}

// Always opens with an explicit app. A plain NSWorkspace.open(url) would hand the
// link straight back to this router once it is the default browser, and loop.
func openLink(_ url: URL, from source: SourceApp?) {
    let config = loadConfig()
    let decision = route(url, from: source, config: config)
    let summary = "\(source?.label ?? "unknown") \(url.host ?? url.lastPathComponent) [\(decision.reason)]"

    let workspace = NSWorkspace.shared
    let candidates: [String] = [decision.browser, config.defaultBrowser]
        .filter { $0 != Bundle.main.bundleIdentifier }
    guard let browser = candidates.first(where: { workspace.urlForApplication(withBundleIdentifier: $0) != nil }),
          let appURL = workspace.urlForApplication(withBundleIdentifier: browser) else {
        log("\(summary) -> no installed browser among \(candidates)")
        NSSound.beep()
        return
    }

    workspace.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        log("\(summary) -> \(browser)" + (error.map { " FAILED: \($0.localizedDescription)" } ?? ""))
    }
}

final class Router: NSObject, NSApplicationDelegate {
    // Must be installed before launch finishes, or the link that launched the app is lost.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else {
            log("ignored unparseable URL event")
            return
        }
        let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        let source = pid.flatMap { SourceApp(pid: $0) }
        if source == nil { log("could not identify sender pid \(pid.map(String.init) ?? "none")") }
        openLink(url, from: source)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { openLink($0, from: nil) }
    }
}

// UniqueRouterLink --explain <url> [--from <app>] prints the decision without opening anything.
let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--explain" {
    guard let url = URL(string: arguments[2]) else {
        print("invalid URL: \(arguments[2])")
        exit(1)
    }
    var source: SourceApp?
    if arguments.count == 5, arguments[3] == "--from" {
        source = SourceApp(bundleID: arguments[4], name: arguments[4])
    }
    let decision = route(url, from: source, config: loadConfig())
    print("\(decision.browser) (\(decision.reason))")
    exit(0)
}

let router = Router()
NSApplication.shared.delegate = router
NSApplication.shared.run()
