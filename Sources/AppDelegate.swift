import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var engine: Engine!
    private var searchWindow: SearchWindowController!
    private var settingsWindow: SettingsWindowController?
    private var hotkey: GlobalHotkey!
    private var configuration: AppConfiguration?
    /// How often settings brought in from outside (an import, another Mac through iCloud) were re-read.
    private var lifecycleReloads = 0
    private var historyObserver: NSObjectProtocol?
    private var localHistoryObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?

    static let supportDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["SIFT_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cyou.tianli.sift", isDirectory: true)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before supportDirectory is read: both runs index their own temp fixture, never the user's index.
        if CommandLine.arguments.contains("--ui-self-test") { UISelfTest.prepareEnvironment() }
        else if Prefs.laneQuiet { UISelfTest.prepareEnvironment(settle: false) }
        if Prefs.readOnly { setenv("SIFT_READONLY", "1", 1) } // snapshot runs never write the index
        #if APP_STORE
        // The sandboxed build indexes the folder the user granted: its scope is opened and config.json's root is
        // made that folder before the engine reads either.
        IndexAccess.prepare(supportDirectory: Self.supportDirectory)
        #endif
        guard let started = Engine(supportDirectory: Self.supportDirectory) else {
            NSApp.terminate(nil)
            return
        }
        engine = started
        searchWindow = SearchWindowController(engine: engine)
        hotkey = GlobalHotkey { [weak self] in self?.searchWindow.toggle() }
        SiftShortcuts.shared.primary = hotkey
        SiftShortcuts.shared.perform = { [weak self] id in self?.performShortcut(id) }
        // No system-wide shortcut until the user records one in Settings.
        if !Prefs.headless, !Prefs.readOnly, let combo = AppSettings.hotkey { hotkey.register(combo) }
        // `sift trash`, `sift hotkey …`, `sift login-item …`: done here by the window's own functions. A snapshot or
        // self-test run has no CLI socket (SIFT_READONLY), so nothing can reach them there.
        AppActions.install(engine: engine, hotkey: hotkey, search: searchWindow, settings: { [weak self] in self?.settingsWindow })
        if !Prefs.headless, !Prefs.readOnly, let store = Lifecycle.store() { installLifecycle(store) }
        #if APP_STORE
        // An isolated verification run answers for the open panel (IndexAccess.testGrantVariable): the folder is
        // granted to the running engine exactly as the panel's answer is.
        if !Prefs.readOnly, let folder = IndexAccess.testGrant {
            DispatchQueue.main.async { [engine] in
                if let engine, let error = IndexAccess.grant(folder, engine: engine) { fputs("store access: \(error)\n", stderr) }
            }
        }
        #else
        // `sift history clear --yes` (core/src/bin/sift.rs, prefs::clear_recent_searches) names this app's own
        // preference domain, so a test run on another domain never reaches the owner's window.
        if !Prefs.headless, !Prefs.readOnly, let domain = Bundle.main.bundleIdentifier {
            historyObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("cyou.tianli.sift.recent-searches-cleared." + domain), object: nil, queue: .main
            ) { [weak self] _ in self?.searchWindow.clearRecentSearches() }
        }
        #endif
        NSApp.mainMenu = buildMenu()
        if !Prefs.readOnly, !Prefs.headless { SiftShortcuts.shared.reload();updateMenuBar() }
        localHistoryObserver = NotificationCenter.default.addObserver(forName:.init("SiftClearHistory"),object:nil,queue:.main) { [weak self] _ in self?.searchWindow.clearRecentSearches() }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            runSnapshot(to: URL(fileURLWithPath: args[i + 1]), args: args)
            return
        }
        if args.contains("--ui-self-test") {
            UISelfTest.start(engine: engine, searchWindow: searchWindow, hotkey: hotkey, args: args)
            return
        }
        #if !APP_STORE
        if Prefs.lifecycleSelfTest {
            LifecycleSelfTest.start(engine: engine, searchWindow: searchWindow, hotkey: hotkey, configuration: configuration,
                                    reloads: { [weak self] in self?.lifecycleReloads ?? 0 },
                                    settings: { [weak self] in self?.settingsWindowUnshown() })
            return
        }
        #endif
        if Prefs.laneQuiet {
            searchWindow.prepareOffscreen(size: NSSize(width: 1000, height: 600))
            announceLaneReady()
            return
        }
        if !args.contains("--background") && !Prefs.headless {
            searchWindow.show()
        }
    }

    /// The「配置与更新…」window's wiring. `sift config status|export|import|sync` and `sift update check` build the same
    /// configuration from the same factory (Lifecycle) in their own process; the lifecycle self-test runs this
    /// function on its throwaway store.
    private func installLifecycle(_ store: Lifecycle.Store) {
        let config = Lifecycle.makeConfiguration(store)
        let file = store.supportDirectory.appendingPathComponent("config.json")
        // The portable settings as this app last applied or stored them. `onChange` also fires when a command only
        // turned the iCloud switch; reloading then would re-run the search and drop an open Settings window for
        // nothing, so it reloads only when what is stored differs from this. The app's own writes are noted key by
        // key (never by re-reading the store: that could take in a command's import before it was applied here).
        // `sift config set` goes through the engine without passing here; the next command then causes one re-read
        // that changes nothing.
        var applied = Lifecycle.storedValues(config)
        Prefs.didWrite = { key, value in
            guard Lifecycle.defaultsKeys.contains(key) else { return }
            if let value { applied?["defaults." + key] = value } else { applied?.removeValue(forKey: "defaults." + key) }
        }
        Prefs.didSaveIndexSettings = { [weak config] in
            guard let config, let stored = Lifecycle.storedValues(config) else { return }
            applied = (applied ?? [:]).filter { !$0.key.hasPrefix("file.") }.merging(stored.filter { $0.key.hasPrefix("file.") }) { $1 }
        }
        config.onChange = { [weak self, weak config] in
            guard let self, let config else { return }
            let stored = Lifecycle.storedValues(config)
            guard !Lifecycle.same(stored, applied) else { return }
            // The engine saves what it is handed, so it is only handed index settings that differ from the ones
            // it already has: a rewrite of an unchanged config.json could land on top of a command's next import.
            let index: ([String: Any]?) -> [String: Any]? = { $0?.filter { $0.key.hasPrefix("file.") } }
            let indexChanged = !Lifecycle.same(index(stored), index(applied))
            let previousShortcut = self.hotkey.combo
            if let combo = AppSettings.hotkey {
                if !self.hotkey.register(combo) {
                    AppSettings.hotkey = previousShortcut
                    self.searchWindow.reportConfigurationError("导入的快捷键被占用，原绑定保留。")
                }
            } else { self.hotkey.unregister() }
            self.searchWindow.reloadConfiguration()
            #if APP_STORE
            // Whatever arrived, the index root stays the folder granted on this Mac (the root is not among this
            // build's portable settings; this also covers a config.json written by hand or by an older build).
            IndexAccess.enforceRoot(in: file)
            #endif
            if indexChanged, let data = try? Data(contentsOf: file) {
                let previous = self.engine.settingsJSON()
                if let error = self.engine.updateSettings(data) {
                    if let previous { try? previous.write(to: file, options: .atomic) }
                    self.searchWindow.reportConfigurationError("配置未应用，保留原索引范围：" + error)
                }
            }
            if let data = try? Data(contentsOf: store.supportDirectory.appendingPathComponent("runtime.json")),
               let runtime = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                var request:[String:Any] = ["action":"set"]
                for key in ["auto_repair","auto_snapshot"] { if let value = runtime[key] as? Bool { request[key] = value } }
                _ = self.engine.control(request)
            }
            self.settingsWindow?.reloadConfiguration()
            SiftShortcuts.shared.reload()
            self.updateMenuBar()
            // After the engine saved its normalized copy, so that rewrite is not taken for another change.
            applied = Lifecycle.storedValues(config)
            self.lifecycleReloads += 1
        }
        configuration = config
        #if APP_STORE
        // No「配置与更新…」window in the Mac App Store build: the App Store delivers its updates. The settings still
        // travel: Settings has the iCloud switch and Export / Import (StoreConfiguration), on this same object.
        config.start()
        StoreConfiguration.current = config
        #else
        let settings = settingsWindowUnshown()
        AppLifecycleUI.shared.productGroups = { [weak settings] in settings?.groups() ?? [] }
        AppLifecycleUI.shared.willShow = { [weak settings] in settings?.showSystemSettings() }
        AppLifecycleUI.shared.canInstallUpdate = { [weak self] in
            guard let self else { return false };let d = self.engine.details()
            return Lifecycle.installable(d)
        }
        AppLifecycleUI.install(name: Lifecycle.name, configuration: config, updateSource: Lifecycle.updateSource)
        // `sift config sync` and `sift config import` run in another process. The running window follows them (the
        // switch, the status line, the imported settings); the command stays the only writer of the switch.
        AppLifecycleCLI.follow(config)
        #endif
    }

    /// `-lane_quiet YES`: the window is built and laid out but never shown. Ready is logged once the index
    /// answers `ready` and the status line shows its count, which is what a background launch gives the user.
    private func announceLaneReady() {
        guard searchWindow.refreshStatusForTesting().state == .ready else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.announceLaneReady() }
            return
        }
        searchWindow.window?.contentView?.layoutSubtreeIfNeeded()
        MainActor.assumeIsolated { LaneSignal.ready("search") }
    }

    /// `--snapshot out.png --query q [--select n] [--sort size] [--folder q] [--case] [--dark|--light]`:
    /// renders the search window offscreen and exits without saving the index.
    private func runSnapshot(to url: URL, args: [String]) {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        hotkey.unregister()
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if args.contains("--settings") {
            let settings = SettingsWindowController(engine: engine, hotkey: hotkey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                do { try settings.writeSnapshot(to: url) } catch { fputs("\(error)\n", stderr) }
                exit(0)
            }
            return
        }
        searchWindow.prepareOffscreen(size: NSSize(width: 1000, height: 600))
        searchWindow.applyScripted(
            select: value("--select").flatMap(Int.init),
            sort: value("--sort").flatMap { ["name": .name, "path": .path, "size": .size, "modified": .modified, "created": .created][$0] },
            folderScope: value("--folder"),
            caseSensitive: args.contains("--case"))
        searchWindow.setQuery(value("--query") ?? "")
        // `--keys down,down,cmd+2,text:abc`: replayed in the offscreen window after results load.
        var keys = value("--keys").map { $0.split(separator: ",").map(String.init) } ?? []
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            waited += 0.2
            guard let self, self.searchWindow.snapshotReady || waited > 60 else { return }
            if !keys.isEmpty {
                let key = keys.removeFirst()
                self.searchWindow.sendScriptedKey(key)
                fputs("key \(key) -> row \(self.searchWindow.selectedRowForTesting) focus \(self.searchWindow.focusForTesting) query \"\(self.searchWindow.queryForTesting)\"\n", stderr)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                do { try self.searchWindow.writeSnapshot(to: url) } catch { fputs("\(error)\n", stderr) }
                #if APP_STORE
                // The sandboxed build can only write the picture inside its container; the same facts as text.
                let shown = self.searchWindow.refreshStatusForTesting()
                fputs("snapshot: results=\(self.searchWindow.resultCountForTesting) rows=\(self.searchWindow.rowNamesForTesting(limit: 5))"
                      + " status=\"\(shown.status)\" count=\"\(shown.count)\" state=\(shown.state)\n", stderr)
                #endif
                exit(0)
            }
            timer.invalidate()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        searchWindow.show()
        return false
    }

    /// Activated by an app launcher (e.g. Hammerspoon right ⌘ + C → launchOrFocus),
    /// ⌘Tab or the Dock while the search window was put away with Esc: bring it back.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Prefs.readOnly, !Prefs.headless, !Prefs.lifecycleSelfTest, let searchWindow else { return }
        if !NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) {
            searchWindow.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.unregister()
        engine?.shutdown() // saves index changes
        if Prefs.laneQuiet { UISelfTest.cleanupFixture() }
    }

    @objc func showSettings(_ sender: Any?) {
        if Prefs.dryRun("show settings", []) { return }
        settingsWindowUnshown().present()
    }

    /// The Settings window object the menu item presents, built and loaded but not shown (the lifecycle self-test
    /// reads from it what an open Settings window would show after a command).
    private func settingsWindowUnshown() -> SettingsWindowController {
        if let settingsWindow { return settingsWindow }
        let window = SettingsWindowController(engine: engine, hotkey: hotkey)
        window.onSelectQuery = { [weak self] query in self?.searchWindow.setQuery(query);self?.searchWindow.show() }
        window.onSelectSaved = { [weak self] saved in self?.searchWindow.restoreSavedSearch(saved);self?.searchWindow.show() }
        window.onPreferencesChange = { [weak self] in self?.updateMenuBar() }
        window.onSaveCurrentSearch = { [weak self] parent in self?.searchWindow.saveCurrentSearch(parent) }
        #if APP_STORE
        window.onIndexFolderChange = { [weak self] in self?.searchWindow.indexFolderChanged($0) }
        #endif
        settingsWindow = window
        return window
    }

    @objc func showSearch(_ sender: Any?) { searchWindow.show() }
    @objc func showHelp(_ sender: Any?) { settingsWindowUnshown().showHelp() }
    @objc private func toggleIndex(_ sender:Any?) {
        let paused = engine.details()["paused"] as? Bool == true
        _ = engine.control(["action":paused ? "resume" : "pause"])
        settingsWindow?.showSystemSettings();updateMenuBar()
    }
    private func updateMenuBar() {
        guard !Prefs.readOnly,!Prefs.headless,!Prefs.lifecycleSelfTest else { return }
        guard UserDefaults.standard.bool(forKey:"menuBar") else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) };statusItem = nil;return
        }
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);statusItem?.button?.image = NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:"Sift") }
        let menu = statusItem?.menu ?? NSMenu()
        menu.delegate = self;refreshStatusMenu(menu);statusItem?.menu = menu
    }
    func menuNeedsUpdate(_ menu:NSMenu) {
        if menu === statusItem?.menu { refreshStatusMenu(menu) }
    }
    private func refreshStatusMenu(_ menu:NSMenu) {
        menu.removeAllItems()
        let details = engine.details()
        let state = item(SiftDiagnostics.summary(details),nil);state.isEnabled = false;menu.addItem(state)
        menu.addItem(item("打开 Sift",#selector(showSearch(_:)),target:self))
        menu.addItem(item(details["paused"] as? Bool == true ? "恢复索引" : "暂停索引",#selector(toggleIndex(_:)),target:self))
        menu.addItem(item("设置…",#selector(showSettings(_:)),target:self))
        #if !APP_STORE
        AppLifecycleUI.menuItems().forEach{menu.addItem($0)}
        #endif
        menu.addItem(.separator());menu.addItem(item("退出 Sift",#selector(NSApplication.terminate(_:)),"q"))
    }
    private func performShortcut(_ id:String) {
        if id == "show" { searchWindow.toggle();return }
        guard let action = ShortcutAction.all.first(where:{$0.id == id}) else { return }
        if action.fileAction, searchWindow.focusForTesting != "table" || searchWindow.window?.isKeyWindow != true || !NSApp.isActive { NSSound.beep();return }
        if !action.fileAction && id != "settings" && id != "help" { searchWindow.show() }
        let menuItem = NSMenuItem(title:action.title,action:NSSelectorFromString(action.selector),keyEquivalent:"");menuItem.tag = action.tag
        if id == "settings" { showSettings(nil) } else if id == "help" { showHelp(nil) }
        else { _ = searchWindow.perform(NSSelectorFromString(action.selector),with:menuItem) }
    }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target
        item.tag = tag
        return item
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let sw = searchWindow!

        let app = NSMenu(title: "Sift")
        app.addItem(item("About Sift", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(showSettings(_:)), ",", target: self))
        #if !APP_STORE
        for item in AppLifecycleUI.menuItems() { app.addItem(item) }
        #endif
        app.addItem(.separator())
        app.addItem(item("Hide Sift", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit Sift", #selector(NSApplication.terminate(_:)), "q"))

        let file = NSMenu(title: "File")
        file.addItem(item("Open", #selector(SearchWindowController.openSelection(_:)), "o", target: sw))
        file.addItem(item("Show in Finder", #selector(SearchWindowController.revealSelection(_:)), "r", target: sw))
        file.addItem(item("用其他应用打开…",#selector(SearchWindowController.openWithSelection(_:)),target:sw))
        file.addItem(item("文件信息",#selector(SearchWindowController.showFileInfo(_:)),target:sw))
        file.addItem(item("重命名…",#selector(SearchWindowController.renameSelection(_:)),target:sw))
        // Space previews (list only); no menu key, so Space in the search field stays a space.
        file.addItem(item("Quick Look", #selector(SearchWindowController.toggleQuickLook(_:)), "", [], target: sw))
        file.addItem(.separator())
        file.addItem(item("Move to Trash", #selector(SearchWindowController.moveToTrash(_:)),
                          String(UnicodeScalar(NSBackspaceCharacter)!), target: sw))
        file.addItem(.separator())
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "Z"))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Copy Path", #selector(SearchWindowController.copyPaths(_:)), "C", target: sw))
        // ⌃⇧⌘N = "copy file names" in Finder (Hammerspoon, right ⌥ + N): same key here.
        edit.addItem(item("Copy Name", #selector(SearchWindowController.copyNames(_:)), "n", [.command, .control, .shift], target: sw))

        let search = NSMenu(title: "Search")
        search.addItem(item("Find", #selector(SearchWindowController.focusSearch(_:)), "f", target: sw))
        search.addItem(item("Focus Search Field", #selector(SearchWindowController.focusSearch(_:)), "l", target: sw))
        // ⌘Y opens history, as in Safari and Chrome.
        search.addItem(item("Recent Searches", #selector(SearchWindowController.showHistory(_:)), "y", target: sw))
        search.addItem(item("常用搜索",#selector(SearchWindowController.showSavedSearches(_:)),target:sw))
        search.addItem(item("保存当前搜索…",#selector(SearchWindowController.saveCurrentSearch(_:)),target:sw))
        search.addItem(item("导出搜索结果…",#selector(SearchWindowController.exportResults(_:)),target:sw))
        search.addItem(.separator())
        search.addItem(item("Match Case", #selector(SearchWindowController.toggleCase(_:)), "i", target: sw))
        search.addItem(.separator())
        let sorts: [(String, SortKey)] = [("Sort by Name", .name), ("Sort by Folder", .path),
                                          ("Sort by Size", .size), ("Sort by Date Modified", .modified),
                                          ("Sort by Date Created", .created)]
        for (i, (title, key)) in sorts.enumerated() {
            search.addItem(item(title, #selector(SearchWindowController.sortMenu(_:)), String(i + 1),
                                target: sw, tag: Int(key.rawValue)))
        }
        search.addItem(.separator())
        search.addItem(item("Re-index Everything", #selector(SearchWindowController.rescan(_:)), "R", target: sw))
        #if APP_STORE
        search.addItem(item("Choose Folder to Index…", #selector(SearchWindowController.chooseIndexFolder(_:)), "", target: sw))
        #endif

        let window = NSMenu(title: "Window")
        window.addItem(item("Search Window", #selector(showSearch(_:)), "0", target: self))
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("缩放",#selector(NSWindow.performZoom(_:))))
        NSApp.windowsMenu = window
        let help = NSMenu(title:"帮助")
        help.addItem(item("使用指南与快捷键",#selector(showHelp(_:)),target:self))
        NSApp.helpMenu = help
        for menu in [app, file, edit, search, window, help] {
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
        }
        SiftText.menu(main)
        return main
    }
}
