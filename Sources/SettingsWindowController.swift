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
        title = monitor != nil ? String(localized: "Press a shortcut…", table: "Settings") : (combo?.display ?? String(localized: "Not Set", table: "Settings"))
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
        text.setHuggingPriority(.init(1),for:.horizontal)
        detail?.widthAnchor.constraint(equalTo:text.widthAnchor).isActive = true
        accessory?.setContentHuggingPriority(.required,for:.horizontal)
        accessory?.setContentCompressionResistancePriority(.required,for:.horizontal)
        let row = NSStackView(views:[text] + (accessory.map{[$0]} ?? []));row.spacing = 12;row.alignment = .centerY;return row
    }
    static func group(_ title:String?, rows:[NSView]) -> NSView {
        let group = NSStackView(views:(title.map{[NSTextField(labelWithString:$0)]} ?? []) + rows);group.orientation = .vertical;group.alignment = .leading;group.spacing = 10
        for row in rows { row.widthAnchor.constraint(equalTo:group.widthAnchor).isActive = true };return group
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
    private let navigation = NSSegmentedControl(labels:[String(localized: "General", table: "Settings"),String(localized: "Index", table: "Settings"),String(localized: "Shortcuts", table: "Settings"),String(localized: "Search History", table: "Settings"),String(localized: "Help", table: "Settings")],trackingMode:.selectOne,target:nil,action:nil)
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
    #if APP_STORE
    // The Store build shows this window itself (no shared「配置与更新…」window), so the language choice lives here;
    // the logic is the shared LifecycleLanguage (本人 2026-10-18: every app's own settings offer it).
    private let languagePopup = NSPopUpButton()
    private let languageNote = SiftSettingsForm.detailLabel()
    private lazy var reopenButton = button(String(localized: "Reopen", table: "Settings"),#selector(reopenForLanguage))
    #endif

    init(engine: Engine, hotkey: GlobalHotkey) {
        self.engine = engine; self.hotkey = hotkey
        #if APP_STORE
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:600),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:true)
        window.contentMinSize = NSSize(width:700,height:600)
        #else
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:480),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:true)
        #endif
        window.title = String(localized: "Sift · Settings", table: "Settings");window.isReleasedWhenClosed = false
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
        guard NSApp.activationPolicy() == .prohibited,let window,let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded();layoutPages();view.needsDisplay = true;view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds),
              let out = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:rep.pixelsWide,pixelsHigh:rep.pixelsHigh,
                  bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let context = NSGraphicsContext(bitmapImageRep:out) else { return }
        view.cacheDisplay(in:view.bounds,to:rep)
        let image = NSImage(size:view.bounds.size);image.addRepresentation(rep);out.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill();view.bounds.fill() }
        image.draw(in:view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try out.representation(using:.png,properties:[:])?.write(to:url,options:.atomic)
        #else
        if Prefs.readOnly {
            AppLifecycleUI.shared.productGroups = { [weak self] in self?.groups() ?? [] }
            AppLifecycleUI.shared.willShow = { [weak self] in self?.showSystemSettings() }
            if let store = Lifecycle.store() { AppLifecycleUI.install(name:String(localized: "Sift", table: "Settings"),configuration:Lifecycle.makeConfiguration(store),updateSource:Lifecycle.updateSource,startConfiguration:false) }
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
        #if APP_STORE
        let saveNote = SiftText.value("store.save.note",fallback:String(localized: "Saves changes when needed. If disabled, changes are still saved when Sift quits.", table: "Settings"))
        let permissionNote = SiftText.value("store.permissions.note",fallback:String(localized: "Choose folders using the system dialog to grant access. Login items are managed by macOS and do not transfer with settings.", table: "Settings"))
        let missingNote = SiftText.value("store.help.missing",fallback:String(localized: "Check the allowed folders, exclusions, and index status. Choose the folder again or rebuild the index manually.", table: "Settings"))
        let compatibilityNote = SiftText.value("store.help.compatibility",fallback:String(localized: "Requires Apple silicon and macOS 14 or later. Updates come from the App Store. Settings sync, import, and export are below.", table: "Settings"))
        let privacyNote = SiftText.value("store.help.privacy",fallback:String(localized: "The index and search history stay on this Mac. Optional iCloud sync transfers settings only. Updates come from the App Store.", table: "Settings"))
        #else
        let saveNote = String(localized: "Saves changes when needed. If disabled, changes are still saved when Sift quits. Run sift flush to save manually.", table: "Settings")
        let permissionNote = String(localized: "Full Disk Access and login items are managed by macOS and do not transfer with settings.", table: "Settings")
        let missingNote = String(localized: "Check the search scope, exclusions, pause status, permissions, and incomplete index warnings. Review diagnostics or rebuild manually. Protected folders require Full Disk Access.", table: "Settings")
        let compatibilityNote = String(localized: "Requires Apple silicon and macOS 14 or later. Updates, optional settings sync, import, and export are below. The index and system permissions do not transfer with settings.", table: "Settings")
        let privacyNote = String(localized: "The file index, paths, and search history stay on this Mac. File contents are never uploaded. Selected settings sync only when you enable iCloud. Checking for updates only reads Sift's public release record on GitHub. Diagnostics omit search scope paths and history by default.", table: "Settings")
        #endif
        tabs.tabViewType = .noTabsNoBorder
        navigation.segmentStyle = .rounded;navigation.selectedSegment = 0;navigation.target = self;navigation.action = #selector(changeTab(_:))
        for toggle in [loginCheck,paused,autoRepair,autoSave,menuBar] { toggle.target = self;toggle.action = #selector(toggle(_:)) }
        loginCheck.identifier = .init("login");paused.identifier = .init("paused");autoRepair.identifier = .init("repair");autoSave.identifier = .init("save");menuBar.identifier = .init("menu")
        #if APP_STORE
        languagePopup.addItems(withTitles:LifecycleLanguage.allCases.map(\.title));languagePopup.target = self;languagePopup.action = #selector(changedLanguage)
        refreshLanguage()
        let language:[NSView] = [F.group(String(localized: "Language", table: "Settings"),rows:[
            F.row(String(localized: "App Language", table: "Settings"),detail:languageNote,accessory:controls([languagePopup,reopenButton]))])]
        #else
        let language:[NSView] = [LifecycleLanguageRow.group()] // ⌘, opens this page: the shared language row comes first
        #endif
        page(String(localized: "General", table: "Settings"),language + [
            F.group(String(localized: "Operation", table: "Settings"),rows:[
                F.row(String(localized: "Launch at Login", table: "Settings"),detail:F.detailLabel(String(localized: "Runs in the background after login without opening a window.", table: "Settings")),accessory:loginCheck),
                F.row(String(localized: "Pause Index Updates", table: "Settings"),detail:F.detailLabel(String(localized: "Search the existing index while paused. File changes are applied when indexing resumes.", table: "Settings")),accessory:paused),
                F.row(String(localized: "Automatically Repair Incomplete Index", table: "Settings"),detail:F.detailLabel(String(localized: "Repairs missing file events in the background while idle. You can still rebuild manually when disabled.", table: "Settings")),accessory:autoRepair),
                F.row(String(localized: "Save Index Automatically While Idle", table: "Settings"),detail:F.detailLabel(saveNote),accessory:autoSave),
                F.row(String(localized: "Show in Menu Bar", table: "Settings"),detail:F.detailLabel(String(localized: "View status, open Sift, pause or resume indexing, and open Settings from the menu bar.", table: "Settings")),accessory:menuBar)]),
            F.group(String(localized: "Status and Recovery", table: "Settings"),rows:[F.row(String(localized: "Index Status", table: "Settings"),detail:runtimeNote),F.row(String(localized: "Actions", table: "Settings"),accessory:controls([
                button(String(localized: "Rebuild Index", table: "Settings"),#selector(reindex)),button(String(localized: "Cancel Scan", table: "Settings"),#selector(cancelScan)),button(String(localized: "Export Diagnostics…", table: "Settings"),#selector(exportDiagnostics))]))]),
            F.row(String(localized: "System Permissions", table: "Settings"),detail:F.detailLabel(permissionNote),accessory:button(String(localized: "Open System Settings…", table: "Settings"),#selector(openAccess)))
        ])
        #if APP_STORE
        rootField.isEditable = false
        #endif
        rootField.placeholderString = String(localized: "/ or ~/folder", table: "Settings")
        page(String(localized: "Index", table: "Settings"),[
            F.group(String(localized: "Search Scope", table: "Settings"),rows:[F.row(String(localized: "Root Folder", table: "Settings"),accessory:rootField),F.row(String(localized: "Choose a Folder", table: "Settings"),detail:F.detailLabel(String(localized: "Choose an existing, readable folder. Resume indexing before changing the scope.", table: "Settings")),accessory:button(String(localized: "Choose…", table: "Settings"),#selector(chooseRoot)))]),
            F.group(String(localized: "Excluded Folders", table: "Settings"),rows:[area(ignoreText),F.row(String(localized: "One absolute path per line; ~ means your home folder", table: "Settings"),accessory:controls([button(String(localized: "Add…", table: "Settings"),#selector(addPath(_:)),"ignore"),button(String(localized: "Remove Selected Lines", table: "Settings"),#selector(removePath(_:)),"ignore")]))]),
            F.group(String(localized: "Included Subfolders", table: "Settings"),rows:[area(includeText),F.row(String(localized: "Include specific subfolders within excluded locations", table: "Settings"),accessory:controls([button(String(localized: "Add…", table: "Settings"),#selector(addPath(_:)),"include"),button(String(localized: "Remove Selected Lines", table: "Settings"),#selector(removePath(_:)),"include")]))]),
            F.row(String(localized: "Apply Search Scope", table: "Settings"),detail:F.detailLabel(String(localized: "External volumes, cloud caches, and temporary folders are excluded by default. Invalid root folders and relative paths are rejected, keeping the existing scope.", table: "Settings")),accessory:button(String(localized: "Save Search Scope", table: "Settings"),#selector(save)))
        ])
        var rows:[NSView] = []
        for action in ShortcutAction.all {
            let capture = action.id == "show" ? recorder : HotkeyRecorder()
            shortcutRecorders[action.id] = capture
            let scope = NSPopUpButton();scope.addItems(withTitles:[String(localized: "In Sift", table: "Settings"),String(localized: "Global", table: "Settings")]);scope.identifier = .init(action.id)
            scope.target = self;scope.action = #selector(scopeChanged(_:));scope.isEnabled = action.id != "show";scopes[action.id] = scope
            capture.onBegin = { SiftShortcuts.shared.suspendRecording(action.id) }
            capture.onCancel = { [weak self] in SiftShortcuts.shared.restoreRecording();self?.showSystemSettings() }
            capture.onChange = { [weak self, weak scope] combo in
                SiftShortcuts.shared.restoreRecording()
                let error = SiftShortcuts.shared.set(action.id,combo:combo,scope:scope?.indexOfSelectedItem == 1 ? "global" : "app")
                self?.report(error ?? String(localized: "Shortcut saved.", table: "Settings"),failed:error != nil);self?.showSystemSettings()
            }
            rows.append(F.row(action.localizedTitle,detail:action.fileAction ? F.detailLabel(String(localized: "File actions work only when the results list has focus.", table: "Settings")) : nil,
                accessory:controls([scope,capture,button(String(localized: "Clear", table: "Settings"),#selector(clearBinding(_:)),action.id)])))
        }
        page(String(localized: "Shortcuts", table: "Settings"),[
            F.row(String(localized: "Customize Each Action", table: "Settings"),detail:F.detailLabel(String(localized: "Click a shortcut, then press a key combination. Press Esc to cancel. Recording stops when the window loses focus or closes. Conflicts keep the previous shortcut. No global shortcut is assigned by default.", table: "Settings"))),
            F.group(nil,rows:rows),F.row(String(localized: "Shortcut Presets", table: "Settings"),accessory:controls([button(String(localized: "Use ⇧⌘Space", table: "Settings"),#selector(usePreset)),button(String(localized: "Restore Default Shortcuts", table: "Settings"),#selector(resetKeys))])),
            F.row(String(localized: "Fixed Shortcuts", table: "Settings"),detail:F.detailLabel(String(localized: "⌘L focuses search, ⌘0 opens Sift, ↑↓ selects, Space previews, ↩ opens, ⌘↩ reveals in Finder, and Esc hides. Text fields keep standard editing shortcuts.", table: "Settings"))),hotkeyNote
        ])
        historyFilter.placeholderString = String(localized: "Filter saved and recent searches", table: "Settings");historyFilter.delegate = self
        historyList.orientation = .vertical;historyList.alignment = .leading;historyList.spacing = 6
        page(String(localized: "Search History", table: "Settings"),[historyFilter,historyList,F.row(String(localized: "Manage", table: "Settings"),accessory:controls([button(String(localized: "Save Current Search…", table: "Settings"),#selector(saveSearch)),button(String(localized: "Clear Recent Searches", table: "Settings"),#selector(clearHistory))]))])
        page(String(localized: "Help", table: "Settings"),[
            F.group(String(localized: "Getting Started", table: "Settings"),rows:[F.row(String(localized: "Search File Names", table: "Settings"),detail:F.detailLabel(String(localized: "Results update as you type. Folder terms are broadened only if the original query has no results. Return in the search field records the query. Press ↓ to enter the results, then Return to open a file.", table: "Settings"))),
                F.row(String(localized: "Search Syntax", table: "Settings"),detail:F.detailLabel(String(localized: "Spaces mean AND, a|b means OR, and !x excludes a term. Try ext:pdf, size:>1mb, dm:today, or regex:…. Paste actual paths, including spaces. The type, date, and size filters use the same syntax.", table: "Settings"))),
                F.row(String(localized: "Missing Results", table: "Settings"),detail:F.detailLabel(missingNote)),
                F.row(String(localized: "Compatibility and Updates", table: "Settings"),detail:F.detailLabel(compatibilityNote))]),
            F.group(String(localized: "Privacy", table: "Settings"),rows:[F.row(String(localized: "On-Device Processing", table: "Settings"),detail:F.detailLabel(privacyNote))]),
            F.row(String(localized: "Feedback and Support", table: "Settings"),detail:F.detailLabel(String(localized: "Export an issue report and redacted diagnostics to share with the maintainer. Sift does not send them automatically.", table: "Settings")),accessory:button(String(localized: "Report an Issue…", table: "Settings"),#selector(feedback))),
            F.row(String(localized: "Diagnostics", table: "Settings"),accessory:controls([button(String(localized: "Export Diagnostics…", table: "Settings"),#selector(exportDiagnostics)),button(String(localized: "Show Support Folder", table: "Settings"),#selector(openSupport))]))
        ])
        #if APP_STORE
        var transfer:[NSView] = [button(String(localized: "Export Settings…", table: "Settings"),#selector(exportStore)),button(String(localized: "Import Settings…", table: "Settings"),#selector(importStore))]
        #if APP_LIFECYCLE_KVS
        let cloud = NSButton(checkboxWithTitle:String(localized: "Sync Settings with iCloud", table: "Settings"),target:self,action:#selector(toggleStoreCloud(_:)));cloud.state = StoreConfiguration.current?.enabled == true ? .on : .off;transfer.insert(cloud,at:0)
        #endif
        let row = F.row(String(localized: "Transfer Settings", table: "Settings"),accessory:controls(transfer))
        let stack = NSStackView(views:[navigation,tabs,message,row]);form = stack
        row.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        #else
        let stack = NSStackView(views:[navigation,tabs,message]);form = stack
        #endif
        stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 8;stack.translatesAutoresizingMaskIntoConstraints = false
        tabs.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true;tabs.heightAnchor.constraint(equalToConstant:340).isActive = true
        message.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        let content = window!.contentView!;content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:content.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-20)])
    }
    private func report(_ text:String,failed:Bool = false) { message.stringValue = SiftText.title(text);message.textColor = failed ? .systemRed : .secondaryLabelColor }
    private func load() {
        showSystemSettings()
        #if APP_STORE
        refreshLanguage()
        #endif
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
        hotkeyNote.stringValue = inUse ? SiftText.title(HotkeySetting.inUseNote) : ""
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
            do { try LoginItem.set(sender.state == .on);report(LoginItem.status == .requiresApproval ? String(localized: "Allow Sift in Login Items in System Settings.", table: "Settings") : String(localized: "Login settings saved.", table: "Settings")) } catch { report(error.localizedDescription,failed:true) }
        case "menu": Prefs.set(sender.state == .on,forKey:"menuBar");onPreferencesChange?();report(String(localized: "Menu bar settings saved.", table: "Settings"))
        default:
            let id = sender.identifier?.rawValue
            let request:[String:Any] = id == "paused" ? ["action":sender.state == .on ? "pause" : "resume"] : ["action":"set",id == "repair" ? "auto_repair" : "auto_snapshot":sender.state == .on]
            let result = engine.control(request);report(result["error"] as? String ?? String(localized: "Runtime settings saved.", table: "Settings"),failed:result["ok"] as? Bool != true)
        }
        showSystemSettings()
    }
    @objc private func reindex() { if paused.state == .on { report(String(localized: "Resume indexing before rebuilding.", table: "Settings"),failed:true);return };engine.rescan();report(String(localized: "Rebuild requested. You can cancel the current scan.", table: "Settings"));showSystemSettings() }
    @objc private func cancelScan() { _ = engine.control(["action":"cancel"]);report(String(localized: "Scan cancellation requested. The existing index is kept.", table: "Settings"));showSystemSettings() }
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
            self?.onIndexFolderChange?(error);self?.load();self?.report(error ?? String(localized: "Index folder updated.", table: "Settings"),failed:error != nil)
        }
        #else
        chooseFolder { [weak self] in self?.rootField.stringValue = $0.path }
        #endif
    }
    @objc private func addPath(_ sender:NSButton) { chooseFolder { [weak self] url in guard let self else { return };let text = sender.identifier?.rawValue == "include" ? self.includeText : self.ignoreText;text.string += (text.string.isEmpty ? "" : "\n") + url.path } }
    @objc private func removePath(_ sender:NSButton) { let text = sender.identifier?.rawValue == "include" ? includeText : ignoreText;let value = text.string as NSString;guard value.length > 0 else { return };let selection = NSIntersectionRange(text.selectedRange(),NSRange(location:0,length:value.length));let range = value.lineRange(for:selection);text.string = value.replacingCharacters(in:range,with:"") }
    @objc private func save() {
        guard engine.details()["paused"] as? Bool != true else { report(String(localized: "Indexing is paused. Resume it before applying the search scope.", table: "Settings"),failed:true);return }
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
        else { Prefs.didSaveIndexSettings?();load();let current = engine.settingsJSON().flatMap{try? JSONSerialization.jsonObject(with:$0)} as? NSDictionary;report(old == current ? String(localized: "Settings saved. The scope is unchanged, so no rebuild is needed.", table: "Settings") : String(localized: "Settings saved. Rebuilding the index with the new scope.", table: "Settings")) }
    }
    @objc private func clearBinding(_ sender:NSButton) { if let id = sender.identifier?.rawValue { let error = SiftShortcuts.shared.set(id,combo:nil,scope:"app");report(error ?? String(localized: "Shortcut cleared.", table: "Settings"),failed:error != nil);showSystemSettings() } }
    @objc private func scopeChanged(_ sender:NSPopUpButton) {
        guard let id = sender.identifier?.rawValue,let action = ShortcutAction.all.first(where:{$0.id == id}) else { return }
        let error = SiftShortcuts.shared.set(id,combo:SiftShortcuts.shared.combo(action),scope:sender.indexOfSelectedItem == 1 ? "global" : "app")
        report(error ?? String(localized: "Shortcut scope saved.", table: "Settings"),failed:error != nil);showSystemSettings()
    }
    @objc private func usePreset() { let error = SiftShortcuts.shared.set("show",combo:HotkeySetting.cardinal,scope:"global");report(error ?? String(localized: "Show Sift shortcut saved.", table: "Settings"),failed:error != nil);showSystemSettings() }
    @objc private func resetKeys() { SiftShortcuts.shared.reset();showSystemSettings();report(String(localized: "Default app shortcuts restored. Global shortcuts cleared.", table: "Settings")) }
    func controlTextDidChange(_ notification:Notification) { if notification.object as? NSControl === historyFilter { rebuildHistory() } }
    private func rebuildHistory() {
        historyList.arrangedSubviews.forEach{historyList.removeArrangedSubview($0);$0.removeFromSuperview()}
        let filter = historyFilter.stringValue.lowercased()
        let saved = SavedSearches.items.filter{filter.isEmpty || (($0["name"] ?? "") + ($0["query"] ?? "")).lowercased().contains(filter)}
        historyList.addArrangedSubview(NSTextField(labelWithString:String(localized: "Saved Searches", table: "Settings")))
        for item in saved {
            let pick = button(item["name"] ?? "",#selector(pickSaved(_:)),item["name"] ?? "")
            pick.toolTip = item["query"]
            historyList.addArrangedSubview(controls([pick,button(String(localized: "Delete", table: "Settings"),#selector(removeSearch(_:)),item["name"] ?? "")]))
        }
        historyList.addArrangedSubview(NSTextField(labelWithString:String(localized: "Recent Searches", table: "Settings")))
        for query in SearchHistory().items where filter.isEmpty || query.lowercased().contains(filter) {
            let b = button(query,#selector(pickSearch(_:)),query);b.toolTip = query;b.lineBreakMode = .byTruncatingMiddle;historyList.addArrangedSubview(b)
        }
        if saved.isEmpty && SearchHistory().items.isEmpty { historyList.addArrangedSubview(SiftSettingsForm.detailLabel(String(localized: "No searches yet. Press Return in the search field or open a result to save a query to history.", table: "Settings"))) }
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
    #if APP_STORE
    var storeChannelForTesting:Bool { !rootField.isEditable && SiftText.value("store.help.compatibility",fallback:"").contains("App Store") }
    #endif
    @objc private func removeSearch(_ sender:NSButton) { SavedSearches.remove(sender.identifier?.rawValue ?? "");rebuildHistory() }
    @objc private func saveSearch() { onSaveCurrentSearch?(form.window ?? window);rebuildHistory() }
    func reloadConfiguration() { load() }
    @objc private func clearHistory() { SearchHistory().clear();NotificationCenter.default.post(name:.init("SiftClearHistory"),object:nil);rebuildHistory();report(String(localized: "Recent searches cleared. Saved searches are kept.", table: "Settings")) }
    @objc private func exportDiagnostics() { SiftDiagnostics.export(engine:engine,window:form.window ?? window) }
    @objc private func openSupport() { if !Prefs.dryRun("show support",[]) { NSWorkspace.shared.activateFileViewerSelecting([AppDelegate.supportDirectory]) } }
    @objc private func feedback() { SiftDiagnostics.feedback(engine:engine,window:form.window ?? window) }
    #if APP_STORE
    @objc private func exportStore() { guard let c = StoreConfiguration.current,!Prefs.dryRun("export settings",[]) else { return };let p = NSSavePanel();p.nameFieldStringValue = "Sift-config.json";p.beginSheetModal(for:form.window ?? window!) { r in if r == .OK,let url = p.url { do { try StoreConfiguration.exportData(c).write(to:url,options:.atomic) } catch { self.report(error.localizedDescription,failed:true) } } } }
    @objc private func importStore() { guard let c = StoreConfiguration.current,!Prefs.dryRun("import settings",[]) else { return };let p = NSOpenPanel();p.beginSheetModal(for:form.window ?? window!) { r in if r == .OK,let url = p.url { do { try StoreConfiguration.importData(Data(contentsOf:url),into:c);self.load();self.report(String(localized: "Settings imported. Previous settings were backed up.", table: "Settings")) } catch { self.report(error.localizedDescription,failed:true) } } } }
    private func refreshLanguage() {
        languagePopup.selectItem(at:LifecycleLanguage.allCases.firstIndex(of:LifecycleLanguage.current) ?? 0)
        let pending = LifecycleLanguage.needsRelaunch
        languageNote.stringValue = pending ? String(localized: "Takes effect after the app reopens.", table: "Settings") : String(localized: "Menus, windows, and system panels switch together.", table: "Settings")
        reopenButton.isHidden = !pending
    }
    @objc private func changedLanguage() { LifecycleLanguage.set(LifecycleLanguage.allCases[max(0,languagePopup.indexOfSelectedItem)]);refreshLanguage() }
    @objc private func reopenForLanguage() { LifecycleLanguage.relaunch() }
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
