import AppKit
import Carbon.HIToolbox
import ServiceManagement

// What the window does to the owner's files and to this Mac's system registrations, each as one function. The menu
// and the Settings buttons call them, and so do the commands `sift trash`, `sift hotkey …` and `sift login-item …`
// (AppActions below), so a command and the window cannot drift apart.

enum FileActions {
    /// File › Move to Trash (⌘⌫, after its dialog) and `sift trash … --yes`: the Finder's own move, so Put Back works.
    /// The completion runs on the main queue with the new locations of what was moved and the error for the rest.
    static func recycle(_ urls: [URL], completion: @escaping (_ moved: [URL: URL], _ error: Error?) -> Void) {
        NSWorkspace.shared.recycle(urls, completionHandler: completion)
    }
}

/// Settings › Show/hide Sift from any app.
enum HotkeySetting {
    /// The button Use ⇧⌘Space (as in Cardinal) and `sift hotkey set cardinal`.
    static let cardinal = GlobalHotkey.Combo(keyCode: UInt32(kVK_Space), modifiers: [.command, .shift])
    /// The orange note next to the recorder; `sift hotkey` reports it as in_use.
    static let inUseNote = "新组合已被占用，原快捷键保留"

    struct State {
        let stored: GlobalHotkey.Combo?
        let registered: Bool
        var rejected = false
        /// A combination is stored, but the system did not register it.
        var inUse: Bool { rejected || (stored != nil && !registered) }
    }

    static func state(_ hotkey: GlobalHotkey) -> State {
        State(stored: AppSettings.hotkey, registered: hotkey.combo != nil, rejected: hotkey.rejected)
    }

    /// The recorder, Clear, the preset button, `sift hotkey set` and `sift hotkey clear`: the combination is stored
    /// (nil forgets it), then registered or unregistered. A refused registration leaves it stored, with the note.
    @discardableResult
    static func apply(_ combo: GlobalHotkey.Combo?, to hotkey: GlobalHotkey) -> State {
        if let combo {
            guard hotkey.register(combo) else { return state(hotkey) }
        } else { hotkey.unregister() }
        AppSettings.hotkey = combo
        ShortcutCatalog.write()
        return state(hotkey)
    }
}

/// Settings › Open Sift at login and `sift login-item`: this app as a login item (SMAppService).
enum LoginItem {
    private static let lock = NSLock()
    private static var asked = SMAppService.Status.notRegistered

    /// An isolated run (the lifecycle self-test on its throwaway copy) registers nothing with macOS: it only notes
    /// what was asked for, as GlobalHotkey.register does. `sift status` reads this on its socket thread.
    static var status: SMAppService.Status {
        guard Lifecycle.isolated else { return SMAppService.mainApp.status }
        lock.lock(); defer { lock.unlock() }
        return asked
    }
    static var enabled: Bool { status == .enabled }

    /// The checkbox and `sift login-item on|off`.
    static func set(_ on: Bool) throws {
        if Lifecycle.isolated {
            lock.lock(); asked = on ? .enabled : .notRegistered; lock.unlock()
            return
        }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// The names `sift status` gives the same four states (core/src/service.rs).
    static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not_registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires_approval"
        case .notFound: return "not_found"
        @unknown default: return "unknown"
        }
    }
}

/// The app's side of `sift trash`, `sift hotkey …` and `sift login-item …`. The CLI (core/src/bin/sift.rs) sends
/// them over its socket as an `app` request; the core (Service.app_action) calls the handler below on that
/// request's thread. The work is done on the main thread by the functions above, and the windows that show the
/// changed value follow. Replies are one JSON object: ok, and on failure code and error.
enum AppActions {
    private static weak var hotkey: GlobalHotkey?
    private static weak var search: SearchWindowController?
    private static var settings: () -> SettingsWindowController? = { nil }

    static func install(engine: Engine, hotkey: GlobalHotkey, search: SearchWindowController,
                        settings: @escaping () -> SettingsWindowController?) {
        self.hotkey = hotkey; self.search = search; self.settings = settings
        engine.setActionHandler { request in
            guard let request else { return nil }
            return strdup(AppActions.answer(String(cString: request)))
        }
    }

