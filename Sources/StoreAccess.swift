// Mac App Store build only (`-D APP_STORE`, store/project.yml). The Developer ID build (build.sh) compiles this
// file to nothing and behaves as before.
#if APP_STORE
import AppKit

/// What the sandboxed build may index. The App Sandbox lets an app read only what the user handed it, and Full
/// Disk Access does not lift that, so this build indexes one folder the user chose in an open panel; choosing the
/// startup disk gives whole-disk search again. The choice is kept as an app-scoped security-scoped bookmark and its
/// scope is opened before the engine starts; from then on the Rust engine's plain path access and its FSEvents
/// stream under that folder work for the whole process.
///
/// The engine's `root` (config.json) is always this Mac's granted folder and nothing else: a root that an import
/// or another Mac brought in names a folder this Mac never granted. While nothing is granted the root is an empty
/// folder inside the app's own support directory, so the index is empty rather than a walk of what the sandbox
/// refuses, and the search window explains and offers the panel (SearchWindowController).
enum IndexAccess {
    /// Per Mac, never exported or synced (not in Lifecycle.defaultsKeys): a bookmark only resolves where it was made.
    private static let bookmarkKey = "indexRootBookmark"
    /// Verification only: a folder that stands in for the open panel's answer, so the rest of the path (bookmark,
    /// settings, re-index, the next launch) can run with nothing on screen. Honoured only in a throwaway copy of
    /// the app (bundle identifier starting with `Lifecycle.isolatedBundlePrefix`), never in the shipped app.
    static let testGrantVariable = "SIFT_STORE_GRANT"

    /// The granted folder, its security scope open until the app quits.
    private(set) static var granted: URL?
    /// Why a folder granted earlier is not in use (moved, its disk not connected, the bookmark refused).
    private(set) static var problem: String?
    private static var placeholder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private static var askedThisLaunch = false

    static var hasGrant: Bool { granted != nil }
    static var rootPath: String { (granted ?? placeholder).path }

    /// The user's home folder. In the sandbox NSHomeDirectory() and $HOME are the app's container.
    static let userHome: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()

    /// The status line of the search window while nothing is granted.
    static var explanation: String {
        if let problem { return problem }
        return "Sift searches the folders you allow. Choose \(startupDiskName) to search the whole Mac."
    }
    static var startupDiskName: String { FileManager.default.displayName(atPath: "/") }

    /// Before the engine starts: tells the core where `~` is and that there is no CLI socket, opens the stored
    /// grant, and makes config.json's root that folder. A read-only run (`--snapshot`, `--ui-self-test`,
    /// `-lane_quiet`) opens the grant too but writes nothing: it indexes its own fixture or reads the index as it is.
    static func prepare(supportDirectory: URL) {
        setenv("SIFT_USER_HOME", userHome, 1) // core/src/config.rs `home`
        setenv("SIFT_NO_IPC", "1", 1)         // core/src/ffi.rs: this build ships without the `sift` CLI
        placeholder = supportDirectory.appendingPathComponent("NoFolderGranted", isDirectory: true)
        try? FileManager.default.createDirectory(at: placeholder, withIntermediateDirectories: true)
        restore()
        // A first start has no config.json; the core's default root is then this folder instead of `/`.
        setenv("SIFT_DEFAULT_ROOT", rootPath, 1)
        if !Prefs.readOnly { enforceRoot(in: supportDirectory.appendingPathComponent("config.json")) }
        // One line for whoever started the app from a shell (verification runs read it; a normal launch has no stderr).
        let stored = (try? Data(contentsOf: supportDirectory.appendingPathComponent("config.json")))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["root"] as? String
        let index = (try? FileManager.default.attributesOfItem(atPath: supportDirectory.appendingPathComponent("index.db").path))?[.size] as? Int
        fputs("store access: root=\(rootPath) grant=\(hasGrant ? "bookmark" : "none")"
              + " sandbox=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "off")"
              + " support=\(supportDirectory.path) config.root=\(stored ?? "none") index.db=\(index.map(String.init) ?? "none")"
              + (problem.map { " problem=\($0)" } ?? "") + "\n", stderr)
    }

