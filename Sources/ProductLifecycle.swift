import AppKit
import SiftCore

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
    #if !APP_STORE
    static let updateSource = release(updateSource: .privateCloud(channel: "default"))
    private static func release(updateSource: AppUpdateSource) -> AppUpdateSource { updateSource }
    #endif
    /// What travels with「导出配置…」and the optional iCloud copy: the window's three preferences and the index
    /// settings in config.json. Recent searches, the window frame, the login item and Full Disk Access stay per Mac.
    static let defaultsKeys = ["hotkey", "shortcuts.v1", "caseInsensitive", "showFolderScope", "sortKey", "sortDescending", "savedSearches", "appUpdateOptions"]
    #if APP_STORE
    /// The Mac App Store build keeps the index root per Mac: it is the folder granted on this Mac (IndexAccess), and
    /// a root from an export or another Mac names a folder this Mac's sandbox was never given.
    static let fileKeys = ["ignore_paths", "include_paths"]
    #else
    static let fileKeys = ["root", "ignore_paths", "include_paths"]
    #endif

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
                         files: [AppConfigurationFile(url: store.supportDirectory.appendingPathComponent("config.json"), keys: fileKeys, validateField:validateIndexField),
                                 AppConfigurationFile(url: store.supportDirectory.appendingPathComponent("runtime.json"), keys: ["auto_repair", "auto_snapshot"], validateValue:validateBoolean)],
                         defaults: store.defaults, validateDefault:validateDefault)
    }

    private static func invalid(_ message:String) -> Error { NSError(domain:"Sift.Configuration",code:2,userInfo:[NSLocalizedDescriptionKey:message + "；原配置已保留"]) }
    private static func validateIndexField(_ key:String,_ value:Any) throws {
        guard (key == "root" && value is String) || (key != "root" && value is [String]) else { throw invalid("索引根应为路径，排除和包含应为路径数组") }
        try validatePath(value)
    }
    private static func validateBoolean(_ value:Any) throws {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw invalid("运行开关必须为 true 或 false") }
    }
    private static func validatePath(_ value:Any) throws {
        let paths: [String]
        if let s = value as? String { paths = [s] }
        else if let list = value as? [String] { paths = list }
        else { throw invalid("索引范围须为路径或路径数组") }
        guard paths.allSatisfy({ !$0.contains("\0") && ($0 == "~" || $0.hasPrefix("/") || $0.hasPrefix("~/")) }) else { throw invalid("索引范围须为绝对路径或 ~/ 路径") }
        if let root = value as? String {
            let path = (root as NSString).expandingTildeInPath
            var directory:ObjCBool = false
            guard FileManager.default.fileExists(atPath:path,isDirectory:&directory),directory.boolValue,FileManager.default.isReadableFile(atPath:path) else { throw invalid("索引根目录不存在或不可读取") }
        }
    }
    private static func validateDefault(_ key:String,_ value:Any) throws {
        if ["caseInsensitive","showFolderScope","sortDescending"].contains(key) { try validateBoolean(value);return }
        if key == "hotkey" {
            guard let stored = value as? String,let combo = GlobalHotkey.Combo(stored:stored),combo.isUsable else { throw invalid("快捷键格式无效") };return
        }
        if key == "sortKey" {
            guard let number = value as? NSNumber,(0...4).contains(number.intValue),number.doubleValue == Double(number.intValue) else { throw invalid("排序字段无效") };return
        }
        if key == "shortcuts.v1" {
            guard let values = value as? [String:[String:String]] else { throw invalid("快捷键配置无效") }
            for (id,binding) in values {
                guard ShortcutAction.all.contains(where:{$0.id == id && id != "show"}),["app","global"].contains(binding["scope"] ?? ""),let stored = binding["stored"],stored.isEmpty || GlobalHotkey.Combo(stored:stored)?.isUsable == true else { throw invalid("快捷键配置含无效操作或组合") }
                if let combo = GlobalHotkey.Combo(stored:stored),combo.modifiers == .command,[0,6,7,8,9].contains(combo.keyCode) { throw invalid("快捷键不可覆盖系统文本编辑键") }
                if binding["scope"] == "app",let combo = GlobalHotkey.Combo(stored:stored),combo.modifiers == .command,SiftShortcuts.fixedAppKeyCodes.contains(combo.keyCode) { throw invalid("快捷键不可覆盖固定窗口导航") }
            }
            var seen = Set<String>()
            for action in ShortcutAction.all where action.id != "show" {
                let stored:String?
                if let binding = values[action.id] { stored = binding["stored"].flatMap{$0.isEmpty ? nil : $0} }
                else { stored = action.key.map{GlobalHotkey.Combo(keyCode:$0,modifiers:action.modifiers).stored} }
                if let stored { guard seen.insert((values[action.id]?["scope"] ?? "app") + "/" + stored).inserted else { throw invalid("快捷键配置含重复绑定") } }
            };return
        }
        if key == "savedSearches" {
            guard let list = value as? [[String:String]],list.count <= 200,list.allSatisfy({ !($0["name"] ?? "").isEmpty && ($0["name"] ?? "").count <= 100 && !($0["query"] ?? "").isEmpty && ($0["query"] ?? "").count <= 4096 }) else { throw invalid("常用搜索格式无效") };return
        }
        #if !APP_STORE
        if key == "appUpdateOptions" {
            let data = try JSONSerialization.data(withJSONObject:value)
            let options = try JSONDecoder().decode(AppUpdateOptions.self,from:data)
            try AppUpdatePreferences.validate(options)
        }
        #endif
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

    // The command side and the updater are the Developer ID build's: the Mac App Store build has no `sift` CLI
    // beside it and is updated by the App Store (Shared/AppLifecycle.swift, AppLifecycleCLI.swift and
    // AppLifecycleUI.swift are not compiled into it, see store/project.yml).
    #if !APP_STORE
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
        product.canInstallUpdate = {
            guard let text = store.supportDirectory.path.withCString({ sift_remote_status($0) }) else { return false }
            defer { sift_string_free(text) }
            guard let status = (try? JSONSerialization.jsonObject(with:Data(String(cString:text).utf8))) as? [String:Any],status["ok"] as? Bool == true else { return false }
            return status["running"] as? Bool == false || installable(status)
        }
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
    #endif
    static func installable(_ status:[String:Any]) -> Bool {
        let state = status["state"] as? String ?? ""
        return ["ready","rebuild_required"].contains(state) && status["repairing"] as? Bool != true && (status["configuration_error"] as? String ?? "").isEmpty && (status["runtime_error"] as? String ?? "").isEmpty
    }
}
