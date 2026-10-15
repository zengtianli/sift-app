import AppKit
private final class SettingsDocument:NSView { override var isFlipped:Bool { true } }
import Carbon.HIToolbox
import ServiceManagement

/// Records a shortcut: click, then press the combination (Esc cancels).
final class HotkeyRecorder: NSButton {
    var combo: GlobalHotkey.Combo? { didSet { if oldValue != combo { refresh() } } }
    var onChange: ((GlobalHotkey.Combo?) -> Void)?
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title = monitor != nil ? "按下组合键…" : (combo?.display ?? "未设置")
    }

    @objc private func startRecording() {
        guard monitor == nil else { return }
        onBegin?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true, self.window?.isVisible == true else { return event }
            if event.keyCode == 53 { self.stop(cancelled: true); return nil } // Esc
            let combo = GlobalHotkey.Combo(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags)
            guard combo.isUsable else { NSSound.beep(); return nil }
            self.stop()
            self.combo = combo
            self.onChange?(combo)
            return nil
        }
        refresh()
    }

    private func stop(cancelled: Bool = false) {
        let wasRecording = monitor != nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refresh()
        if cancelled && wasRecording { onCancel?() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop(cancelled: true)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let window {
            for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.stop(cancelled: true) })
            }
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) }; for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}


#if APP_STORE
enum SiftSettingsForm {
    static func detailLabel(_ text: String = "") -> NSTextField { let f = NSTextField(wrappingLabelWithString:text);f.font = .systemFont(ofSize:11);f.textColor = .secondaryLabelColor;return f }
    static func row(_ title:String, detail:NSTextField? = nil, accessory:NSView? = nil) -> NSView {
        let text = NSStackView(views:[NSTextField(labelWithString:title)] + (detail.map{[$0]} ?? []));text.orientation = .vertical;text.alignment = .leading
        let row = NSStackView(views:[text,NSView()] + (accessory.map{[$0]} ?? []));row.spacing = 12;return row
    }
    static func group(_ title:String?, rows:[NSView]) -> NSView {
        let group = NSStackView(views:(title.map{[NSTextField(labelWithString:$0)]} ?? []) + rows);group.orientation = .vertical;group.alignment = .leading;group.spacing = 10;return group
    }
}
#else
typealias SiftSettingsForm = AppLifecycleUI
#endif

final class SettingsWindowController: NSWindowController, NSSearchFieldDelegate {
    private let engine: Engine
    private let hotkey: GlobalHotkey
    private let recorder = HotkeyRecorder()
    private let hotkeyNote = SiftSettingsForm.detailLabel()
    private let rootField = NSTextField()
    private let ignoreText = NSTextView()
    private let includeText = NSTextView()
    private let loginCheck = NSSwitch()
    private let paused = NSSwitch()
    private let autoRepair = NSSwitch()
    private let autoSave = NSSwitch()
    private let menuBar = NSSwitch()
    private let runtimeNote = SiftSettingsForm.detailLabel()
    private let message = SiftSettingsForm.detailLabel()
    private let historyFilter = NSSearchField()
    private let historyList = NSStackView()
    private let tabs = NSTabView()
    private let navigation = NSSegmentedControl(labels:["通用","索引","快捷键","搜索历史","帮助"],trackingMode:.selectOne,target:nil,action:nil)
    private var form: NSView!
    private var shortcutRecorders: [String:HotkeyRecorder] = [:]
    private var scopes: [String:NSPopUpButton] = [:]
    private var timer: Timer?
    private var systemSettingsSnapshot: [String]?
    private(set) var layoutPassesForTesting = 0
    var onIndexFolderChange: ((String?) -> Void)?
    var onSelectQuery: ((String) -> Void)?
    var onSelectSaved: (([String:String]) -> Void)?
    var onPreferencesChange: (() -> Void)?
    var onSaveCurrentSearch: ((NSWindow?) -> Void)?