    private static func answer(_ text: String) -> String {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let action = request["action"] as? String else { return line(failure("usage", "the request names no action")) }
        switch action {
        case "trash": return line(trash(request))
        case "shortcuts", "shortcut_set", "shortcut_clear", "saved", "saved_add", "saved_remove", "file_info", "file_rename":
            return line(onMain(seconds: 20) { features(action, request) })
        case "hotkey", "hotkey_set", "hotkey_clear", "login_item", "login_item_set":
            return line(onMain(seconds: 20) { system(action, request) })
        default: return line(failure("usage", "unknown action \(action)"))
        }
    }

    // MARK: Move to Trash

    private static func features(_ action: String, _ request: [String: Any]) -> [String: Any] {
        guard !Prefs.headless else { return failure("unavailable", "headless 实例不更改窗口设置或本人文件") }
        do {
            switch action {
            case "shortcuts": return ["ok":true,"shortcuts":SiftShortcuts.shared.list()]
            case "shortcut_set":
                guard let id = request["id"] as? String, let stored = request["stored"] as? String,
                      let combo = GlobalHotkey.Combo(stored:stored) else { return failure("usage","需要操作和有效组合键") }
                if let error = SiftShortcuts.shared.set(id, combo:combo, scope:request["scope"] as? String ?? "app") { return failure("invalid_shortcut",error) }
                settings()?.showSystemSettings()
                return ["ok":true,"shortcuts":SiftShortcuts.shared.list()]
            case "shortcut_clear":
                guard let id = request["id"] as? String else { return failure("usage","需要操作 id") }
                if id == "all" { SiftShortcuts.shared.clearAll() }
                else if id == "defaults" { SiftShortcuts.shared.reset() }
                else if let error = SiftShortcuts.shared.set(id, combo:nil, scope:"app") { return failure("usage",error) }
                settings()?.showSystemSettings()
                return ["ok":true,"shortcuts":SiftShortcuts.shared.list()]
            case "saved": return ["ok":true,"searches":SavedSearches.items]
            case "saved_add":
                try SavedSearches.add(name:request["name"] as? String ?? "",query:request["query"] as? String ?? "",folder:request["dir"] as? String ?? "",caseInsensitive:request["case_insensitive"] as? Bool ?? true)
                settings()?.showSystemSettings()
                return ["ok":true,"searches":SavedSearches.items]
            case "saved_remove":
                SavedSearches.remove(request["name"] as? String ?? "")
                settings()?.showSystemSettings()
                return ["ok":true,"searches":SavedSearches.items]
            case "file_info": return try ProductFiles.info(request["path"] as? String ?? "")
            case "file_rename":
                guard request["confirmed"] as? Bool == true else { return failure("confirmation_required","重命名需要 --yes") }
                let path = request["path"] as? String ?? ""
                guard path.hasPrefix("/") else { return failure("usage","请提供绝对路径") }
                let target = try ProductFiles.rename(path,to:request["name"] as? String ?? "")
                search?.resultsMayHaveChanged()
                return ["ok":true,"path":target.path]
            default: return failure("usage","未知操作")
            }
        } catch { return failure("failed",error.localizedDescription) }
    }

