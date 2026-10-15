import AppKit
import Carbon.HIToolbox

struct ShortcutAction {
    let id: String
    let title: String
    let selector: String
    let key: UInt32?
    let modifiers: NSEvent.ModifierFlags
    var tag: Int = 0
    var fileAction = false
    static let all: [ShortcutAction] = [
        .init(id: "show", title: "显示/隐藏搜索窗", selector: "showSearch:", key: nil, modifiers: []),
        .init(id: "settings", title: "打开设置", selector: "showSettings:", key: 43, modifiers: .command),
        .init(id: "find", title: "聚焦搜索并全选", selector: "focusSearch:", key: 3, modifiers: .command),
        .init(id: "history", title: "最近搜索", selector: "showHistory:", key: 16, modifiers: .command),
        .init(id: "scope", title: "统一搜索框（旧范围键兼容）", selector: "toggleFolderScope:", key: nil, modifiers: []),
        .init(id: "case", title: "区分大小写", selector: "toggleCase:", key: 34, modifiers: .command),
        .init(id: "sort-name", title: "按名称排序", selector: "sortMenu:", key: 18, modifiers: .command, tag: 0),
        .init(id: "sort-folder", title: "按文件夹排序", selector: "sortMenu:", key: 19, modifiers: .command, tag: 1),
        .init(id: "sort-size", title: "按大小排序", selector: "sortMenu:", key: 20, modifiers: .command, tag: 2),
        .init(id: "sort-modified", title: "按修改时间排序", selector: "sortMenu:", key: 21, modifiers: .command, tag: 3),
        .init(id: "sort-created", title: "按创建时间排序", selector: "sortMenu:", key: 23, modifiers: .command, tag: 4),
        .init(id: "rescan", title: "重建索引", selector: "rescan:", key: 15, modifiers: [.command, .shift]),
        .init(id: "open", title: "打开所选文件", selector: "openSelection:", key: 31, modifiers: .command, fileAction: true),
        .init(id: "reveal", title: "在 Finder 中显示", selector: "revealSelection:", key: 15, modifiers: .command, fileAction: true),
        .init(id: "copy-path", title: "复制路径", selector: "copyPaths:", key: 8, modifiers: [.command, .shift], fileAction: true),
        .init(id: "copy-name", title: "复制文件名", selector: "copyNames:", key: 45, modifiers: [.command, .control, .shift], fileAction: true),
        .init(id: "trash", title: "移到废纸篓…", selector: "moveToTrash:", key: 51, modifiers: .command, fileAction: true),
        .init(id: "save-search", title: "保存常用搜索…", selector: "saveCurrentSearch:", key: nil, modifiers: []),
        .init(id: "export", title: "导出搜索结果…", selector: "exportResults:", key: nil, modifiers: []),
        .init(id: "info", title: "文件信息", selector: "showFileInfo:", key: nil, modifiers: [], fileAction: true),
        .init(id: "rename", title: "重命名…", selector: "renameSelection:", key: nil, modifiers: [], fileAction: true),
        .init(id: "help", title: "使用指南与快捷键", selector: "showHelp:", key: nil, modifiers: [])
    ]
}