    init(engine: Engine, hotkey: GlobalHotkey) {
        self.engine = engine; self.hotkey = hotkey
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:480),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:true)
        window.title = "Sift · 设置";window.isReleasedWhenClosed = false
        super.init(window:window); build(); load()
        if !Prefs.readOnly, !Prefs.headless {
            timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
                guard let self, self.form.window?.isVisible == true else { return }
                self.showSystemSettings()
            }
            timer?.tolerance = 0.5
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    func present() {
        load()
        #if APP_STORE
        window?.center();NSApp.activate(ignoringOtherApps:true);window?.makeKeyAndOrderFront(nil)
        #else
        AppLifecycleUI.shared.show()
        #endif
    }
    func groups() -> [NSView] { [form] }
    func showHelp() { selectTabForTesting(4);present() }
    func writeSnapshot(to url:URL,showUpdates:Bool = false) throws {
        load()
        #if APP_STORE
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:rep);try rep.representation(using:.png,properties:[:])?.write(to:url) }
        #else
        if Prefs.readOnly {
            AppLifecycleUI.shared.productGroups = { [weak self] in self?.groups() ?? [] }
            AppLifecycleUI.shared.willShow = { [weak self] in self?.showSystemSettings() }
            if let store = Lifecycle.store() { AppLifecycleUI.install(name:"Sift · 速寻",configuration:Lifecycle.makeConfiguration(store),updateSource:Lifecycle.updateSource,startConfiguration:false) }
        }
        _ = try AppLifecycleUI.shared.offscreenSnapshot(to:url,appearance:NSApp.effectiveAppearance.name == .darkAqua ? .darkAqua : .aqua,showingUpdateOptions:showUpdates)
        #endif
    }
    func stateForTesting() -> (root:String,ignore:[String],recorderTitle:String,recorderInWindow:Bool) {
        load();let previous = tabs.selectedTabViewItem;tabs.selectTabViewItem(at:2);window?.contentView?.layoutSubtreeIfNeeded()
        defer { if let previous { tabs.selectTabViewItem(previous) } }
        return(rootField.stringValue,ignoreText.string.split(whereSeparator:\.isNewline).map(String.init),recorder.title,recorder.window != nil && !recorder.isHidden)
    }
    var systemSettingsForTesting:(recorderTitle:String,note:String,loginChecked:Bool) { (recorder.title,hotkeyNote.stringValue,loginCheck.state == .on) }

    private func button(_ title:String,_ action:Selector,_ id:String = "") -> NSButton {
        let b = NSButton(title:title,target:self,action:action);b.identifier = NSUserInterfaceItemIdentifier(id);return b
    }
    private func controls(_ views:[NSView]) -> NSStackView { let s = NSStackView(views:views);s.spacing = 6;return s }
    private func page(_ title:String,_ views:[NSView]) {
        let stack = NSStackView(views:views);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top:12,left:12,bottom:12,right:12)
        let document = SettingsDocument(frame:NSRect(x:0,y:0,width:500,height:340))
        document.addSubview(stack)
        let scroll = NSScrollView();scroll.hasVerticalScroller = true;scroll.scrollerStyle = .overlay;scroll.autohidesScrollers = true;scroll.drawsBackground = false;scroll.documentView = document
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:document.leadingAnchor),stack.topAnchor.constraint(equalTo:document.topAnchor),stack.trailingAnchor.constraint(equalTo:document.trailingAnchor)])
        for view in views { view.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-24).isActive = true }
        let item = NSTabViewItem(identifier:title);item.label = title;item.view = scroll;tabs.addTabViewItem(item)
    }
    private func area(_ text:NSTextView) -> NSScrollView {
        text.isRichText = false;text.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        text.isAutomaticQuoteSubstitutionEnabled = false;text.isAutomaticDashSubstitutionEnabled = false
        let scroll = NSScrollView();scroll.borderType = .bezelBorder;scroll.hasVerticalScroller = true;scroll.documentView = text
        text.autoresizingMask = [.width];text.textContainer?.widthTracksTextView = true
        scroll.heightAnchor.constraint(equalToConstant:76).isActive = true;return scroll
    }
    private func build() {
        typealias F = SiftSettingsForm
        tabs.tabViewType = .noTabsNoBorder
        navigation.segmentStyle = .rounded;navigation.selectedSegment = 0;navigation.target = self;navigation.action = #selector(changeTab(_:))
        for toggle in [loginCheck,paused,autoRepair,autoSave,menuBar] { toggle.target = self;toggle.action = #selector(toggle(_:)) }
        loginCheck.identifier = .init("login");paused.identifier = .init("paused");autoRepair.identifier = .init("repair");autoSave.identifier = .init("save");menuBar.identifier = .init("menu")
        page("通用",[
            F.group("运行",rows:[
                F.row("登录时启动",detail:F.detailLabel("登录后在后台运行，不主动打开窗口。"),accessory:loginCheck),
                F.row("暂停索引更新",detail:F.detailLabel("暂停后仍可查询旧索引；恢复时回放期间的文件变化。"),accessory:paused),
                F.row("自动修复不完整索引",detail:F.detailLabel("空闲时以后台线程修复丢失事件；关闭后可手动重建。"),accessory:autoRepair),
                F.row("空闲时自动保存索引",detail:F.detailLabel("有变化时按需保存；关闭后仍在退出时保存，可用 sift flush 手动保存。"),accessory:autoSave),
                F.row("菜单栏入口",detail:F.detailLabel("在菜单栏查看状态、呼出、暂停/恢复与打开设置。"),accessory:menuBar)]),
            F.group("状态与恢复",rows:[F.row("索引状态",detail:runtimeNote),F.row("操作",accessory:controls([
                button("重建索引",#selector(reindex)),button("取消当前扫描",#selector(cancelScan)),button("导出诊断…",#selector(exportDiagnostics))]))]),
            F.row("系统权限",detail:F.detailLabel("完全磁盘访问和登录项由 macOS 管理，不随配置迁移。"),accessory:button("查看系统设置…",#selector(openAccess)))
        ])
        #if APP_STORE
        rootField.isEditable = false
        #endif
        rootField.placeholderString = "/ 或 ~/文件夹"
        page("索引",[
            F.group("搜索范围",rows:[F.row("根目录",accessory:rootField),F.row("选择文件夹",detail:F.detailLabel("请选存在且可读取的文件夹；修改范围需先恢复索引。"),accessory:button("选择…",#selector(chooseRoot)))]),
            F.group("排除的文件夹",rows:[area(ignoreText),F.row("一行一个绝对路径；~ 表示主目录",accessory:controls([button("添加…",#selector(addPath(_:)),"ignore"),button("删除所选行",#selector(removePath(_:)),"ignore")]))]),
            F.group("仍包含的子文件夹",rows:[area(includeText),F.row("可包含排除范围里的指定子文件夹",accessory:controls([button("添加…",#selector(addPath(_:)),"include"),button("删除所选行",#selector(removePath(_:)),"include")]))]),
            F.row("应用索引范围",detail:F.detailLabel("默认跳过外接卷、云缓存和临时目录。相对路径或错误根目录会拒绝保存，原范围保留。"),accessory:button("保存索引范围",#selector(save)))
        ])
        var rows:[NSView] = []
        for action in ShortcutAction.all {
            let capture = action.id == "show" ? recorder : HotkeyRecorder()
            shortcutRecorders[action.id] = capture
            let scope = NSPopUpButton();scope.addItems(withTitles:["仅 Sift 内","全局"]);scope.identifier = .init(action.id)
            scope.target = self;scope.action = #selector(scopeChanged(_:));scope.isEnabled = action.id != "show";scopes[action.id] = scope
            capture.onBegin = { SiftShortcuts.shared.suspendRecording(action.id) }
            capture.onCancel = { [weak self] in SiftShortcuts.shared.restoreRecording();self?.showSystemSettings() }
            capture.onChange = { [weak self, weak scope] combo in
                SiftShortcuts.shared.restoreRecording()
                let error = SiftShortcuts.shared.set(action.id,combo:combo,scope:scope?.indexOfSelectedItem == 1 ? "global" : "app")
                self?.report(error ?? "快捷键已保存",failed:error != nil);self?.showSystemSettings()
            }
            rows.append(F.row(action.title,detail:action.fileAction ? F.detailLabel("文件操作仅在结果列表有焦点时生效。") : nil,
                accessory:controls([scope,capture,button("清除",#selector(clearBinding(_:)),action.id)])))
        }
        page("快捷键",[
            F.row("按操作自定义",detail:F.detailLabel("点击录制后按组合键，Esc 取消；失焦/关闭自动结束。冲突失败保留旧键。默认不占全局键。")),
            F.group(nil,rows:rows),F.row("快捷键预设",accessory:controls([button("使用 ⇧⌘Space",#selector(usePreset)),button("恢复应用默认键",#selector(resetKeys))])),
            F.row("其他固定操作",detail:F.detailLabel("⌘L 聚焦，⌘0 呼出，↑↓ 选择，Space 预览，↩ 打开，⌘↩ Finder，Esc 隐藏；文本框保留系统编辑键。")),hotkeyNote
        ])
        historyFilter.placeholderString = "筛选常用搜索与最近搜索";historyFilter.delegate = self
        historyList.orientation = .vertical;historyList.alignment = .leading;historyList.spacing = 6
        page("搜索历史",[historyFilter,historyList,F.row("管理",accessory:controls([button("保存当前搜索…",#selector(saveSearch)),button("清除最近搜索",#selector(clearHistory))]))])
        page("帮助",[
            F.group("开始使用",rows:[F.row("搜索文件名",detail:F.detailLabel("输入即搜索；只有原查询没有结果时才放宽文件夹词。搜索框 ↩ 只记历史，↓ 进入列表后 ↩ 才打开文件。")),
                F.row("搜索语法",detail:F.detailLabel("空格为与，a|b 为或，!x 排除，ext:pdf、size:>1mb、dm:today、regex:…；带空格的真实路径可直接粘贴。顶部类型、日期和大小筛选与语法共用。")),
                F.row("搜不到时",detail:F.detailLabel("检查范围/排除、暂停状态、权限和不完整索引提示；可查看诊断或手动重建。保护目录需要完全磁盘访问。")),
                F.row("兼容与更新",detail:F.detailLabel("Apple Silicon，macOS 14+。软件更新、可选配置同步和导入/导出在本窗口下方；索引与系统权限不随配置迁移。"))]),
            F.group("隐私",rows:[F.row("本机处理",detail:F.detailLabel("文件索引、路径与搜索历史保存在本机，不上传文件内容。只有主动开启 iCloud 时同步选定配置；更新读取原私有渠道的本机发行记录。诊断默认不含范围路径和搜索历史。"))]),
            F.row("反馈与支持",detail:F.detailLabel("导出问题说明与脱敏诊断，交给维护者；本程序不会自动发送。"),accessory:button("反馈问题…",#selector(feedback))),
            F.row("诊断",accessory:controls([button("导出诊断…",#selector(exportDiagnostics)),button("显示支持目录",#selector(openSupport))]))
        ])
        #if APP_STORE
        var transfer:[NSView] = [button("导出配置…",#selector(exportStore)),button("导入配置…",#selector(importStore))]
        #if APP_LIFECYCLE_KVS
        let cloud = NSButton(checkboxWithTitle:"使用 iCloud 记住配置",target:self,action:#selector(toggleStoreCloud(_:)));cloud.state = StoreConfiguration.current?.enabled == true ? .on : .off;transfer.insert(cloud,at:0)
        #endif
        let row = F.row("配置迁移",accessory:controls(transfer))
        let stack = NSStackView(views:[navigation,tabs,message,row]);form = stack
        #else
        let stack = NSStackView(views:[navigation,tabs,message]);form = stack
        #endif
        stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 8;stack.translatesAutoresizingMaskIntoConstraints = false
        tabs.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true;tabs.heightAnchor.constraint(equalToConstant:340).isActive = true
        message.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        let content = window!.contentView!;content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:content.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-20)])
    }
    private func report(_ text:String,failed:Bool = false) { message.stringValue = text;message.textColor = failed ? .systemRed : .secondaryLabelColor }
    private func load() {
        showSystemSettings()
        if let data = engine.settingsJSON(),let json = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            rootField.stringValue = json["root"] as? String ?? "/"
            let lines:(String)->String = { key in ((json[key] as? [String]) ?? []).filter{$0 != "/System/Volumes/Data"}.map{($0 as NSString).abbreviatingWithTildeInPath}.joined(separator:"\n") }
            ignoreText.string = lines("ignore_paths");includeText.string = lines("include_paths")
        }
        rebuildHistory();layoutPages()
    }
    func showSystemSettings() {
        // Poll live values, but do not invalidate AppKit layout for unchanged controls.
        let oldNotes = [hotkeyNote.stringValue, runtimeNote.stringValue]
        let shortcuts = SiftShortcuts.shared
        let d = engine.details()
        let inUse = HotkeySetting.state(hotkey).inUse
        let login = LoginItem.enabled
        let summary = SiftDiagnostics.summary(d)
        let menu = UserDefaults.standard.bool(forKey:"menuBar")
        var snapshot = [String(inUse), String(login), String(menu), summary,
                        String(d["paused"] as? Bool ?? false), String(d["auto_repair"] as? Bool ?? true),
                        String(d["auto_snapshot"] as? Bool ?? true)]
        for action in ShortcutAction.all {
            let combo = shortcuts.combo(action)
            snapshot.append("\(action.id):\(combo?.keyCode ?? UInt32.max):\(combo?.modifiers.rawValue ?? 0):\(shortcuts.scope(action.id))")
        }
        guard snapshot != systemSettingsSnapshot else { return }
        systemSettingsSnapshot = snapshot
        for action in ShortcutAction.all {
            shortcutRecorders[action.id]?.combo = shortcuts.combo(action)
            let scope = shortcuts.scope(action.id) == "global" ? 1 : 0
            if scopes[action.id]?.indexOfSelectedItem != scope { scopes[action.id]?.selectItem(at:scope) }
        }
        hotkeyNote.stringValue = inUse ? HotkeySetting.inUseNote : ""
        hotkeyNote.textColor = .systemOrange;loginCheck.state = login ? .on : .off
        paused.state = d["paused"] as? Bool == true ? .on : .off;autoRepair.state = d["auto_repair"] as? Bool == false ? .off : .on
        autoSave.state = d["auto_snapshot"] as? Bool == false ? .off : .on;menuBar.state = menu ? .on : .off
        runtimeNote.stringValue = summary
        if oldNotes != [hotkeyNote.stringValue, runtimeNote.stringValue] { layoutPages() }
        if let problem = d["configuration_error"] as? String,!problem.isEmpty { report(problem,failed:true) }
    }
    @objc private func toggle(_ sender:NSSwitch) {
        switch sender.identifier?.rawValue {
        case "login":
            do { try LoginItem.set(sender.state == .on);report(LoginItem.status == .requiresApproval ? "请在系统登录项中允许 Sift" : "登录设置已保存") } catch { report(error.localizedDescription,failed:true) }
        case "menu": Prefs.set(sender.state == .on,forKey:"menuBar");onPreferencesChange?();report("菜单栏设置已保存")
        default:
            let id = sender.identifier?.rawValue
            let request:[String:Any] = id == "paused" ? ["action":sender.state == .on ? "pause" : "resume"] : ["action":"set",id == "repair" ? "auto_repair" : "auto_snapshot":sender.state == .on]
            let result = engine.control(request);report(result["error"] as? String ?? "运行设置已保存",failed:result["ok"] as? Bool != true)
        }
        showSystemSettings()
    }
    @objc private func reindex() { if paused.state == .on { report("请先恢复索引再重建",failed:true);return };engine.rescan();report("已请求重建，可取消当前扫描");showSystemSettings() }
    @objc private func cancelScan() { _ = engine.control(["action":"cancel"]);report("已请求取消扫描，旧索引保留");showSystemSettings() }
    @objc private func openAccess() {
        #if APP_STORE
        chooseRoot()
        #else
        Permissions.openFullDiskAccessSettings()
        #endif
    }
    private func chooseFolder(_ completion:@escaping(URL)->Void) {
        guard !Prefs.dryRun("choose folder",[]) else { return }
        let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.allowsMultipleSelection = false
        panel.beginSheetModal(for:form.window ?? window!) { response in if response == .OK,let url = panel.url { completion(url) } }
    }
    @objc private func chooseRoot() {
        #if APP_STORE
        IndexAccess.chooseAndGrant(for:form.window ?? window,engine:engine) { [weak self] error in
            self?.onIndexFolderChange?(error);self?.load();self?.report(error ?? "索引文件夹已更新",failed:error != nil)
        }
        #else
        chooseFolder { [weak self] in self?.rootField.stringValue = $0.path }
        #endif
    }
    @objc private func addPath(_ sender:NSButton) { chooseFolder { [weak self] url in guard let self else { return };let text = sender.identifier?.rawValue == "include" ? self.includeText : self.ignoreText;text.string += (text.string.isEmpty ? "" : "\n") + url.path } }
    @objc private func removePath(_ sender:NSButton) { let text = sender.identifier?.rawValue == "include" ? includeText : ignoreText;let value = text.string as NSString;guard value.length > 0 else { return };let selection = NSIntersectionRange(text.selectedRange(),NSRange(location:0,length:value.length));let range = value.lineRange(for:selection);text.string = value.replacingCharacters(in:range,with:"") }
    @objc private func save() {
        guard engine.details()["paused"] as? Bool != true else { report("索引已暂停，请先恢复后应用范围",failed:true);return }
        let split:(String)->[String] = { $0.split(whereSeparator:\.isNewline).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty} }
        #if APP_STORE
        let root = IndexAccess.rootPath
        #else
        let root = rootField.stringValue.trimmingCharacters(in:.whitespaces)
        #endif
        let payload:[String:Any] = ["root":root,"ignore_paths":split(ignoreText.string),"include_paths":split(includeText.string)]
        let old = engine.settingsJSON().flatMap{try? JSONSerialization.jsonObject(with:$0)} as? NSDictionary
        guard let data = try? JSONSerialization.data(withJSONObject:payload) else { return }
        if let error = engine.updateSettings(data) { report(error,failed:true) }
        else { Prefs.didSaveIndexSettings?();load();let current = engine.settingsJSON().flatMap{try? JSONSerialization.jsonObject(with:$0)} as? NSDictionary;report(old == current ? "配置已保存，范围没有变化，无需重建。" : "配置已保存，正在按新范围重建。") }
    }
    @objc private func clearBinding(_ sender:NSButton) { if let id = sender.identifier?.rawValue { let error = SiftShortcuts.shared.set(id,combo:nil,scope:"app");report(error ?? "绑定已清除",failed:error != nil);showSystemSettings() } }
    @objc private func scopeChanged(_ sender:NSPopUpButton) {
        guard let id = sender.identifier?.rawValue,let action = ShortcutAction.all.first(where:{$0.id == id}) else { return }
        let error = SiftShortcuts.shared.set(id,combo:SiftShortcuts.shared.combo(action),scope:sender.indexOfSelectedItem == 1 ? "global" : "app")
        report(error ?? "作用范围已保存",failed:error != nil);showSystemSettings()
    }
    @objc private func usePreset() { let error = SiftShortcuts.shared.set("show",combo:HotkeySetting.cardinal,scope:"global");report(error ?? "呼出键已保存",failed:error != nil);showSystemSettings() }
    @objc private func resetKeys() { SiftShortcuts.shared.reset();showSystemSettings();report("应用键已恢复默认，全局键已清除") }
    func controlTextDidChange(_ notification:Notification) { if notification.object as? NSControl === historyFilter { rebuildHistory() } }
    private func rebuildHistory() {
        historyList.arrangedSubviews.forEach{historyList.removeArrangedSubview($0);$0.removeFromSuperview()}
        let filter = historyFilter.stringValue.lowercased()
        let saved = SavedSearches.items.filter{filter.isEmpty || (($0["name"] ?? "") + ($0["query"] ?? "")).lowercased().contains(filter)}
        historyList.addArrangedSubview(NSTextField(labelWithString:"常用搜索"))
        for item in saved {
            let pick = button(item["name"] ?? "",#selector(pickSaved(_:)),item["name"] ?? "")
            pick.toolTip = item["query"]
            historyList.addArrangedSubview(controls([pick,button("删除",#selector(removeSearch(_:)),item["name"] ?? "")]))
        }
        historyList.addArrangedSubview(NSTextField(labelWithString:"最近搜索"))
        for query in SearchHistory().items where filter.isEmpty || query.lowercased().contains(filter) {
            let b = button(query,#selector(pickSearch(_:)),query);b.toolTip = query;b.lineBreakMode = .byTruncatingMiddle;historyList.addArrangedSubview(b)
        }
        if saved.isEmpty && SearchHistory().items.isEmpty { historyList.addArrangedSubview(SiftSettingsForm.detailLabel("尚无记录。搜索框回车或打开结果后会记住查询。")) }
    }
    @objc private func pickSearch(_ sender:NSButton) { onSelectQuery?(sender.identifier?.rawValue ?? "") }
    @objc private func pickSaved(_ sender:NSButton) { if let saved = SavedSearches.items.first(where:{$0["name"] == sender.identifier?.rawValue}) { onSelectSaved?(saved) } }
    @objc private func changeTab(_ sender:NSSegmentedControl) { selectTabForTesting(sender.selectedSegment) }
    private func layoutPages() {
        layoutPassesForTesting += 1
        for item in tabs.tabViewItems {
            guard let scroll = item.view as? NSScrollView,let document = scroll.documentView,let stack = document.subviews.first as? NSStackView else { continue }
            document.setFrameSize(NSSize(width:max(480,scroll.contentView.bounds.width),height:max(340,stack.fittingSize.height)))
            document.layoutSubtreeIfNeeded()
            document.setFrameSize(NSSize(width:document.frame.width,height:max(340,stack.fittingSize.height)))
        }
    }
    func selectTabForTesting(_ index:Int) { tabs.selectTabViewItem(at:index);navigation.selectedSegment = index;form.window?.contentView?.layoutSubtreeIfNeeded();layoutPages() }
    @objc private func removeSearch(_ sender:NSButton) { SavedSearches.remove(sender.identifier?.rawValue ?? "");rebuildHistory() }
    @objc private func saveSearch() { onSaveCurrentSearch?(form.window ?? window);rebuildHistory() }
    func reloadConfiguration() { load() }
    @objc private func clearHistory() { SearchHistory().clear();NotificationCenter.default.post(name:.init("SiftClearHistory"),object:nil);rebuildHistory();report("最近搜索已清除，常用搜索保留") }
    @objc private func exportDiagnostics() { SiftDiagnostics.export(engine:engine,window:form.window ?? window) }
    @objc private func openSupport() { if !Prefs.dryRun("show support",[]) { NSWorkspace.shared.activateFileViewerSelecting([AppDelegate.supportDirectory]) } }
    @objc private func feedback() { SiftDiagnostics.feedback(engine:engine,window:form.window ?? window) }
    #if APP_STORE
    @objc private func exportStore() { guard let c = StoreConfiguration.current,!Prefs.dryRun("export settings",[]) else { return };let p = NSSavePanel();p.nameFieldStringValue = "Sift-config.json";p.beginSheetModal(for:form.window ?? window!) { r in if r == .OK,let url = p.url { do { try StoreConfiguration.exportData(c).write(to:url,options:.atomic) } catch { self.report(error.localizedDescription,failed:true) } } } }
    @objc private func importStore() { guard let c = StoreConfiguration.current,!Prefs.dryRun("import settings",[]) else { return };let p = NSOpenPanel();p.beginSheetModal(for:form.window ?? window!) { r in if r == .OK,let url = p.url { do { try StoreConfiguration.importData(Data(contentsOf:url),into:c);self.load();self.report("配置已导入，原设置已备份") } catch { self.report(error.localizedDescription,failed:true) } } } }
    #if APP_LIFECYCLE_KVS
    @objc private func toggleStoreCloud(_ sender:NSButton) { StoreConfiguration.current?.setEnabled(sender.state == .on) }
    #endif
    #endif
}

enum AppSettings {
    /// nil (the default) means no system-wide shortcut is registered.
    static var hotkey: GlobalHotkey.Combo? {
        get {
            UserDefaults.standard.string(forKey: "hotkey").flatMap(GlobalHotkey.Combo.init(stored:))
        }
        set {
            if let newValue { Prefs.set(newValue.stored, forKey: "hotkey") } else { Prefs.remove("hotkey") }
        }
    }
}
