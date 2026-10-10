import AppKit

/// Sift's side of the shared「配置与更新」layer (Shared/AppLifecycle*.swift, byte copies of swift-shared). This is the
/// one place that names the product, its release channel and its portable settings. The window
/// (`AppDelegate.installLifecycle`) and the commands `sift config status|export|import|sync` and
/// `sift update check|install` are both built from it, so they read and write one set of settings.
///
/// The `sift` CLI is the Rust binary in Contents/Resources/bin. These functions belong to the app bundle (its
/// preference domain, its version, its release channel), so the CLI starts this executable with the words after
/// `sift` and `main.swift` answers them here, before any NSApplication exists: no window, no Dock icon, no engine,
/// no index is opened. A Sift that is already running is left alone; it follows through `AppLifecycleCLI.follow`.
enum Lifecycle {
    static let name = "Sift"
    static let command = "sift"
    static let productID = "cyou.tianli.sift"
    /// The one release channel: the window's「检查更新」and `sift update check` both read it (packages iCloud Drive
    /// already downloaded to this Mac; the app is built without a network client, see build.sh).
    /// Kept as a labelled argument with the channel as a literal: Chapter finds a product's private channel by
    /// that spelling in its sources (app_sop.private_update_channel) and compares the feed with the installed build.
    static let updateSource = release(updateSource: .privateCloud(channel: "default"))
    private static func release(updateSource: AppUpdateSource) -> AppUpdateSource { updateSource }
    /// What travels with「导出配置…」and the optional iCloud copy: the window's three preferences and the index
    /// settings in config.json. Recent searches, the window frame, the login item and Full Disk Access stay per Mac.
    static let defaultsKeys = ["hotkey", "caseInsensitive", "showFolderScope"]
    static let fileKeys = ["root", "ignore_paths", "include_paths"]

    static let selfTestFlag = "--lifecycle-self-test"
    /// An isolated run is only accepted from a throwaway copy of the app whose bundle identifier starts with this:
    /// its standard preference domain is then a throwaway one, whatever the code under test reads or writes.
    static let isolatedBundlePrefix = "test.tianli.sift."
    static let refusal = "APP_LIFECYCLE_SUPPORT_DIR is set (an isolated run): it must run from a throwaway copy of Sift.app whose "
        + "bundle identifier starts with \(isolatedBundlePrefix) and with SIFT_SUPPORT_DIR naming a temporary folder "
        + "(scripts/accept/lifecycle.sh makes both), so the run never reaches the owner's own settings."

    /// Where the portable settings live: the app's own preference domain and its support folder.
    struct Store {
        let defaults: UserDefaults
        let supportDirectory: URL
    }

    static var isolated: Bool { ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"] != nil }

    /// The app and the command resolve the same store. With APP_LIFECYCLE_SUPPORT_DIR the shared layer keeps to its
    /// temporary support and "cloud" folders; the product's own two places must then be throwaway as well, or the
    /// run is refused (nil): never the owner's preference domain, never the owner's config.json.
    static func store(bundleID: String? = Bundle.main.bundleIdentifier,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> Store? {
        guard environment["APP_LIFECYCLE_SUPPORT_DIR"] != nil else {
            return Store(defaults: .standard, supportDirectory: AppDelegate.supportDirectory)
        }
        guard let bundleID, bundleID.hasPrefix(isolatedBundlePrefix), let folder = environment["SIFT_SUPPORT_DIR"], !folder.isEmpty else { return nil }
        return Store(defaults: .standard, supportDirectory: URL(fileURLWithPath: folder, isDirectory: true))
    }

    static func makeConfiguration(_ store: Store) -> AppConfiguration {
        AppConfiguration(productID: productID, defaultsKeys: defaultsKeys,
                         files: [AppConfigurationFile(url: store.supportDirectory.appendingPathComponent("config.json"), keys: fileKeys)],
                         defaults: store.defaults)
    }

    /// The portable values as they are stored right now (the export's own read), keyed as the export keys them:
    /// defaults.<key>, file.0.<key>. nil when they cannot be read (an invalid config.json).
    static func storedValues(_ configuration: AppConfiguration) -> [String: Any]? {
        guard let data = try? configuration.exportData(),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["values"] as? [String: Any]
    }
    static func same(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return NSDictionary(dictionary: a).isEqual(to: b)
        default: return false
        }
    }

    /// The .app this executable lives in, also when it was started through a symlink.
    static let hostBundle: Bundle = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return .main }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (app.pathExtension == "app" ? Bundle(url: app) : nil) ?? .main
    }()

    static func product(_ store: Store) -> AppLifecycleCLI.Product {
        var product = AppLifecycleCLI.Product(command: command, name: name, configuration: makeConfiguration(store), updateSource: updateSource)
        product.bundle = hostBundle
        // `sift update install`: a running Sift saves its index when it quits, which can take a while on a big one.
        product.quitTimeout = 45
        return product
    }

    // MARK: Command side

    /// `sift config status|export|import|sync …` and `sift update check`, as `main.swift` hands them over.
    /// `words` starts at the verb. The work is the shared layer's; this only keeps `sift`'s own conventions:
    /// with --json one JSON object on one line, a failure as {"ok":false,"error":"reason","exit":N} (plus the shared
    /// layer's `code` and `command`) with the reason also on stderr as `sift: reason`. Exit codes are the shared
    /// layer's: 0, 1 the operation did not complete, 2 usage or a missing --yes / --force.
    static func run(_ words: [String]) -> Int32 {
        let json = words.contains("--json")
        let command = words.prefix(2).filter { !$0.hasPrefix("-") }.joined(separator: " ")
        guard let store = store() else {
            return fail(["command": command, "code": "isolation_incomplete"], message: refusal, exit: 1, json: json)
        }
        var printed: [String] = []
        var product = product(store)
        if json { product.out = { printed.append($0) } }
        product.err = { complain($0) }
        let code = AppLifecycleCLI.run(words, product: product)
        guard json else { return code }
        let text = printed.joined(separator: "\n")
        guard var body = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            // Not an object (the help text): as it came.
            if !text.isEmpty { emit(text) }
            return code
        }
        guard let error = body.removeValue(forKey: "error") as? [String: Any] else {
            emit(line(body))
            return code
        }
        if let short = error["code"] { body["code"] = short }
        return fail(body, message: error["message"] as? String ?? "failed", exit: code, json: true)
    }

    private static func fail(_ fields: [String: Any], message: String, exit code: Int32, json: Bool) -> Int32 {
        if json {
            var body = fields
            body["ok"] = false; body["error"] = message; body["exit"] = Int(code)
            emit(line(body))
        }
        complain(message)
        return code
    }
    private static func line(_ body: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{\"ok\":false}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
    private static func emit(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    private static func complain(_ message: String) { FileHandle.standardError.write(Data(("sift: " + message + "\n").utf8)) }
}