    private static func restore() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            let scoped = resolved.startAccessingSecurityScopedResource()
            let url = resolved.standardizedFileURL // the spelling `grant` stored as the root
            guard readableFolder(url) else {
                if scoped { resolved.stopAccessingSecurityScopedResource() }
                problem = "Sift can no longer reach “\(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)”. Choose the folder to index again."
                return
            }
            granted = url
            // The system asks for a fresh bookmark after the folder moved or the system was updated.
            if stale, !Prefs.readOnly, let fresh = try? bookmark(url) { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
        } catch {
            problem = "Sift could not reopen the folder it indexed (\(error.localizedDescription)). Choose it again."
        }
    }

    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func readableFolder(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    /// config.json keeps its other settings; only a root that is not this Mac's granted folder is replaced.
    static func enforceRoot(in file: URL) {
        guard let data = try? Data(contentsOf: file), let fixed = enforcingRoot(data), fixed != data else { return }
        try? fixed.write(to: file, options: .atomic)
    }

    /// The same settings with this Mac's root; nil when they are not a JSON object (the core then reports it).
    static func enforcingRoot(_ settings: Data) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any] else { return nil }
        if object["root"] as? String == rootPath { return settings }
        object["root"] = rootPath
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Granting

    /// The folder an isolated verification run supplies in place of the panel (see `testGrantVariable`).
    static var testGrant: URL? {
        guard let path = ProcessInfo.processInfo.environment[testGrantVariable], path.hasPrefix("/"),
              Bundle.main.bundleIdentifier?.hasPrefix(Lifecycle.isolatedBundlePrefix) == true else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The open panel: folders only, opened on the startup disk, so the default button alone allows the whole
    /// disk. Never shown in a verification run. `completion` gets nil when the user cancelled.
    static func choose(for window: NSWindow?, completion: @escaping (URL?) -> Void) {
        if Prefs.readOnly || Prefs.headless { fputs("dry-run choose index folder\n", stderr); return }
        if let url = testGrant { completion(url); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        panel.message = "Choose what Sift may index. To search the whole Mac, stay on \(startupDiskName) and click Allow; or pick one folder."
        panel.prompt = "Allow"
        let done: (NSApplication.ModalResponse) -> Void = { completion($0 == .OK ? panel.url : nil) }
        if let window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// What the panel's answer leads to: the folder is remembered (bookmark), becomes the engine's root and is
    /// indexed. Returns what went wrong, if anything; the folder is then not in use.
    @discardableResult
    static func grant(_ url: URL, engine: Engine) -> String? {
        let url = url.standardizedFileURL
        guard readableFolder(url) else { return "Sift cannot read “\(url.path)”." }
        guard let current = engine.settingsJSON(), var object = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any] else {
            return "Sift could not read its settings."
        }
        let previous = (granted, problem)
        granted = url
        problem = nil
        object["root"] = url.path
        guard let settings = try? JSONSerialization.data(withJSONObject: object) else { return "Sift could not write its settings." }
        if let error = engine.updateSettings(settings) {
            (granted, problem) = previous
            return error
        }
        Prefs.didSaveIndexSettings?()
        // The earlier folder's scope stays open until the app quits: a walk of it may still be winding down.
        do { UserDefaults.standard.set(try bookmark(url), forKey: bookmarkKey) } catch {
            // Still usable now (the panel's answer is good for this run); the next launch asks again.
            fputs("store access: folder in use, but not remembered: \(error.localizedDescription)\n", stderr)
        }
        fputs("store access: granted \(url.path)\n", stderr)
        return nil
    }

    /// The button in the search window, the one in Settings and the Search menu item.
    static func chooseAndGrant(for window: NSWindow?, engine: Engine, completion: @escaping (_ error: String?) -> Void) {
        choose(for: window) { url in
            guard let url else { return }
            completion(grant(url, engine: engine))
        }
    }

    /// The first time the search window comes up without a grant, the panel is offered once; after that the
    /// status line and its button stay.
    static func offerOnce(for window: NSWindow?, engine: Engine, completion: @escaping (_ error: String?) -> Void) {
        guard !hasGrant, !askedThisLaunch else { return }
        askedThisLaunch = true
        DispatchQueue.main.async { chooseAndGrant(for: window, engine: engine, completion: completion) }
    }

    /// A path as Settings shows it: `~` for the user's real home.
    static func abbreviated(_ path: String) -> String {
        path == userHome ? "~" : (path.hasPrefix(userHome + "/") ? "~" + path.dropFirst(userHome.count) : path)
    }
}

/// The settings that travel (Lifecycle), for the Settings window's own iCloud switch and Export / Import buttons.
/// The shared「配置与更新」window is not part of this build: it always offers its update check, and the App Store
/// delivers this build's updates.
enum StoreConfiguration {
    static weak var current: AppConfiguration?
    static let statusChanged = Notification.Name("AppConfigurationStatusChanged")

    /// The exported file also names the index root, as the Developer ID build's export does, so that build can
    /// import it (it requires a root). The root is not among this build's own portable settings.
    static func exportData(_ configuration: AppConfiguration) throws -> Data {
        let data = try configuration.exportData()
        guard var envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var values = envelope["values"] as? [String: Any] else { return data }
        values["file.0.root"] = IndexAccess.granted?.path ?? "/"
        envelope["values"] = values
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    /// An exported file's index root (a Developer ID build's, another Mac's) is left out: what this Mac indexes is
    /// the folder granted here. Everything else is imported by the shared layer, which backs up the old settings.
    static func importData(_ data: Data, into configuration: AppConfiguration) throws {
        var portable = data
        if var envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var values = envelope["values"] as? [String: Any], values.removeValue(forKey: "file.0.root") != nil {
            envelope["values"] = values
            portable = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? data
        }
        try configuration.importData(portable)
    }
}
#endif
