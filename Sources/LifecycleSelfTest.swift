import AppKit

/// `--lifecycle-self-test [--out <dir>] [--trash-volume <dir>]`: this process is the running app, and the real
/// `sift config …`, `sift update check|install`, `sift hotkey …`, `sift login-item …` and `sift trash` commands are
/// run against it as child processes, the way an agent runs them: the `sift` CLI of this bundle through a symlink
/// named sift, which hands the words to this bundle's app executable or sends them over this app's socket.
///
/// What it is for: a command changes a setting that a running window also holds. The app must follow (the
/// switch, the status line, the imported settings reach the search window, the global shortcut and the index),
/// and nothing the app does may put an older value back. Every verdict on a stored value is read by a fresh
/// process (`sift config status`, `sift status`, `sift config`), never from this app's own memory, and the
/// back-to-back sections run two commands with nothing in between.
///
/// Isolation: it only runs from a throwaway copy of Sift.app with a `test.tianli.sift.` bundle identifier
/// (scripts/accept/lifecycle.sh makes one), so the standard preference domain is a throwaway one. The index is a
/// small fixture in a temporary folder, the shared layer's support and "cloud" folders are temporary, the
/// follow channel is private. Activation policy prohibited: no Dock icon, nothing can be ordered onto the
/// screen. No system-wide key is taken (GlobalHotkey.register) except one obscure combination (⌃⌥⇧⌘F20) held for
/// a moment to see Carbon accept and refuse it; the login item is only noted, never registered with macOS
/// (LoginItem); the only files moved to a Trash are this run's own, on the throwaway volume the wrapper script
/// mounts (their Trash is that volume's, not the owner's). The owner's index, config.json, preferences, iCloud
/// Drive, Trash and running Sift are not opened. Prints one final JSON line and exits 0 (all passed) or 1.
@MainActor
final class LifecycleSelfTest {
    nonisolated(unsafe) private static var base: URL?
    nonisolated(unsafe) private static var outDir: URL?
    nonisolated(unsafe) private static var fixture = ""
    nonisolated(unsafe) private static var trashVolume: URL?
    private static var current: LifecycleSelfTest?
    nonisolated private static let timeoutSeconds = 420.0
    nonisolated private static let progress = NSLock()
    nonisolated(unsafe) private static var step = "start"
    private static let off = "iCloud 配置同步已关闭"

    private let engine: Engine
    private let search: SearchWindowController
    private let hotkey: GlobalHotkey
    private let configuration: AppConfiguration?
    private let reloads: () -> Int
    private let settings: () -> SettingsWindowController?
    /// Holds the obscure combination while the app is asked to register the same one (Carbon refuses the second).
    private let blocker = GlobalHotkey {}
    private var checks: [(String, Bool)] = []
    private var details: [String: Any] = [:]
    private var commands = 0
    private var link = URL(fileURLWithPath: "/usr/bin/false")
    private var toggle: NSControl?
    private var statusLine: NSTextField?

    // MARK: Before the app starts

    /// Called from main.swift before the app object exists: the fixture, the folders and the environment the
    /// app and every child command will see. Refuses a bundle that is not a throwaway copy.
    nonisolated static func prepareEnvironment(arguments: [String]) {
        guard let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix(Lifecycle.isolatedBundlePrefix) else {
            emit(["ok": false, "checks": [String: Bool](), "failed": ["throwaway_bundle"],
                  "summary": "生命周期自检只在换了 bundle id 的临时副本里运行（scripts/accept/lifecycle.sh 会做）；当前 \(Bundle.main.bundleIdentifier ?? "无 bundle")"])
            exit(64)
        }
        let files = FileManager.default
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        // The real path: FSEvents and the engine report /private/var/…, not the /var/… symlink.
        let temporary = realpath(NSTemporaryDirectory(), &buffer) != nil ? String(cString: buffer) : NSTemporaryDirectory()
        let root = URL(fileURLWithPath: temporary, isDirectory: true).appendingPathComponent("sift-lc-\(getpid())", isDirectory: true)
        try? files.removeItem(at: root)
        let tree = root.appendingPathComponent("fixture", isDirectory: true), support = root.appendingPathComponent("support", isDirectory: true)
        for (path, text) in [("docs/README.md", "a"), ("docs/notes.txt", "b"), ("skipme/hidden-target.md", "c"), (".hidden/secret.key", "d")] {
            let url = tree.appendingPathComponent(path)
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            files.createFile(atPath: url.path, contents: Data(text.utf8))
        }
        try? files.createDirectory(at: support, withIntermediateDirectories: true)
        let config: [String: Any] = ["root": tree.path, "ignore_paths": [tree.appendingPathComponent(".hidden").path, "/System/Volumes/Data"], "include_paths": [String]()]
        try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: support.appendingPathComponent("config.json"))
        setenv("SIFT_SUPPORT_DIR", support.path, 1)
        setenv("SIFT_PREFS_DOMAIN", identifier, 1)   // the CLI's read of the window preferences: this throwaway domain
        setenv("APP_LIFECYCLE_SUPPORT_DIR", root.appendingPathComponent("lifecycle", isDirectory: true).path, 1)
        setenv("APP_LIFECYCLE_CLOUD_DIR", root.appendingPathComponent("cloud", isDirectory: true).path, 1)
        setenv("APP_LIFECYCLE_FOLLOW_CHANNEL", "test." + UUID().uuidString.lowercased(), 1)
        unsetenv("SIFT_APP"); unsetenv("SIFT_APP_TIMEOUT"); unsetenv("SIFT_READONLY")
        // The window's own preferences as a fresh Mac has them, written out so the export lists them.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "caseInsensitive"); defaults.set(false, forKey: "showFolderScope")
        defaults.set(["kept on this Mac"], forKey: "recentSearches")
        defaults.removeObject(forKey: "hotkey"); defaults.removeObject(forKey: "appLifecycle.configuration.enabled")
        defaults.synchronize()
        base = root; fixture = tree.path
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
            outDir = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else { outDir = root.appendingPathComponent("out", isDirectory: true) }
        if let outDir { try? files.createDirectory(at: outDir, withIntermediateDirectories: true) }
        if let index = arguments.firstIndex(of: "--trash-volume"), index + 1 < arguments.count {
            trashVolume = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        // As for the UI self-test: let the fixture's own file events age past the engine's FSEvents start.
        Thread.sleep(forTimeInterval: 1.5)
    }