final class SiftShortcuts {
    static let shared = SiftShortcuts()
    static let fixedAppKeyCodes:[UInt32] = [37,29,36]
    private var global: [String: GlobalHotkey] = [:]
    private var errors: [String:String] = [:]
    weak var primary: GlobalHotkey?
    var perform: ((String) -> Void)?
    private var overrides: [String: [String: String]] {
        get { UserDefaults.standard.dictionary(forKey: "shortcuts.v1") as? [String: [String: String]] ?? [:] }
        set { Prefs.set(newValue, forKey: "shortcuts.v1") }
    }
    func scope(_ id: String) -> String { id == "show" ? "global" : overrides[id]?["scope"] ?? "app" }
    func combo(_ action: ShortcutAction) -> GlobalHotkey.Combo? {
        if action.id == "show" { return AppSettings.hotkey }
        if let binding = overrides[action.id] { return binding["stored"].flatMap(GlobalHotkey.Combo.init(stored:)) }
        return action.key.map { GlobalHotkey.Combo(keyCode: $0, modifiers: action.modifiers) }
    }
    func list() -> [[String: Any]] {
        ShortcutAction.all.map { action in
            ["id": action.id, "title": action.title, "scope": scope(action.id), "stored": combo(action)?.stored ?? NSNull(),
             "display": combo(action)?.display ?? "未设置", "requires_list_focus": action.fileAction,
             "error":errors[action.id] ?? "", "registered":action.id == "show" ? primary?.combo != nil : global[action.id]?.combo != nil]
        }
    }
    @discardableResult func set(_ id: String, combo proposed: GlobalHotkey.Combo?, scope: String) -> String? {
        guard let action = ShortcutAction.all.first(where: { $0.id == id }), ["app", "global"].contains(scope) else { return "未知操作或作用范围" }
        if let proposed {
            guard proposed.isUsable, proposed.keyCode < 128 else { return "至少包含 ⌘、⌃ 或 ⌥" }
            if proposed.modifiers == .command, [0, 6, 7, 8, 9].contains(proposed.keyCode) { return "保留系统全选、撤销、剪切、复制和粘贴键" }
            if scope == "app",proposed.modifiers == .command,Self.fixedAppKeyCodes.contains(proposed.keyCode) { return "该组合用于固定窗口导航，请选择其他组合" }
            if ShortcutAction.all.contains(where: { $0.id != id && combo($0) == proposed && self.scope($0.id) == (id == "show" ? "global" : scope) }) { return "与 Sift 的另一操作重复，请先清除那个绑定" }
        }
        if id == "show" {
            guard let primary else { return "呼出服务尚未就绪" }
            let state = HotkeySetting.apply(proposed, to: primary)
            if state.inUse { return HotkeySetting.inUseNote }
        } else {
            var replacement: GlobalHotkey?
            if scope == "global", let proposed {
                if self.scope(id) == "global", combo(action) == proposed, global[id]?.combo != nil { return nil }
                let key = GlobalHotkey { [weak self] in self?.perform?(id) }
                guard key.register(proposed) else { return "组合已被占用，原绑定保留" }
                replacement = key
            }
            global.removeValue(forKey: id)?.unregister()
            if let replacement { global[id] = replacement }
            var values = overrides
            values[id] = ["stored": proposed?.stored ?? "", "scope": scope]
            overrides = values
        }
        errors.removeValue(forKey:id)
        applyMenus(); ShortcutCatalog.write()
        return nil
    }
    func reset() {
        global.values.forEach { $0.unregister() }; global = [:]
        errors = [:];Prefs.remove("shortcuts.v1")
        if let primary { _ = HotkeySetting.apply(nil, to: primary) }
        applyMenus(); ShortcutCatalog.write()
    }
    func clearAll() {
        global.values.forEach{$0.unregister()};global = [:];errors = [:]
        overrides = Dictionary(uniqueKeysWithValues:ShortcutAction.all.filter{$0.id != "show"}.map{($0.id,["stored":"","scope":"app"])})
        if let primary { _ = HotkeySetting.apply(nil,to:primary) }
        applyMenus();ShortcutCatalog.write()
    }
    func reload() {
        errors = [:]
        for action in ShortcutAction.all where action.id != "show" {
            guard scope(action.id) == "global",let combo = combo(action) else { global.removeValue(forKey:action.id)?.unregister();continue }
            if global[action.id]?.combo == combo { continue }
            let hotkey = GlobalHotkey { [weak self] in self?.perform?(action.id) }
            if hotkey.register(combo) { global.removeValue(forKey:action.id)?.unregister();global[action.id] = hotkey }
            else {
                errors[action.id] = "组合已被占用，原绑定保留"
                if let old = global[action.id]?.combo {
                    var values = overrides;values[action.id] = ["stored":old.stored,"scope":"global"];overrides = values
                }
            }
        }
        applyMenus(); ShortcutCatalog.write()
    }
    func suspendRecording(_ id: String) { primary?.unregister();global.values.forEach{$0.unregister()} }
    func restoreRecording() { if let combo = AppSettings.hotkey { primary?.register(combo) }; reload() }
    func applyMenus() {
        for action in ShortcutAction.all where action.id != "show" {
            let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
            guard let item = items.first(where: { $0.action.map(NSStringFromSelector) == action.selector && (action.selector != "sortMenu:" || $0.tag == action.tag) }) else { continue }
            if scope(action.id) == "app", let key = combo(action) {
                item.keyEquivalent = key.menuKey
                item.keyEquivalentModifierMask = key.modifiers
            } else { item.keyEquivalent = "" }
        }
    }
}