    private static func trash(_ request: [String: Any]) -> [String: Any] {
        guard request["confirmed"] as? Bool == true else {
            return failure("confirmation_required", "moving files to the Trash needs the confirmation (sift trash … --yes)")
        }
        guard let paths = request["paths"] as? [String], !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && $0 != "/" }) else {
            return failure("usage", "trash needs absolute paths")
        }
        var outcome: (moved: [URL: URL], error: Error?)?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            FileActions.recycle(paths.map { URL(fileURLWithPath: $0) }) { moved, error in
                outcome = (moved, error)
                search?.resultsMayHaveChanged()
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + 110) == .success, let outcome else {
            return failure("timeout", "the move to the Trash did not finish within 110 s; look at the paths before trying again")
        }
        let moved = Dictionary(outcome.moved.map { ($0.key.path, $0.value.path) }, uniquingKeysWith: { first, _ in first })
        let trashed = paths.compactMap { path in moved[path].map { ["path": path, "trash_path": $0] } }
        let left = paths.filter { moved[$0] == nil }
        guard !left.isEmpty else { return ["ok": true, "trashed": trashed] }
        // One error comes back for all that stayed; where it names a file, that file gets its own reason.
        let whole = outcome.error?.localizedDescription ?? "the system did not move it"
        let underlying = ((outcome.error as NSError?)?.userInfo["NSUnderlyingErrors"] as? [NSError]) ?? []
        func reason(_ path: String) -> String {
            underlying.first { ($0.userInfo[NSURLErrorKey] as? URL)?.path == path }?.localizedDescription ?? whole
        }
        var reply = failure("trash_failed", "\(left.count) of \(paths.count) could not be moved to the Trash: \(reason(left[0]))")
        reply["trashed"] = trashed
        reply["failed"] = left.map { ["path": $0, "error": reason($0)] }
        return reply
    }

    // MARK: Global shortcut and login item

    private static func system(_ action: String, _ request: [String: Any]) -> [String: Any] {
        // A --headless instance is a verification run: it never takes a system-wide key (the stored combination is
        // the owner's, unregistered here) and must not change a login item. Reading the login item is harmless.
        if Prefs.headless && action != "login_item" {
            return failure("unavailable", "this Sift runs --headless (a verification instance): it has no global shortcut and changes no login item")
        }
        switch action {
        case "login_item": return describe(LoginItem.status)
        case "login_item_set":
            guard let on = request["on"] as? Bool else { return failure("usage", "login_item_set needs on") }
            let before = LoginItem.status
            // Asking for the state it already has registers nothing, as the checkbox cannot be set to what it shows.
            if (before == .enabled) != on {
                do { try LoginItem.set(on) } catch {
                    settings()?.showSystemSettings()
                    return failure("login_item_failed", error.localizedDescription).merging(describe(LoginItem.status)) { mine, _ in mine }
                }
            }
            settings()?.showSystemSettings()
            let now = LoginItem.status
            return describe(now).merging(["changed": now != before]) { $1 }
        default: break
        }
        guard let hotkey else { return failure("failed", "Sift has no global shortcut object yet") }
        switch action {
        case "hotkey": return describe(HotkeySetting.state(hotkey))
        case "hotkey_clear": return apply(nil, hotkey)
        default:
            let combo = request["preset"] as? String == "cardinal" ? HotkeySetting.cardinal
                : (request["stored"] as? String).flatMap(GlobalHotkey.Combo.init(stored:))
            guard let combo, combo.isUsable else {
                return failure("invalid_shortcut", "a global shortcut needs a key with cmd, option or ctrl (shift alone is not enough), as the recorder in Settings requires")
            }
            return apply(combo, hotkey)
        }
    }

    private static func apply(_ combo: GlobalHotkey.Combo?, _ hotkey: GlobalHotkey) -> [String: Any] {
        let before = HotkeySetting.state(hotkey)
        let now = HotkeySetting.apply(combo, to: hotkey)
        settings()?.showSystemSettings()
        return describe(now).merging(["changed": before.stored != now.stored || before.registered != now.registered]) { $1 }
    }

    private static func describe(_ state: HotkeySetting.State) -> [String: Any] {
        ["ok": true, "stored": state.stored?.stored ?? NSNull(), "display": state.stored?.display ?? NSNull(),
         "registered": state.registered, "in_use": state.inUse]
    }

    private static func describe(_ status: SMAppService.Status) -> [String: Any] {
        ["ok": true, "login_item": LoginItem.name(status), "enabled": status == .enabled]
    }

    // MARK: Plumbing

    /// The request's own thread waits here while the main thread does the work.
    private static func onMain(seconds: Double, _ work: @escaping () -> [String: Any]) -> [String: Any] {
        var reply: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { reply = work(); done.signal() }
        guard done.wait(timeout: .now() + seconds) == .success, let reply else {
            return failure("busy", "Sift's main thread did not get to it within \(Int(seconds)) s; read the state before trying again")
        }
        return reply
    }

    private static func failure(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "code": code, "error": message]
    }

    private static func line(_ body: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"ok":false,"code":"failed","error":"the answer could not be written"}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