    static func start(engine: Engine, searchWindow: SearchWindowController, hotkey: GlobalHotkey, configuration: AppConfiguration?,
                      reloads: @escaping () -> Int, settings: @escaping () -> SettingsWindowController?) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            progress.lock(); let at = step; progress.unlock()
            emit(["ok": false, "checks": [String: Bool](), "failed": ["timeout"], "summary": "生命周期自检超过 \(Int(timeoutSeconds)) 秒未完成（停在 \(at)）",
                  "preference_domain": Bundle.main.bundleIdentifier ?? ""])
            cleanup()
            exit(1)
        }
        let test = LifecycleSelfTest(engine: engine, search: searchWindow, hotkey: hotkey, configuration: configuration, reloads: reloads, settings: settings)
        current = test
        Task { @MainActor in await test.run() }
    }

    private init(engine: Engine, search: SearchWindowController, hotkey: GlobalHotkey, configuration: AppConfiguration?, reloads: @escaping () -> Int,
                 settings: @escaping () -> SettingsWindowController?) {
        self.engine = engine; self.search = search; self.hotkey = hotkey; self.configuration = configuration; self.reloads = reloads
        self.settings = settings
    }

    // MARK: Helpers

    private func mark(_ name: String) { Self.progress.lock(); Self.step = name; Self.progress.unlock() }

    private func check(_ name: String, _ passed: Bool, _ detail: Any? = nil) {
        checks.append((name, passed))
        if let detail { details[name] = detail }
        if !passed { fputs("lifecycle-self-test FAIL \(name): \(detail.map { "\($0)" } ?? "")\n", stderr) }
    }

    /// Deadlines count time the Mac was awake, so a wait that spans a sleep neither fails nor passes because of it.
    private func awake() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func wait(_ seconds: Double, until done: () -> Bool) async -> Bool {
        let end = awake() + seconds
        while !done() && awake() < end { await pause(0.02) }
        return done()
    }
    private func eventually(_ seconds: Double, _ done: () async -> Bool) async -> Bool {
        let end = awake() + seconds
        while awake() < end { if await done() { return true }; await pause(0.05) }
        return await done()
    }

    private struct Outcome {
        let code: Int32
        let body: [String: Any]
        let stdout: String
        let stderr: String
        var errorCode: String? { body["code"] as? String }
    }

    /// One command as a child process. The main actor is released while it runs, so this app keeps receiving
    /// the command's notification and its own timers, as a running app does.
    private func launch(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil, directory: URL? = nil) async -> Outcome {
        guard let base = Self.base else { return Outcome(code: -1, body: [:], stdout: "", stderr: "no working folder") }
        commands += 1
        let out = base.appendingPathComponent("out-\(commands).txt"), err = base.appendingPathComponent("err-\(commands).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil); FileManager.default.createFile(atPath: err.path, contents: nil)
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle(forWritingAtPath: out.path); process.standardError = FileHandle(forWritingAtPath: err.path)
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        guard (try? process.run()) != nil else { return Outcome(code: -1, body: [:], stdout: "", stderr: "not started") }
        while process.isRunning { await pause(0.005) }
        let stdout = (try? String(contentsOf: out, encoding: .utf8)) ?? "", stderr = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: err)
        let body = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any]
        return Outcome(code: process.terminationStatus, body: body ?? [:], stdout: stdout, stderr: stderr)
    }
    /// `sift <words> --json`, as an agent types it.
    private func sift(_ words: String...) async -> Outcome { await launch(link, words + ["--json"]) }
    private func siftText(_ words: String...) async -> Outcome { await launch(link, words) }

    private var shown: Bool? {
        if let button = toggle as? NSButton { return button.state == .on }
        if let control = toggle as? NSSwitch { return control.state == .on }
        return nil
    }
    /// The stored switch as a fresh process reads it; nil when the read itself failed.
    private func stored() async -> Bool? {
        let status = await sift("config", "status")
        return status.code == 0 ? status.body["sync_enabled"] as? Bool : nil
    }
    /// For `seconds`, the app, its window and every fresh read of the stored value all stay at `target`.
    private func holds(_ target: Bool, _ seconds: Double) async -> Bool {
        let end = awake() + seconds
        repeat {
            guard configuration?.enabled == target, shown == target, await stored() == target else { return false }
            await pause(0.03)
        } while awake() < end
        return true
    }
    private func sync(_ target: Bool) async -> Outcome { await sift("config", "sync", target ? "on" : "off", "--yes") }
    private var unfollowed: [[String: Any]] = []
    private func follows(_ target: Bool) async -> Bool {
        let began = awake(), clock = Date()
        let followed = await wait(6) { configuration?.enabled == target && shown == target && (statusLine?.stringValue == Self.off) == !target }
        if !followed {
            unfollowed.append(["target": target, "enabled": configuration?.enabled ?? false, "shown": shown ?? false,
                               "status": statusLine?.stringValue ?? "", "awake_s": awake() - began, "wall_s": Date().timeIntervalSince(clock)])
        }
        return followed
    }
    private func envelope(_ values: [String: Any], product: String = Lifecycle.productID, version: Int = 1) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["version": version, "product": product, "values": values], options: [.sortedKeys])) ?? Data()
    }
    private func object(_ url: URL) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] }
    private func stamp(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "absent" }
        return "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)/\(attributes[.size] ?? 0)"
    }
    /// What a fresh process reads of the portable settings: the window preferences and the index settings on disk.
    private func read() async -> (caseInsensitive: Bool?, folder: Bool?, hotkey: String?, ignore: [String], live: [String], state: String, walks: Int) {
        let status = await sift("status"), config = await sift("config")
        let gui = status.body["gui"] as? [String: Any]
        return (gui?["case_insensitive"] as? Bool, gui?["show_folder_scope"] as? Bool, (gui?["hotkey"] as? [String: Any])?["stored"] as? String,
                config.body["ignore_paths"] as? [String] ?? [], status.body["ignore_paths"] as? [String] ?? [],
                status.body["state"] as? String ?? "", status.body["walks"] as? Int ?? -1)
    }

    // MARK: Run

    private func run() async {
        let files = FileManager.default
        guard let base = Self.base, let outDir = Self.outDir, let identifier = Bundle.main.bundleIdentifier else { return finish() }
        let home = files.homeDirectoryForCurrentUser
        // The owner's own state, looked at (never opened for writing) before and after. iCloud Drive is not even looked at.
        let owned = [home.appendingPathComponent("Library/Preferences/\(Lifecycle.productID).plist"),
                     home.appendingPathComponent("Library/Application Support/\(Lifecycle.productID)/config.json"),
                     home.appendingPathComponent("Library/Application Support/\(Lifecycle.productID)/index.db"),
                     home.appendingPathComponent("Library/Application Support/Sift/Configuration/\(Lifecycle.productID)")]
        let ownedBefore = owned.map(stamp)
        let support = base.appendingPathComponent("support"), lifecycle = base.appendingPathComponent("lifecycle"), cloud = base.appendingPathComponent("cloud")
        let configFile = support.appendingPathComponent("config.json"), cloudFile = cloud.appendingPathComponent(Lifecycle.productID + ".json")
        let hidden = Self.fixture + "/.hidden", skipme = Self.fixture + "/skipme", system = "/System/Volumes/Data"

        mark("isolation")
        let environment = ProcessInfo.processInfo.environment
        check("isolation_in_force", Lifecycle.isolated && Lifecycle.store()?.supportDirectory.path == support.path
              && AppDelegate.supportDirectory.path == support.path && environment["APP_LIFECYCLE_FOLLOW_CHANNEL"]?.hasPrefix("test.") == true,
              ["bundle": identifier, "support": AppDelegate.supportDirectory.path])
        // The same rule decides for the app and for the command; an isolated run on the owner's bundle or folder is refused.
        check("isolated_run_needs_a_throwaway_bundle_and_folder",
              Lifecycle.store(bundleID: Lifecycle.productID, environment: environment) == nil
              && Lifecycle.store(bundleID: identifier, environment: environment.filter { $0.key != "SIFT_SUPPORT_DIR" }) == nil
              && Lifecycle.store(bundleID: nil, environment: environment) == nil
              && Lifecycle.store(bundleID: identifier, environment: environment)?.supportDirectory.path == support.path)
        guard checks.allSatisfy(\.1), configuration != nil else {
            check("lifecycle_installed", configuration != nil)
            return finish()
        }

        mark("index")
        let ready = await wait(60) { engine.status().state == .ready }
        check("index_ready", ready && engine.status().files > 0, ["state": engine.status().state.label, "files": engine.status().files] as [String: Any])

        mark("window")
        search.prepareOffscreen(size: NSSize(width: 1000, height: 600))
        let shot = (try? AppLifecycleUI.shared.offscreenSnapshot(to: outDir.appendingPathComponent("lifecycle-window.png"))) ?? [:]
        let window = Mirror(reflecting: AppLifecycleUI.shared)
        toggle = window.descendant("cloudToggle") as? NSControl
        statusLine = window.descendant("syncStatus") as? NSTextField
        check("lifecycle_window_built_offscreen", shot["upgrade_window_offscreen"] == true && shot["upgrade_image_rendered"] == true
              && toggle?.window != nil && toggle?.window?.isVisible == false && statusLine?.window === toggle?.window
              && NSApp.activationPolicy() == .prohibited && NSApp.windows.allSatisfy { !$0.isVisible },
              ["title": toggle?.window?.title ?? "", "shot": shot] as [String: Any])
        check("app_starts_with_sync_off", configuration?.enabled == false && shown == false && statusLine?.stringValue == Self.off
              && search.caseInsensitiveForTesting && !search.folderVisibleForTesting && hotkey.combo == nil)

        mark("command")
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        link = bin.appendingPathComponent("sift")
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/sift")
        guard (try? files.createDirectory(at: bin, withIntermediateDirectories: true)) != nil,
              (try? files.createSymbolicLink(at: link, withDestinationURL: cli)) != nil, let executable = Bundle.main.executableURL else {
            check("command_link", false)
            return finish()
        }
        let first = await sift("config", "status")
        let portable = ["defaults.caseInsensitive", "defaults.showFolderScope", "file.0.ignore_paths", "file.0.include_paths", "file.0.root"]
        check("status_reads_the_windows_settings", first.code == 0 && first.body["ok"] as? Bool == true && first.body["command"] as? String == "config status"
              && first.body["has_settings"] as? Bool == true && first.body["sync_enabled"] as? Bool == false
              && first.body["keys"] as? [String] == portable && first.body["problem"] is NSNull && first.body["app_running"] as? Bool == true
              && first.stdout.split(separator: "\n").count == 1, first.stdout)
        // The sentence under the window's switch, read without the window: this app is running and shows 已关闭.
        let firstSentence = first.body["sync_status"] as? [String: Any]
        let asText = await siftText("config", "status")
        check("status_carries_the_windows_sync_sentence", firstSentence?["text"] as? String == Self.off && firstSentence?["live"] as? Bool == true
              && ["app", "derived"].contains(firstSentence?["from"] as? String ?? "") && asText.code == 0 && asText.stdout.contains("同步状态：" + Self.off),
              [first.stdout, asText.stdout])
        check("status_writes_nothing", !files.fileExists(atPath: lifecycle.path) && !files.fileExists(atPath: cloud.path))
        // The CLI adds nothing and drops nothing: the same words to the app executable give the same bytes and exit code.
        var forwarded = true
        for words in [["config", "status", "--json"], ["config", "status"], ["config", "sync", "maybe", "--json"], ["config", "sync", "on", "--json"],
                      ["config", "export", "--json"], ["update", "--json"], ["update", "check", "--json"], ["update", "check"],
                      ["update", "install", "--json"], ["update", "install", "--dry-run", "--json"], ["update", "install", "--no-such", "--json"]] {
            let ours = await launch(link, words), theirs = await launch(executable, words)
            if ours.code != theirs.code || ours.stdout != theirs.stdout || ours.stderr != theirs.stderr {
                forwarded = false
                details["command_line_forwards_unchanged"] = ["words": words, "cli": [ours.code, ours.stdout, ours.stderr] as [Any], "app": [theirs.code, theirs.stdout, theirs.stderr] as [Any]] as [String: Any]
            }
        }
        check("command_line_forwards_unchanged", forwarded)

        mark("switch")
        for round in 1...3 {
            let on = await sync(true)
            check("round\(round)_command_switches_on", on.code == 0 && on.body["changed"] as? Bool == true && on.body["sync_enabled"] as? Bool == true
                  && on.body["app_running"] as? Bool == true && on.body["check_with"] as? String == "sift config status", on.stdout)
            check("round\(round)_app_follows_on", await follows(true))
            check("round\(round)_on_is_not_written_back", await holds(true, 1.2))
            if round == 1 {
                let uploaded = object(cloudFile)?["values"] as? [String: Any]
                check("sync_on_uploads_through_the_shared_reconcile", uploaded?["file.0.root"] as? String == Self.fixture
                      && uploaded?["defaults.caseInsensitive"] as? Bool == true, uploaded?.keys.sorted() ?? [])
                // With the switch on, a fresh process reads the very sentence this running window shows.
                var read: [String: Any] = [:]
                let sentence = await eventually(6) {
                    read = (await self.sift("config", "status")).body["sync_status"] as? [String: Any] ?? [:]
                    return read["from"] as? String == "app" && read["live"] as? Bool == true && read["text"] as? String == self.statusLine?.stringValue
                        && read["text"] as? String != Self.off
                }
                check("sync_status_is_the_running_windows_sentence", sentence, ["read": read, "window": statusLine?.stringValue ?? ""] as [String: Any])
            }
            let turnedOff = await sync(false)
            check("round\(round)_command_switches_off", turnedOff.code == 0 && turnedOff.body["changed"] as? Bool == true && turnedOff.body["sync_enabled"] as? Bool == false, turnedOff.stdout)
            check("round\(round)_app_follows_off", await follows(false))
            check("round\(round)_off_is_not_written_back", await holds(false, 1.2))
        }

        // Back to back: the second command lands while the app is still about to act on the first. From the moment
        // the second command returns, no fresh read may see the first command's value again.
        mark("back_to_back")
        var regressions: [String] = []
        func settled(_ target: Bool, _ label: String) async {
            let end = awake() + 1.5
            while awake() < end {
                if await stored() != target { regressions.append(label); return }
            }
            if !(await follows(target)) { regressions.append(label + ":app") }
        }
        for round in 1...4 {
            _ = await sync(true); _ = await sync(false)
            await settled(false, "on>off#\(round)")
            _ = await sync(true); _ = await follows(true); await pause(0.5)
            _ = await sync(false); _ = await sync(true)
            await settled(true, "off>on#\(round)")
            _ = await sync(false); _ = await follows(false); await pause(0.5)
        }
        check("back_to_back_switches_never_regress", regressions.isEmpty, regressions)

        // The window's own switch and the command are one setting, both ways.
        mark("window_switch")
        if let toggle, let action = toggle.action {
            (toggle as? NSButton)?.state = .on; (toggle as? NSSwitch)?.state = .on
            NSApp.sendAction(action, to: toggle.target, from: toggle)
            let seen = await eventually(6) { await self.stored() == true }
            check("window_switch_is_read_by_the_command", seen && configuration?.enabled == true)
            let back = await sync(false)
            let followed = await follows(false)
            check("command_switch_is_shown_by_the_window", back.code == 0 && followed)
            check("command_switch_stays", await holds(false, 0.6))
        } else { check("window_switch_is_read_by_the_command", false) }

        // A command that only turns the switch brings no settings: the app must not reload for it, also not right
        // after the app stored a preference of its own.
        mark("no_reload")
        let reloadsBefore = reloads()
        search.toggleCase(nil); search.toggleCase(nil)   // the window's own Match Case, there and back (stored each time)
        _ = await sync(true); _ = await follows(true); _ = await sync(false); _ = await follows(false)
        await pause(0.6)
        check("switch_only_commands_do_not_reload_settings", reloads() == reloadsBefore && search.caseInsensitiveForTesting, ["reloads": reloads() - reloadsBefore])

        // Export, then import: the window preferences, the global shortcut and the index settings reach the running app.
        mark("export")
        let exported = base.appendingPathComponent("export.json")
        let export = await sift("config", "export", "-o", exported.path)
        let written = object(exported), exportedValues = written?["values"] as? [String: Any] ?? [:]
        check("export_writes_the_portable_settings_only", export.code == 0 && export.body["path"] as? String == exported.path
              && written?["product"] as? String == Lifecycle.productID && exportedValues.keys.sorted() == portable
              && exportedValues["file.0.ignore_paths"] as? [String] == [hidden, system] && !String(decoding: (try? Data(contentsOf: exported)) ?? Data(), as: UTF8.self).contains("kept on this Mac"),
              exportedValues.keys.sorted())
        let again = await sift("config", "export", "-o", exported.path), forced = await sift("config", "export", "-o", exported.path, "--force")
        check("export_does_not_overwrite_without_force", again.code == 2 && again.errorCode == "file_exists" && forced.code == 0)
        // A relative path is resolved where the command was typed, not where the app executable lives.
        let relative = await launch(link, ["config", "export", "-o", "here.json", "--json"], directory: base)
        check("relative_paths_resolve_where_the_command_was_typed", relative.code == 0 && relative.body["path"] as? String == base.appendingPathComponent("here.json").path
              && files.fileExists(atPath: base.appendingPathComponent("here.json").path), relative.stdout)

        mark("import")
        let found = await siftText("search", "hidden-target")
        let before = await read(), reloadsAtImport = reloads()
        var values = exportedValues
        values["defaults.caseInsensitive"] = false; values["defaults.showFolderScope"] = true; values["defaults.hotkey"] = "49:1179648"
        values["file.0.ignore_paths"] = [hidden, system, skipme]
        let incoming = base.appendingPathComponent("in.json")
        try? envelope(values).write(to: incoming)
        let configBytes = try? Data(contentsOf: configFile)
        let unconfirmed = await sift("config", "import", incoming.path)
        check("import_needs_yes", unconfirmed.code == 2 && unconfirmed.errorCode == "confirmation_required" && (try? Data(contentsOf: configFile)) == configBytes
              && search.caseInsensitiveForTesting && found.code == 0 && before.caseInsensitive == true && before.walks >= 1, [unconfirmed.stdout, found.code, before.walks] as [Any])
        let imported = await sift("config", "import", incoming.path, "--yes")
        check("import_command", imported.code == 0 && imported.body["imported"] as? Bool == true && imported.body["sync"] == nil
              && imported.body["sync_enabled"] as? Bool == false, imported.stdout)
        let reread = await wait(8) { self.reloads() > reloadsAtImport && !self.search.caseInsensitiveForTesting && self.search.folderVisibleForTesting
            && self.hotkey.combo?.stored == "49:1179648" && AppSettings.hotkey?.stored == "49:1179648" }
        check("app_rereads_imported_preferences_and_shortcut", reread, ["reloads": reloads() - reloadsAtImport, "case_insensitive": search.caseInsensitiveForTesting,
                                                                        "folder_field": search.folderVisibleForTesting, "shortcut": hotkey.combo?.stored ?? ""] as [String: Any])
        // The index follows: the running engine re-indexes with the imported skip list, as a fresh process sees it.
        let reindexed = await eventually(45) { let now = await self.read(); return now.live == [hidden, system, skipme] && now.state == "ready" && now.walks > before.walks }
        let gone = await siftText("search", "hidden-target")
        check("running_index_follows_the_imported_settings", reindexed && gone.code == 1, ["search_exit": gone.code])
        check("import_leaves_the_switch_alone", await holds(false, 0.8))
        // Nothing the app did after the import put an older value back: every fresh read stays at the imported values.
        var kept = true
        let end = awake() + 1.5
        while awake() < end {
            let now = await read()
            if now.caseInsensitive != false || now.folder != true || now.hotkey != "49:1179648" || now.ignore != [hidden, system, skipme] { kept = false; break }
        }
        check("import_is_not_written_back", kept)
        let history = await sift("history")
        let backups = (try? files.contentsOfDirectory(atPath: lifecycle.appendingPathComponent(Lifecycle.productID + "/Backups").path)) ?? []
        check("import_backs_up_and_keeps_what_is_not_portable", backups.count == 1 && history.body["items"] as? [String] == ["kept on this Mac"], [backups.count, history.stdout] as [Any])

        // Clear Recent Searches as a command: the saved list goes, the running window drops its copy, and the next
        // search the window records does not bring the old entries back.
        mark("history")
        let keptWithoutYes = await sift("history", "clear"), stillThere = await sift("history")
        check("history_clear_needs_yes", keptWithoutYes.code == 2 && keptWithoutYes.errorCode == "confirmation_required"
              && stillThere.body["total"] as? Int == 1 && search.historyForTesting == ["kept on this Mac"], keptWithoutYes.stdout)
        let cleared = await sift("history", "clear", "--yes")
        let dropped = await wait(6) { self.search.historyForTesting.isEmpty }
        let afterClear = await sift("history")
        check("history_clear_reaches_the_store_and_the_running_window", cleared.code == 0 && cleared.body["cleared"] as? Int == 1 && dropped
              && afterClear.body["total"] as? Int == 0, [cleared.stdout, afterClear.stdout])
        search.setQuery("fresh query")
        search.focusSearch(nil)
        if let editor = search.window?.fieldEditor(true, for: search.searchFieldForTesting) as? NSTextView {
            _ = search.control(search.searchFieldForTesting, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))   // ↩ records it
        }
        let recorded = await eventually(6) { (await self.sift("history")).body["items"] as? [String] == ["fresh query"] }
        check("cleared_history_is_not_written_back", recorded && search.historyForTesting == ["fresh query"], search.historyForTesting)
        _ = await sift("history", "clear", "--yes"); let twice = await sift("history", "clear", "--yes")
        let emptied = await wait(6) { self.search.historyForTesting.isEmpty }
        check("history_clear_twice_is_fine", twice.code == 0 && twice.body["cleared"] as? Int == 0 && emptied)
        search.setQuery("")

        // Refused imports change nothing.
        mark("bad_imports")
        let foreign = base.appendingPathComponent("foreign.json"), notAllowed = base.appendingPathComponent("not-allowed.json"), wrongVersion = base.appendingPathComponent("version.json")
        try? envelope(values, product: "someone.else").write(to: foreign)
        try? envelope(["defaults.recentSearches": ["x"]]).write(to: notAllowed)
        try? envelope(values, version: 2).write(to: wrongVersion)
        let goodBytes = try? Data(contentsOf: configFile)
        var refused: [Outcome] = []
        for file in [foreign, notAllowed, wrongVersion] { refused.append(await sift("config", "import", file.path, "--yes")) }
        let absent = await sift("config", "import", base.appendingPathComponent("absent.json").path, "--yes")
        let afterRefusals = await read()
        check("bad_imports_are_refused_and_change_nothing", refused.allSatisfy { $0.code == 1 && $0.errorCode == "import_rejected" && $0.body["error"] is String }
              && absent.code == 1 && absent.errorCode == "not_found" && (try? Data(contentsOf: configFile)) == goodBytes && afterRefusals.caseInsensitive == false
              && afterRefusals.ignore == [hidden, system, skipme], refused.map(\.stdout) + [absent.stdout])
        // With sync on, an import reaches the cloud copy and the app; nothing puts the old values back, also not
        // after two imports back to back.
        mark("synced_import")
        _ = await sync(true)
        check("app_follows_on_before_synced_import", await follows(true))
        var earlier = values, later = values
        earlier["defaults.showFolderScope"] = false; earlier["file.0.ignore_paths"] = [hidden, system]
        later["defaults.showFolderScope"] = true; later["defaults.caseInsensitive"] = true; later["file.0.ignore_paths"] = [hidden, system, skipme]
        let firstFile = base.appendingPathComponent("first.json"), secondFile = base.appendingPathComponent("second.json")
        try? envelope(earlier).write(to: firstFile); try? envelope(later).write(to: secondFile)
        let walksBefore = (await read()).walks
        let carried = await sift("config", "import", firstFile.path, "--yes")
        func cloudValues() -> [String: Any] { object(cloudFile)?["values"] as? [String: Any] ?? [:] }
        check("import_while_syncing_reaches_the_cloud_copy", carried.code == 0 && (carried.body["sync"] as? [String: Any])?["completed"] as? Bool == true
              && cloudValues()["defaults.showFolderScope"] as? Bool == false && cloudValues()["file.0.ignore_paths"] as? [String] == [hidden, system], carried.stdout)
        var syncedKept = true
        var until = awake() + 1.5
        while awake() < until {
            let now = await read(), switchOn = await stored()
            if now.folder != false || now.ignore != [hidden, system] || cloudValues()["defaults.showFolderScope"] as? Bool != false || switchOn != true { syncedKept = false; break }
        }
        check("synced_import_is_not_written_back", syncedKept)
        let shownSynced = await wait(8) { !self.search.folderVisibleForTesting }
        let backIndexed = await eventually(45) { let now = await self.read(); return now.live == [hidden, system] && now.state == "ready" && now.walks > walksBefore }
        let foundAgain = await siftText("search", "hidden-target")
        check("app_and_index_show_the_synced_import", shownSynced && backIndexed && foundAgain.code == 0, ["search_exit": foundAgain.code])
        check("sync_stays_on_after_the_import", await follows(true))
        _ = await sift("config", "import", firstFile.path, "--yes"); let last = await sift("config", "import", secondFile.path, "--yes")
        var lastKept = last.code == 0
        until = awake() + 1.5
        while lastKept && awake() < until {
            let now = await read()
            if now.folder != true || now.caseInsensitive != true || now.ignore != [hidden, system, skipme] || cloudValues()["defaults.showFolderScope"] as? Bool != true
                || cloudValues()["defaults.caseInsensitive"] as? Bool != true || cloudValues()["file.0.ignore_paths"] as? [String] != [hidden, system, skipme] { lastKept = false }
        }
        let settledOnLast = await wait(8) { self.search.folderVisibleForTesting && self.search.caseInsensitiveForTesting }
        let indexOnLast = await eventually(45) { let now = await self.read(); return now.live == [hidden, system, skipme] && now.state == "ready" }
        check("back_to_back_imports_keep_the_last", lastKept && settledOnLast && indexOnLast, ["stored": lastKept, "window": settledOnLast, "index": indexOnLast])
        _ = await sync(false)
        let finalOff = await follows(false)
        check("app_follows_final_off", finalOff)
        check("final_off_stays", await holds(false, 0.6))

        // Index settings the engine cannot read (here a number for the root) never reach the index: the running app
        // puts its own settings back, as it does for the window's 导入配置…. Last of the imports, with sync off: the
        // shared layer keeps an import made while sync is off as pending, and it would win at the next sync on.
        mark("unreadable")
        let current = (await read()).ignore
        var broken = later
        broken["file.0.root"] = 5
        let brokenFile = base.appendingPathComponent("broken.json")
        try? envelope(broken).write(to: brokenFile)
        _ = await sift("config", "import", brokenFile.path, "--yes")
        let restored = await eventually(10) { let config = await self.sift("config"); return config.code == 0 && config.body["root"] as? String == Self.fixture
            && config.body["ignore_paths"] as? [String] == current }
        let stillIndexed = await sift("status")
        check("unreadable_index_settings_are_put_back_by_the_running_app", restored && stillIndexed.body["root"] as? String == Self.fixture
              && stillIndexed.body["state"] as? String == "ready", stillIndexed.stdout)

        // Like `config set`: what can rewrite config.json is refused while no Sift answers for that folder.
        mark("not_running")
        let empty = base.appendingPathComponent("no-app", isDirectory: true)
        try? files.createDirectory(at: empty, withIntermediateDirectories: true)
        var elsewhere = ProcessInfo.processInfo.environment
        elsewhere["SIFT_SUPPORT_DIR"] = empty.path
        let stopped = await launch(link, ["config", "import", incoming.path, "--yes", "--json"], environment: elsewhere)
        let stoppedSync = await launch(link, ["config", "sync", "on", "--yes", "--json"], environment: elsewhere)
        check("import_and_sync_on_need_the_running_app", stopped.code == 3 && stopped.errorCode == "not_running" && stoppedSync.code == 3 && stoppedSync.errorCode == "not_running"
              && ((try? files.contentsOfDirectory(atPath: empty.path)) ?? ["?"]).isEmpty, [stopped.stdout, stoppedSync.stdout])

        // Errors keep sift's shape: one JSON object with error as text, exit, plus command and code; the reason on stderr.
        mark("errors")
        let usage = await sift("config", "sync", "maybe"), unknown = await sift("config", "status", "--no-such"), bare = await sift("update")
        check("usage_errors_exit_2_in_sifts_failure_shape", [usage, unknown, bare].allSatisfy { $0.code == 2 && $0.errorCode == "usage" && $0.body["ok"] as? Bool == false
            && $0.body["error"] is String && $0.body["exit"] as? Int == 2 && $0.stderr.hasPrefix("sift: ") && $0.stdout.split(separator: "\n").count == 1 }
              && usage.body["command"] as? String == "config sync", [usage.stdout, unknown.stdout, bare.stdout])

        // The top-level help lists every subcommand in the shared layer's own words.
        mark("help")
        let top = await siftText("--help"), own = await siftText("help", "update"), viaVerb = await siftText("config", "sync", "--help")
        let lines = (AppLifecycleCLI.helpRead(Lifecycle.command) + "\n" + AppLifecycleCLI.helpWrite(Lifecycle.command)).split(separator: "\n").map(String.init)
        let listed = lines.count == 6 && lines.allSatisfy { top.stdout.contains("\n" + $0 + "\n") && own.stdout.contains("\n" + $0 + "\n") }
        // Every item of the window has a command now: nothing is announced as missing any more.
        check("help_lines_are_the_shared_layers_own", top.code == 0 && listed && !top.stdout.contains("暂无命令") && !own.stdout.contains("暂无命令")
              && top.stdout.contains(AppLifecycleCLI.helpWindowOnly) && viaVerb.stdout == own.stdout && viaVerb.code == 0,
              lines.filter { !top.stdout.contains("\n" + $0 + "\n") })

        // 检查更新: only the isolated release record is read (APP_LIFECYCLE_CLOUD_DIR); nothing is downloaded or installed.
        mark("update")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let missing = await sift("update", "check")
        check("update_check_without_a_release_record", missing.code == 1 && missing.errorCode == "check_incomplete"
              && (missing.body["current"] as? [String: String]) == ["version": version, "build": build]
              && (missing.body["source"] as? [String: String]) == ["kind": "private_cloud", "channel": "default"], missing.stdout)
        let feed = cloud.appendingPathComponent("Sift/Updates/\(identifier)/default", isDirectory: true)
        try? files.createDirectory(at: feed, withIntermediateDirectories: true)
        func publish(_ version: String, _ build: String) async -> Outcome {
            let record: [String: Any] = ["version": version, "build": build, "bundle_id": identifier, "channel": "default",
                                         "filename": "Sift-\(version).zip", "sha256": String(repeating: "a", count: 64), "size_bytes": 10]
            try? JSONSerialization.data(withJSONObject: record).write(to: feed.appendingPathComponent("release.json"))
            return await sift("update", "check")
        }
        let newer = await publish("99.0", "1"), same = await publish(version, build), older = await publish("0.0.1", "1")
        let upgrade = newer.body["upgrade"] as? [String: Any]
        let text = await siftText("update", "check")
        check("update_check_reads_the_isolated_release_record", newer.code == 0 && newer.body["state"] as? String == "update_available"
              && newer.body["update_available"] as? Bool == true && (newer.body["latest"] as? [String: Any])?["version"] as? String == "99.0"
              && (upgrade?["how"] as? String)?.contains("「配置与更新…」") == true && upgrade?["button"] is String
              && same.body["state"] as? String == "up_to_date" && (same.body["upgrade"] as? [String: Any])?["button"] is NSNull
              && older.body["state"] as? String == "ahead_of_channel" && text.code == 0 && !text.stdout.isEmpty
              && ((try? files.contentsOfDirectory(atPath: feed.path)) ?? []) == ["release.json"], [newer.stdout, same.stdout, older.stdout])

        // 升级到新版 as a command, on the isolated release record. Nothing is ever replaced here: the dry run and the
        // missing --yes stop before the package, and the record's package file does not exist, so --yes fails at
        // verification, before the running app (this process) would be asked to quit.
        mark("update_install")
        func record(_ version: String, _ build: String) {
            let record: [String: Any] = ["version": version, "build": build, "bundle_id": identifier, "channel": "default",
                                         "filename": "Sift-\(version).zip", "sha256": String(repeating: "a", count: 64), "size_bytes": 10]
            try? JSONSerialization.data(withJSONObject: record).write(to: feed.appendingPathComponent("release.json"))
        }
        let executableStamp = stamp(executable)
        record("99.0", "1")
        let offered = await sift("update", "check")
        let plan = await sift("update", "install", "--dry-run"), unconfirmed99 = await sift("update", "install")
        let unverified = await sift("update", "install", "--yes")
        record(version, build)
        let nothingNewer = await sift("update", "install", "--yes"), nothingText = await siftText("update", "install", "--yes")
        record("0.0.1", "1")
        let ahead = await sift("update", "install", "--yes")
        let wrong = await sift("update", "install", "--no-such")
        let target = (plan.body["would_install"] as? [String: Any])?["to"] as? [String: String]
        check("update_install_plans_asks_and_replaces_nothing", (offered.body["upgrade"] as? [String: Any])?["command"] as? String == "sift update install --yes"
              && plan.code == 0 && plan.body["dry_run"] as? Bool == true && plan.body["installed"] as? Bool == false && target == ["version": "99.0", "build": "1"]
              && plan.body["installation"] as? String == "bundle" && plan.body["will_quit_app"] as? Bool == true && plan.body["app_running"] as? Bool == true
              && unconfirmed99.code == 2 && unconfirmed99.errorCode == "confirmation_required"
              && unverified.code == 1 && unverified.errorCode == "upgrade_failed" && unverified.body["error"] is String
              && nothingNewer.code == 0 && nothingNewer.body["installed"] as? Bool == false && nothingNewer.body["state"] as? String == "up_to_date"
              && nothingNewer.body["command"] as? String == "update install" && nothingText.code == 0 && !nothingText.stdout.isEmpty
              && ahead.code == 0 && ahead.body["installed"] as? Bool == false && ahead.body["state"] as? String == "ahead_of_channel"
              && wrong.code == 2 && wrong.errorCode == "usage"
              && stamp(executable) == executableStamp && ((try? files.contentsOfDirectory(atPath: feed.path)) ?? []) == ["release.json"],
              [offered.stdout, plan.stdout, unconfirmed99.stdout, unverified.stdout, nothingNewer.stdout, ahead.stdout, wrong.stdout])

        // The global shortcut as commands: the functions the Settings buttons call (HotkeySetting.apply), in this app.
        // Read back by a fresh process each time; the Settings window object the menu would present follows unasked.
        mark("hotkey")
        let panel = settings()
        _ = await sift("hotkey", "set", "cardinal")
        let preset = await sift("hotkey", "set", "cardinal"), shownPreset = await sift("hotkey"), statusPreset = await sift("status")
        let presetKey = shownPreset.body["hotkey"] as? [String: Any]
        check("hotkey_preset_is_the_settings_button", preset.code == 0 && preset.body["changed"] as? Bool == false && preset.body["command"] as? String == "hotkey set"
              && shownPreset.code == 0 && presetKey?["stored"] as? String == HotkeySetting.cardinal.stored && presetKey?["combo"] as? String == "cmd+shift+space"
              && presetKey?["display"] as? String == HotkeySetting.cardinal.display && shownPreset.body["registered"] as? Bool == true
              && shownPreset.body["in_use"] as? Bool == false && shownPreset.body["running"] as? Bool == true
              && ((statusPreset.body["gui"] as? [String: Any])?["hotkey"] as? [String: Any])?["stored"] as? String == HotkeySetting.cardinal.stored
              && hotkey.combo == HotkeySetting.cardinal && AppSettings.hotkey == HotkeySetting.cardinal
              && panel?.systemSettingsForTesting.recorderTitle == HotkeySetting.cardinal.display && panel?.systemSettingsForTesting.note == "",
              [preset.stdout, shownPreset.stdout, panel?.systemSettingsForTesting.recorderTitle ?? "no settings window"])
        let clearedKey = await sift("hotkey", "clear"), shownCleared = await sift("hotkey"), statusCleared = await sift("status")
        let clearedAgain = await sift("hotkey", "clear")
        check("hotkey_clear_is_the_clear_button", clearedKey.code == 0 && clearedKey.body["changed"] as? Bool == true && clearedKey.body["hotkey"] is NSNull
              && clearedKey.body["registered"] as? Bool == false && shownCleared.body["hotkey"] is NSNull && shownCleared.body["in_use"] as? Bool == false
              && (statusCleared.body["gui"] as? [String: Any])?["hotkey"] is NSNull && hotkey.combo == nil && AppSettings.hotkey == nil
              && panel?.systemSettingsForTesting.recorderTitle == "Not set" && clearedAgain.code == 0 && clearedAgain.body["changed"] as? Bool == false,
              [clearedKey.stdout, shownCleared.stdout, clearedAgain.stdout])
        let controlOptionK = GlobalHotkey.Combo(keyCode: 40, modifiers: [.control, .option])
        let named = await sift("hotkey", "set", "ctrl+option+k"), shownNamed = await sift("hotkey")
        let shiftOnly = await sift("hotkey", "set", "shift+a"), noModifier = await sift("hotkey", "set", "a"), unknownKey = await sift("hotkey", "set", "cmd+nokey")
        let noWord = await sift("hotkey", "set"), afterRefused = await sift("hotkey")
        check("hotkey_set_takes_a_named_combination_and_refuses_what_the_recorder_refuses", named.code == 0 && named.body["changed"] as? Bool == true
              && (shownNamed.body["hotkey"] as? [String: Any])?["combo"] as? String == "option+ctrl+k" && hotkey.combo == controlOptionK
              && AppSettings.hotkey == controlOptionK && panel?.systemSettingsForTesting.recorderTitle == controlOptionK.display
              && shiftOnly.code == 2 && shiftOnly.errorCode == "invalid_shortcut" && noModifier.code == 2 && noModifier.errorCode == "invalid_shortcut"
              && unknownKey.code == 2 && noWord.code == 2 && (afterRefused.body["hotkey"] as? [String: Any])?["combo"] as? String == "option+ctrl+k",
              [named.stdout, shiftOnly.stdout, noModifier.stdout, unknownKey.stdout, noWord.stdout])
        // Carbon itself, with one combination nobody uses (⌃⌥⇧⌘F20): accepted, then refused while this process holds
        // it elsewhere — the command reports the window's orange note — and accepted again once it is free.
        let obscure = GlobalHotkey.Combo(keyCode: 90, modifiers: [.command, .option, .control, .shift]), spelled = "cmd+option+ctrl+shift+keycode90"
        GlobalHotkey.realInIsolatedRun = obscure
        let accepted = await sift("hotkey", "set", spelled)
        _ = await sift("hotkey", "clear")
        let held = blocker.register(obscure)
        let refusedKey = await sift("hotkey", "set", spelled), shownRefused = await sift("hotkey")
        let noteShown = panel?.systemSettingsForTesting.note
        blocker.unregister()
        let freed = await sift("hotkey", "set", spelled), shownFreed = await sift("hotkey")
        let noteGone = panel?.systemSettingsForTesting.note
        _ = await sift("hotkey", "clear")
        GlobalHotkey.realInIsolatedRun = nil
        check("carbon_accepts_refuses_and_the_command_reports_the_windows_note", accepted.code == 0 && accepted.body["registered"] as? Bool == true && held
              && refusedKey.code == 1 && refusedKey.errorCode == "in_use" && refusedKey.body["in_use"] as? Bool == true && refusedKey.body["registered"] as? Bool == false
              && (refusedKey.body["hotkey"] as? [String: Any])?["stored"] as? String == obscure.stored && refusedKey.body["error"] is String
              && shownRefused.code == 0 && shownRefused.body["in_use"] as? Bool == true && noteShown == HotkeySetting.inUseNote
              && freed.code == 0 && freed.body["registered"] as? Bool == true && shownFreed.body["in_use"] as? Bool == false && noteGone == ""
              && hotkey.combo == nil && AppSettings.hotkey == nil,
              [accepted.stdout, refusedKey.stdout, shownRefused.stdout, freed.stdout, noteShown ?? "no settings window"])

        // Open Sift at login as a command: the checkbox's function (LoginItem.set). An isolated run only notes the
        // request, so macOS is never asked; what is checked is command → app → the same function → status → window.
        mark("login_item")
        let loginBefore = await sift("login-item"), statusLoginBefore = await sift("status")
        let loginOn = await sift("login-item", "on"), loginShown = await sift("login-item"), statusLoginOn = await sift("status")
        let checkedOn = panel?.systemSettingsForTesting.loginChecked
        let loginOnAgain = await sift("login-item", "on")
        let loginOff = await sift("login-item", "off"), statusLoginOff = await sift("status")
        let checkedOff = panel?.systemSettingsForTesting.loginChecked
        let loginBad = await sift("login-item", "maybe"), loginText = await siftText("login-item")
        check("login_item_is_the_checkbox", loginBefore.code == 0 && loginBefore.body["login_item"] as? String == "not_registered" && loginBefore.body["enabled"] as? Bool == false
              && statusLoginBefore.body["login_item"] as? String == "not_registered"
              && loginOn.code == 0 && loginOn.body["action"] as? String == "on" && loginOn.body["login_item"] as? String == "enabled" && loginOn.body["changed"] as? Bool == true
              && loginShown.body["enabled"] as? Bool == true && statusLoginOn.body["login_item"] as? String == "enabled" && checkedOn == true
              && loginOnAgain.code == 0 && loginOnAgain.body["changed"] as? Bool == false
              && loginOff.code == 0 && loginOff.body["login_item"] as? String == "not_registered" && loginOff.body["changed"] as? Bool == true
              && statusLoginOff.body["login_item"] as? String == "not_registered" && checkedOff == false
              && loginBad.code == 2 && loginText.code == 0 && loginText.stdout == "login item: not_registered\n",
              [loginBefore.stdout, loginOn.stdout, loginOnAgain.stdout, loginOff.stdout, loginBad.stdout, loginText.stdout])

        // Move to Trash as a command: the menu item's own call (FileActions.recycle → NSWorkspace), for real, on files
        // this run made on its throwaway volume. Their Trash is that volume's; the owner's Trash is not involved.
        mark("trash")
        if let volume = Self.trashVolume, (try? files.createDirectory(at: volume.appendingPathComponent("folder"), withIntermediateDirectories: true)) != nil {
            let one = volume.appendingPathComponent("one.txt"), two = volume.appendingPathComponent("two.txt"), kept = volume.appendingPathComponent("kept.txt")
            let folder = volume.appendingPathComponent("folder"), link = volume.appendingPathComponent("link"), absent = volume.appendingPathComponent("absent.txt")
            for file in [one, two, kept, folder.appendingPathComponent("inner.txt")] { files.createFile(atPath: file.path, contents: Data("x".utf8)) }
            try? files.createSymbolicLink(at: link, withDestinationURL: kept)
            func there(_ url: URL) -> Bool { (try? files.attributesOfItem(atPath: url.path)) != nil }   // the link itself, not its target
            let asked = await sift("trash", one.path)
            let withAbsent = await sift("trash", absent.path, two.path, "--yes")
            check("trash_needs_yes_and_moves_nothing_when_a_path_is_missing", asked.code == 2 && asked.errorCode == "confirmation_required" && there(one)
                  && withAbsent.code == 1 && withAbsent.errorCode == "not_found" && withAbsent.body["missing"] as? [String] == [absent.path] && there(two),
                  [asked.stdout, withAbsent.stdout])
            let moved = await sift("trash", one.path, folder.path, "--yes")
            let rows = moved.body["trashed"] as? [[String: String]] ?? []
            let inVolumeTrash = rows.count == 2 && rows.allSatisfy { ($0["trash_path"] ?? "").hasPrefix(volume.path + "/.Trashes/") && files.fileExists(atPath: $0["trash_path"] ?? "") }
            check("trash_moves_the_named_files_like_the_menu_item", moved.code == 0 && moved.body["command"] as? String == "trash" && moved.body["count"] as? Int == 2
                  && rows.map { $0["path"] ?? "" } == [one.path, folder.path] && inVolumeTrash && !there(one) && !there(folder) && there(two) && there(kept),
                  [moved.stdout, moved.stderr])
            // A relative path is the typed one; a symlink is moved itself and its target stays.
            let relative = await launch(self.link, ["trash", "two.txt", "--yes", "--json"], directory: volume)
            let linkMoved = await sift("trash", link.path, "--yes")
            check("trash_resolves_relative_paths_and_moves_a_link_not_its_target", relative.code == 0
                  && (relative.body["trashed"] as? [[String: String]])?.first?["path"] == two.path && !there(two)
                  && linkMoved.code == 0 && !there(link) && there(kept), [relative.stdout, linkMoved.stdout])
            var noApp = ProcessInfo.processInfo.environment
            noApp["SIFT_SUPPORT_DIR"] = empty.path
            let trashStopped = await launch(self.link, ["trash", kept.path, "--yes", "--json"], environment: noApp)
            let keyStopped = await launch(self.link, ["hotkey", "set", "cardinal", "--json"], environment: noApp)
            let keyShownStopped = await launch(self.link, ["hotkey", "--json"], environment: noApp)
            let loginStopped = await launch(self.link, ["login-item", "on", "--json"], environment: noApp)
            check("trash_hotkey_and_login_item_need_the_running_app", trashStopped.code == 3 && trashStopped.errorCode == "not_running" && there(kept)
                  && keyStopped.code == 3 && keyStopped.errorCode == "not_running" && loginStopped.code == 3 && loginStopped.errorCode == "not_running"
                  && keyShownStopped.code == 3 && keyShownStopped.body["ok"] as? Bool == true && keyShownStopped.body["running"] as? Bool == false
                  && keyShownStopped.body["registered"] is NSNull && hotkey.combo == nil && !LoginItem.enabled,
                  [trashStopped.stdout, keyStopped.stdout, keyShownStopped.stdout, loginStopped.stdout])
        } else {
            check("trash_volume_for_the_run", false, "no --trash-volume (scripts/accept/lifecycle.sh mounts one); the real Move to Trash was not exercised")
        }

        mark("owner")
        check("nothing_on_screen", NSApp.activationPolicy() == .prohibited && NSApp.windows.allSatisfy { !$0.isVisible })
        check("owner_settings_untouched", owned.map(stamp) == ownedBefore, ["before": ownedBefore, "after": owned.map(stamp)])
        details["back_to_back_regressions"] = regressions
        finish()
    }

    private func finish() {
        mark("done")
        let failed = checks.filter { !$0.1 }.map(\.0)
        let ok = !checks.isEmpty && failed.isEmpty
        let summary = ok
            ? "生命周期离屏自检 \(checks.count) 项通过：真实 sift 命令拨开关、导入、导出、检查更新、升级预演、全局快捷键、登录项、移到废纸篓，运行中的 App 跟随，存储值未被写回（共跑命令 \(commands) 条）"
            : "生命周期离屏自检 \(failed.count)/\(checks.count) 项失败：\(failed.joined(separator: ", "))"
        Self.emit(["ok": ok, "checks": Dictionary(checks, uniquingKeysWith: { $0 && $1 }), "failed": failed, "count": checks.count, "summary": summary,
                   "commands_run": commands, "not_followed": unfollowed, "details": details, "screenshots": ["lifecycle-window.png"],
                   "preference_domain": Bundle.main.bundleIdentifier ?? "",
                   "not_covered": ["the owner's real iCloud Drive and preference domain", "the real release channel in iCloud Drive",
                                   "a physical click on the window's switch", "a window that is actually on screen",
                                   "Carbon registration of an imported global shortcut (an isolated run takes no system-wide key, except ⌃⌥⇧⌘F20 for the hotkey check)",
                                   "a combination another app holds (on this macOS Carbon registers it anyway; the refusal seen here is this process holding it twice)",
                                   "SMAppService: the login item is only noted in an isolated run, macOS is never asked",
                                   "an update install that replaces the app (only the plan, the missing --yes, nothing newer and a package that fails verification)",
                                   "config status while no Sift runs (sync_status from record)",
                                   "the search window's list after sift trash (its files are outside this run's index)"]])
        engine.shutdown()   // removes the socket; the index it saves is the fixture's, in the folder removed next
        Self.cleanup()
        exit(ok ? 0 : 1)
    }

    nonisolated private static func cleanup() {
        if let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix(Lifecycle.isolatedBundlePrefix) {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
            UserDefaults.standard.synchronize()
        }
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    nonisolated private static func emit(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else {
            print(#"{"ok":false,"checks":{},"failed":["encode"],"summary":"JSON encode failed"}"#)
            fflush(stdout)
            return
        }
        print(line)
        fflush(stdout)
    }
}