enum ShortcutCatalog {
    static func write() {
        #if !APP_STORE
        guard !Prefs.readOnly, !Prefs.headless, !Lifecycle.isolated else { return }
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        let directory = base.appendingPathComponent("mackit/keys.d")
        guard FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path) else { return }
        let file = directory.appendingPathComponent("sift.json")
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path) {
            guard link.hasSuffix("/sift/keys.json") else { return }
            try? FileManager.default.removeItem(at: file)
        }
        let rows = self.rows()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: file, options: .atomic) }
        #endif
    }
    static func rows() -> [[String:String]] {
        var rows: [[String: String]] = ShortcutAction.all.compactMap { action in
            guard let combo = SiftShortcuts.shared.combo(action) else { return nil }
            let modifiers: [(NSEvent.ModifierFlags, String)] = [(.command, "cmd"), (.option,"alt"), (.control,"ctrl"), (.shift,"shift")]
            let special:[UInt32:String] = [51:"delete",117:"forward-delete",36:"return",76:"enter",48:"tab",53:"escape",49:"space",123:"left",124:"right",125:"down",126:"up",116:"pageup",121:"pagedown"]
            let key = (modifiers.filter { combo.modifiers.contains($0.0) }.map { $0.1 } + [special[combo.keyCode] ?? GlobalHotkey.Combo.keyName(combo.keyCode).lowercased()]).joined(separator: "+")
            return ["component":"sift", "mode":SiftShortcuts.shared.scope(action.id) == "global" ? "global" : "app:Sift", "key":key, "description":action.title, "source":"Sift 用户设置"]
        }
        let fixed = [("cmd+l","聚焦搜索框"),("cmd+0","显示搜索窗"),("cmd+return","在 Finder 中显示（列表）"),("space","Quick Look（列表）"),("return","进入结果 / 打开所选文件"),("escape","隐藏搜索窗"),("up","历史 / 上一行"),("down","进入结果 / 下一行"),("tab","移动焦点"),("cmd+c","复制文件对象（列表）或文字（输入框）")]
        for (key,description) in fixed where !rows.contains(where:{$0["key"] == key && $0["mode"] == "app:Sift"}) {
            rows.append(["component":"sift","mode":"app:Sift","key":key,"description":description,"source":"Sift 固定导航与系统编辑"])
        }
        return rows
    }
}

enum SavedSearches {
    static var items: [[String: String]] { UserDefaults.standard.array(forKey: "savedSearches") as? [[String: String]] ?? [] }
    static func add(name: String, query: String, folder:String = "",caseInsensitive:Bool = true) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !query.isEmpty, name.count <= 100, query.count <= 4096 else { throw NSError(domain: "Sift", code: 2, userInfo: [NSLocalizedDescriptionKey:"请输入名称和搜索条件，名称最长 100 字"] ) }
        var values = items.filter { $0["name"] != name }
        guard values.count < 200 else { throw NSError(domain:"Sift",code:2,userInfo:[NSLocalizedDescriptionKey:"最多保存 200 项常用搜索"]) }
        values.append(["name":name,"query":query,"folder":folder,"caseInsensitive":caseInsensitive ? "true" : "false"]); Prefs.set(values, forKey:"savedSearches")
    }
    static func remove(_ name: String) { Prefs.set(items.filter { $0["name"] != name }, forKey:"savedSearches") }
}

enum ProductFiles {
    static func info(_ path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ["ok":true,"path":url.path,"name":url.lastPathComponent,"size":attributes[.size] ?? 0,
                "kind":(attributes[.type] as? FileAttributeType)?.rawValue ?? "unknown",
                "modified":(attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                "created":(attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                "readable":FileManager.default.isReadableFile(atPath:path),"writable":FileManager.default.isWritableFile(atPath:path)]
    }
    static func rename(_ path: String, to name: String) throws -> URL {
        let source = URL(fileURLWithPath:path).standardizedFileURL
        guard source.path != "/", source.path != NSHomeDirectory(), !name.isEmpty, ![".",".."].contains(name), !name.contains("/"), !name.contains("\0") else { throw NSError(domain:"Sift",code:2,userInfo:[NSLocalizedDescriptionKey:"请输入同一文件夹中的有效名称"]) }
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        guard target != source else { return source }
        guard !FileManager.default.fileExists(atPath:target.path) else { throw NSError(domain:"Sift",code:2,userInfo:[NSLocalizedDescriptionKey:"目标名称已存在，未覆盖文件"]) }
        try FileManager.default.moveItem(at:source,to:target); return target
    }
}
