import AppKit
import Quartz

/// Result list keys, laid out like Cardinal's: Space previews, ↑ on the first
/// row returns to the search field, Esc hides. ↩ opens and ⌘↩ reveals (Sift extras).
final class ResultsTableView: NSTableView {
    var onSpace: (() -> Void)?
    var onTab: (() -> Void)?
    var onLeaveTop: (() -> Void)?
    var onEscape: (() -> Void)?
    var onReveal: (() -> Void)?
    var onTrash: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let plain = mods.isEmpty
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if plain && event.charactersIgnoringModifiers == " " {
            onSpace?()
        } else if plain && event.keyCode == 48 { // Tab
            onTab?()
        } else if plain && isReturn {
            _ = target?.perform(doubleAction, with: self)
        } else if mods == .command && isReturn {
            onReveal?()
        } else if mods == .command && event.keyCode == 51 { // ⌘⌫, list only
            onTrash?()
        } else if plain && event.keyCode == 126 && selectedRow == 0 && numberOfSelectedRows == 1 { // ↑ on row 0
            onLeaveTop?()
        } else if plain && event.keyCode == 53 { // Esc
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class SearchWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSMenuItemValidation
{
    private let engine: Engine
    private let model: ResultModel
    private let history = SearchHistory()

    private let searchField = NSSearchField()
    private let caseButton = NSButton()
    private let historyButton = NSButton()
    private let table = ResultsTableView()
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let accessButton = NSButton()
    private let typeFilter = NSPopUpButton()
    private let dateFilter = NSPopUpButton()
    private let sizeFilter = NSPopUpButton()
    private var lastIndexRevision: UInt64?
    private var lastBackgroundRefresh = -Double.infinity
    private var backgroundSearch = false
    private(set) var resultReloadsForTesting = 0
    private(set) var backgroundSearchesForTesting = 0
    private var selectionPaths = Set<String>()
    private var restoration: IndexSet?
    private var restoreAll = false

    private var generation = 0
    private var appliedGeneration = 0
    private var lastQueryMillis: Double = 0
    private var sortKey: SortKey? = UserDefaults.standard.object(forKey:"sortKey").flatMap { ($0 as? Int).flatMap { SortKey(rawValue:UInt8(clamping:$0)) } }
    private var sortDescending = UserDefaults.standard.bool(forKey:"sortDescending")
    private var caseInsensitive = UserDefaults.standard.object(forKey: "caseInsensitive") as? Bool ?? true
    private var statusTimer: Timer?
    private var lastError: String?
    private var engineState: EngineState = .starting
    /// ↑/↓ in the search field walk recent searches (index into `history.items`).
    private var historyCursor: Int?
    private var historyDraft = ""

    init(engine: Engine) {
        self.engine = engine
        model = ResultModel(engine: engine)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.title = "Sift"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 520, height: 280)
        if !Prefs.readOnly, !Prefs.headless { window.setFrameAutosaveName("SiftMain") }
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildLayout()
        model.onRowsLoaded = { [weak self] range in self?.rowsArrived(range) }
        model.onResultsInvalidated = { [weak self] in self?.refreshResultsIfNeeded() }
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        searchField.placeholderString = SiftText.title("Search file names")
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 16)
        searchField.controlSize = .large
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        (searchField.cell as? NSSearchFieldCell)?.searchMenuTemplate = nil
        searchField.setAccessibilityLabel(SiftText.title("Search file names"))


        caseButton.setButtonType(.pushOnPushOff)
        caseButton.bezelStyle = .texturedRounded
        caseButton.title = "Aa"
        caseButton.toolTip = "Match case (⌘I)"
        caseButton.state = caseInsensitive ? .off : .on
        caseButton.target = self
        caseButton.action = #selector(toggleCaseFromButton)

        historyButton.bezelStyle = .texturedRounded
        historyButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Recent searches")
        historyButton.toolTip = "Recent searches (⌘Y)"
        historyButton.target = self
        historyButton.action = #selector(showHistory(_:))

        let input = NSStackView(views: [searchField, caseButton, historyButton]);input.spacing = 8
        typeFilter.addItems(withTitles:["所有类型","PDF","Word","Excel","HTML","图片 PNG","Markdown"])
        dateFilter.addItems(withTitles:["任何修改时间","今天","本周"])
        sizeFilter.addItems(withTitles:["任何大小","大于 1 MB","大于 100 MB"])
        for filter in [typeFilter,dateFilter,sizeFilter] { filter.controlSize = .small;filter.target = self;filter.action = #selector(filtersChanged) }
        let filters = NSStackView(views:[typeFilter,dateFilter,sizeFilter,NSView()]);filters.spacing = 6
        let top = NSStackView(views:[input,filters])
        top.orientation = .vertical;top.alignment = .leading;top.spacing = 6
        input.widthAnchor.constraint(equalTo:top.widthAnchor).isActive = true
        filters.widthAnchor.constraint(equalTo:top.widthAnchor).isActive = true
        top.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureTable()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        accessButton.bezelStyle = .inline
        accessButton.controlSize = .small
        accessButton.target = self
        #if APP_STORE
        // The sandboxed build indexes the folder the user allows (IndexAccess); shown until one is granted.
        accessButton.title = SiftText.title("Choose Folder to Index…")
        accessButton.action = #selector(chooseIndexFolder(_:))
        accessButton.isHidden = IndexAccess.hasGrant
        #else
        accessButton.title = SiftText.title("Grant Full Disk Access…")
        accessButton.action = #selector(openAccessSettings)
        accessButton.isHidden = true
        #endif

        let bottom = NSStackView(views: [statusLabel, accessButton, countLabel])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        bottom.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(top)
        content.addSubview(scroll)
        content.addSubview(divider)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 6),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
        ])
    }

    private func configureTable() {
        let columns: [(String, String, CGFloat, SortKey)] = [
            ("name", "Name", 280, .name),
            ("folder", "Folder", 280, .path),
            ("size", "Size", 80, .size),
            ("modified", "Modified", 140, .modified),
            ("created", "Created", 140, .created),
        ]
        for (id, title, width, key) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = SiftText.title(title)
            column.width = width
            column.minWidth = 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(key.rawValue), ascending: true)
            if id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        if !Prefs.readOnly, !Prefs.headless {
            table.autosaveName = "SiftColumns"
            table.autosaveTableColumns = true
        }
        table.style = .fullWidth
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelection(_:))
        table.onSpace = { [weak self] in self?.toggleQuickLook(nil) }
        table.onTab = { [weak self] in self?.focusSearch(nil) }
        table.onLeaveTop = { [weak self] in
            self?.table.deselectAll(nil)
            self?.focusSearch(nil)
        }
        table.onEscape = { [weak self] in self?.hide() }
        table.onReveal = { [weak self] in self?.revealSelection(nil) }
        table.onTrash = { [weak self] in self?.moveToTrash(nil) }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
    }

    // MARK: Offscreen snapshot (verification without touching the screen)

    /// True once the current query has results applied and visible rows loaded.
    var snapshotReady: Bool {
        guard generation > 0, appliedGeneration == generation else { return false }
        let visible = table.rows(in: table.visibleRect)
        guard model.count > 0 else { return true }
        for row in visible.location..<min(visible.location + visible.length, model.count) where model.row(at: row) == nil {
            return false
        }
        return true
    }

    func prepareOffscreen(size: NSSize) {
        guard let window else { return }
        window.setFrame(NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func applyScripted(select: Int?, sort: SortKey?, folderScope: String?, caseSensitive: Bool) {
        if caseSensitive { caseInsensitive = false; caseButton.state = .on }
        if let folderScope { scriptedFolder = folderScope }
        if let sort { sortBy(sort) }
        pendingSelection = select
    }

    private var pendingSelection: Int?
    private var scriptedFolder: String?

    /// Replays one key inside this (offscreen) window: menu shortcuts through
    /// the main menu, everything else through the window's first responder.
    /// Nothing is posted to the system event stream.
    func sendScriptedKey(_ spec: String) {
        guard let window else { return }
        if window.firstResponder == nil || window.firstResponder === window {
            window.makeFirstResponder(searchField)
        }
        if spec == "menu-state" {
            for top in NSApp.mainMenu?.items ?? [] {
                guard let menu = top.submenu, [SiftText.title("File"),SiftText.title("Search")].contains(menu.title) else { continue }
                menu.update()
                let states = menu.items.filter { !$0.isSeparatorItem }
                    .map { "\($0.title)[\($0.isEnabled ? "on" : "off")\($0.state == .on ? ",✓" : "")]" }
                fputs("menu \(menu.title): \(states.joined(separator: " "))\n", stderr)
            }
            return
        }
        if spec.hasPrefix("text:") {
            let text = String(spec.dropFirst(5))
            if let editor = searchField.currentEditor() as? NSTextView { editor.insertText(text, replacementRange: editor.selectedRange()) }
            return
        }
        var mods: NSEvent.ModifierFlags = []
        var key = spec
        while let plus = key.firstIndex(of: "+"), plus != key.startIndex {
            switch key[..<plus] {
            case "cmd": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt": mods.insert(.option)
            case "ctrl": mods.insert(.control)
            default: break
            }
            key = String(key[key.index(after: plus)...])
        }
        let named: [String: (String, UInt16)] = [
            "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125),
            "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
            "pagedown": (String(UnicodeScalar(NSPageDownFunctionKey)!), 121),
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123),
            "delete": ("\u{7f}", 51),
            "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            "return": ("\r", 36), "tab": ("\t", 48), "esc": ("\u{1b}", 53), "space": (" ", 49),
            "comma": (",", 43),
        ]
        let (chars, code) = named[key] ?? (key, 0)
        let fnMods: NSEvent.ModifierFlags = ["down", "up", "pagedown", "left", "right"].contains(key) ? [.function, .numericPad] : []
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods.union(fnMods), timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        if mods.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        window.sendEvent(event)
    }

    var selectedRowForTesting: Int { table.selectedRow }
    var firstResponderIsTable: Bool { window?.firstResponder === table }
    var focusForTesting: String {
        let r = window?.firstResponder
        if r === table { return "table" }
        if let editor = r as? NSText, editor.delegate === searchField { return "search" }
        return "other"
    }
    var queryForTesting: String { searchField.stringValue }

    // MARK: In-process UI self-test (`--ui-self-test`): read state, reach private action paths.

    var resultCountForTesting: Int { model.count }
    /// Settled: the latest search's results (or error) are applied.
    var searchSettledForTesting: Bool { generation > 0 && appliedGeneration == generation }
    func rowNamesForTesting(limit: Int) -> [String] {
        model.rowsNow(IndexSet(integersIn: 0..<min(limit, model.count))).map(\.name)
    }
    func rowsForTesting(limit: Int) -> [FileRow] { model.rowsNow(IndexSet(integersIn: 0..<min(limit, model.count))) }
    var caseInsensitiveForTesting: Bool { caseInsensitive }
    var caseButtonOnForTesting: Bool { caseButton.state == .on }
    var folderVisibleForTesting: Bool { false }
    var sortForTesting: (key: SortKey?, descending: Bool) { (sortKey, sortDescending) }
    var historyForTesting: [String] { history.items }
    var searchFieldForTesting: NSSearchField { searchField }
    var hideRequestsForTesting = 0
    var cachedVisibleRowsForTesting: [FileRow] { model.cachedRows(in: visibleRange) }
    func refreshResultsForTesting() { runSearch(preserveSelection: true) }
    func moveSelectionForTesting(by delta: Int) { moveSelection(by: delta) }
    /// The status line as the visible window's 1 s timer would set it (the offscreen window is never visible).
    func refreshStatusForTesting() -> (state: EngineState, count: String, status: String) {
        let details = engine.details()
        observeIndex(details)
        let status = engine.status()
        engineState = status.state
        let files = Format.count(status.files)
        countLabel.stringValue = status.state == .ready ? "\(files) files" : "\(status.state.label) · \(files)"
        updateStatusLabel(details)
        return (status.state, countLabel.stringValue, statusLabel.stringValue)
    }

    func writeSnapshot(to url: URL) throws {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<min(model.count, 60)),
                         columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        // An offscreen window is never key; draw the selection as a focused window shows it.
        for row in table.selectedRowIndexes {
            table.rowView(atRow: row, makeIfNecessary: false)?.isEmphasized = true
        }
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // cacheDisplay skips the window's own background; paint it under the content.
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        image.draw(in: view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try out.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Showing

    func toggle() {
        guard let window else { return }
        if window.isVisible && NSApp.isActive && window.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let window, !Prefs.dryRun("show window", []) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focusSearch(nil)
        startStatusUpdates()
        #if APP_STORE
        // First run: nothing is indexed until a folder is allowed, so the panel comes up once with the window.
        IndexAccess.offerOnce(for: window, engine: engine) { [weak self] in self?.indexFolderChanged($0) }
        #endif
    }

    func hide() {
        hideRequestsForTesting += 1
        if Prefs.dryRun("hide window", []) { return }
        window?.orderOut(nil)
        stopStatusUpdates()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        NSApp.hide(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) { startStatusUpdates() }

    // MARK: Status

    private func startStatusUpdates() {
        refreshStatus()
        guard statusTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshStatus() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func stopStatusUpdates() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func refreshStatus() {
        guard window?.isVisible == true else { stopStatusUpdates(); return }
        let details = engine.details()
        observeIndex(details)
        let status = engine.status()
        engineState = status.state
        let files = Format.count(status.files)
        if status.state == .ready {
            countLabel.stringValue = "\(files) files"
        } else {
            countLabel.stringValue = "\(status.state.label) · \(files)"
        }
        #if APP_STORE
        if !IndexAccess.hasGrant { countLabel.stringValue = "" }
        #else
        accessButton.isHidden = Permissions.hasFullDiskAccess
        #endif
        updateStatusLabel(details)
    }

    private func updateStatusLabel(_ currentDetails: [String: Any]? = nil) {
        let details = currentDetails ?? engine.details()
        if let problem = details["configuration_error"] as? String,!problem.isEmpty {
            statusLabel.stringValue = problem;statusLabel.textColor = .systemRed;return
        }
        if let problem = details["runtime_error"] as? String,!problem.isEmpty { statusLabel.stringValue = problem;statusLabel.textColor = .systemRed;return }
        #if APP_STORE
        accessButton.isHidden = IndexAccess.hasGrant
        #endif
        if let lastError {
            statusLabel.stringValue = lastError
            statusLabel.textColor = .systemRed
            return
        }
        statusLabel.textColor = .secondaryLabelColor
        #if APP_STORE
        // Nothing is indexed yet: say why and what to do, instead of "0 results" on an empty index.
        if !IndexAccess.hasGrant {
            statusLabel.stringValue = IndexAccess.explanation
            return
        }
        #endif
        if details["paused"] as? Bool == true || details["rebuild_required"] as? Bool == true {
            statusLabel.stringValue = SiftDiagnostics.summary(details);statusLabel.textColor = .systemOrange
        } else if currentQuery.isEmpty && currentFolder.isEmpty {
            statusLabel.stringValue = "Type to search · ↓ to results · ↩ open · ⌘R reveal · Space Quick Look · ⌘Y history"
        } else if appliedGeneration != generation && !backgroundSearch {
            statusLabel.stringValue = engineState == .loading || engineState == .scanning || engineState == .starting
                ? "Searching once the index is loaded…" : "Searching…"
        } else {
            let n = model.count
            let ms = lastQueryMillis < 10 ? String(format: "%.1f", lastQueryMillis) : String(format: "%.0f", lastQueryMillis)
            statusLabel.stringValue = "\(Format.count(n)) \(n == 1 ? "result" : "results") · \(ms) ms"
            if let loosened = model.results?.loosened {
                statusLabel.stringValue += " · Expanded folder query: \(loosened)"
            }
        }
        statusLabel.toolTip = statusLabel.stringValue
    }

    #if APP_STORE
    /// The status-line button, Search › Choose Folder to Index… and the first-run offer.
    @objc func chooseIndexFolder(_ sender: Any?) {
        IndexAccess.chooseAndGrant(for: window, engine: engine) { [weak self] in self?.indexFolderChanged($0) }
    }

    /// A folder was allowed (here or in Settings) or the attempt failed: the status line and the list follow.
    func indexFolderChanged(_ error: String?) {
        if let error { lastError = error; updateStatusLabel(); return }
        startStatusUpdates()
        runSearch()
    }
    #else
    @objc private func openAccessSettings() { Permissions.openFullDiskAccessSettings() }
    #endif

    // MARK: Searching

    private var currentQuery: String {
        let filters = ["","ext:pdf","ext:docx","ext:xlsx","ext:html","ext:png","ext:md"]
        let dates = ["","dm:today","dm:thisweek"]
        let sizes = ["","size:>1mb","size:>100mb"]
        return [searchField.stringValue.trimmingCharacters(in:.whitespaces),filters[max(0,typeFilter.indexOfSelectedItem)],dates[max(0,dateFilter.indexOfSelectedItem)],sizes[max(0,sizeFilter.indexOfSelectedItem)]].filter{!$0.isEmpty}.joined(separator:" ")
    }
    @objc private func filtersChanged() { runSearch() }
    private func observeIndex(_ details: [String: Any]) {
        let revision = (details["index_revision"] as? NSNumber)?.uint64Value ?? 0
        guard let previous = lastIndexRevision else { lastIndexRevision = revision; return }
        guard previous != revision else { return }
        if currentQuery.isEmpty { lastIndexRevision = revision; return }
        if refreshResultsIfNeeded() { lastIndexRevision = revision }
    }
    @discardableResult private func refreshResultsIfNeeded() -> Bool {
        guard appliedGeneration == generation, !currentQuery.isEmpty else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastBackgroundRefresh >= 2 else { return false }
        lastBackgroundRefresh = now
        runSearch(preserveSelection: true)
        return true
    }
    private var currentFolder: String { "" }
    private var visibleRange: Range<Int> {
        let visible = table.rows(in: table.visibleRect)
        let start = visible.location == NSNotFound ? 0 : max(0, visible.location)
        return start..<(start + max(1, visible.length))
    }
    private func unifiedQuery(_ query: String, folder: String) -> String {
        let folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return query }
        let escaped = folder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ["\"*\(escaped)*/**\"", query].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSControl) === searchField { historyCursor = nil }
        runSearch()
    }

    func setQuery(_ query: String) {
        searchField.stringValue = unifiedQuery(query, folder: scriptedFolder ?? "")
        scriptedFolder = nil
        runSearch()
    }
    func reportConfigurationError(_ message: String) { lastError = message; updateStatusLabel() }

    func reloadConfiguration() {
        caseInsensitive = UserDefaults.standard.object(forKey: "caseInsensitive") as? Bool ?? true
        caseButton.state = caseInsensitive ? .off : .on
        runSearch()
    }

    private func runSearch(preserveSelection:Bool = false) {
        generation += 1
        backgroundSearch = preserveSelection
        if preserveSelection { backgroundSearchesForTesting += 1 }
        let gen = generation
        let query = currentQuery
        let folder = currentFolder
        let visible = preserveSelection ? visibleRange : 0..<max(1, visibleRange.count)
        lastError = nil
        if query.isEmpty && folder.isEmpty {
            apply(nil, generation: gen, millis: 0)
            return
        }
        // Only mention a pending search if it is not near-instant (avoids flicker).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.generation == gen, self.appliedGeneration != gen, !self.backgroundSearch else { return }
            self.updateStatusLabel()
        }
        let ci = caseInsensitive
        let sortKey = sortKey
        let descending = sortDescending
        let paths = preserveSelection ? selectionPaths : []
        let all = preserveSelection && model.count > 0 && table.numberOfSelectedRows == model.count
        DispatchQueue.global(qos: .userInteractive).async { [engine, weak self] in
            let outcome = engine.search(query: query, folder: folder.isEmpty ? nil : folder, caseInsensitive: ci)
            // Report work time, not wall time: a search typed during launch waits
            // for the index to load, and that wait is not the search's cost.
            var millis = 0.0
            var located: IndexSet?
            var prepared: [Int: [FileRow]] = [:]
            if case .results(let set) = outcome {
                millis = set.searchMillis
                if let sortKey {
                    let started = DispatchTime.now()
                    guard engine.sort(set, by: sortKey, descending: descending) else {
                        DispatchQueue.main.async { self?.retryIfLatest(gen, preserveSelection: preserveSelection) }
                        return
                    }
                    millis += Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                }
                guard let pages = ResultModel.prepare(set, engine: engine, visible: visible) else {
                    DispatchQueue.main.async { self?.retryIfLatest(gen, preserveSelection: preserveSelection) }
                    return
                }
                prepared = pages
                if preserveSelection {
                    let visibleMatches = IndexSet(pages.flatMap { page, rows in rows.enumerated().compactMap { offset, row in paths.contains(row.path) ? page * ResultModel.pageSize + offset : nil } })
                    located = all ? IndexSet(integersIn:0..<set.count) : (visibleMatches.count == paths.count ? visibleMatches : engine.locate(set,paths:paths))
                }
            }
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                switch outcome {
                case .results(let set): self.restoration = located;self.apply(set, generation: gen, millis: millis, prepared: prepared, background: preserveSelection)
                case .cancelled: self.retryIfLatest(gen, preserveSelection: preserveSelection)
                case .failed(let message):
                    self.appliedGeneration = gen
                    self.lastError = message
                    self.updateStatusLabel()
                }
            }
        }
    }

    /// Searches run on a concurrent queue and each takes a fresh cancellation token when it starts, so an
    /// older search that starts late can cancel the newest one. Only the newest search is re-run.
    private func retryIfLatest(_ gen: Int, preserveSelection: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.runSearch(preserveSelection: preserveSelection)
        }
    }

    private func apply(_ results: ResultSet?, generation gen: Int, millis: Double, prepared: [Int: [FileRow]] = [:], background: Bool = false) {
        guard gen == generation else { return }
        appliedGeneration = gen
        lastQueryMillis = millis
        let unchanged = background && model.matches(results, pages: prepared)
        model.replace(with: results, prepared: prepared)
        if !unchanged { resultReloadsForTesting += 1; table.reloadData() }
        if let restored = restoration {
            if table.selectedRowIndexes != restored { table.selectRowIndexes(restored,byExtendingSelection:false) }
            restoration = nil
        } else if model.count > 0 {
            let row = min(pendingSelection ?? 0, model.count - 1)
            pendingSelection = nil
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        selectionPaths = model.cachedPaths(table.selectedRowIndexes)
        updateStatusLabel()
        if !unchanged { refreshQuickLook() }
    }

    private func rowsArrived(_ range: Range<Int>) {
        selectionPaths = model.cachedPaths(table.selectedRowIndexes)
        let visible = table.rows(in: table.visibleRect)
        let lo = max(range.lowerBound, visible.location)
        let hi = min(range.upperBound, visible.location + visible.length)
        guard lo < hi else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: lo..<hi),
                         columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible,
           table.selectedRowIndexes.contains(where: { range.contains($0) }) {
            refreshQuickLook()
        }
    }

    /// Header clicks arrive here; menu shortcuts go through `sortBy`.
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !settingSortDescriptors else { return }
        let d = tableView.sortDescriptors.first
        let key = d.flatMap { UInt8($0.key ?? "") }.flatMap(SortKey.init(rawValue:))
        applySort(key, descending: !(d?.ascending ?? true))
    }

    private var settingSortDescriptors = false

    func sortBy(_ key: SortKey) {
        let descending: Bool
        if sortKey == key { descending = !sortDescending } else { descending = !(key == .name || key == .path) }
        settingSortDescriptors = true
        table.sortDescriptors = [NSSortDescriptor(key: String(key.rawValue), ascending: !descending)]
        settingSortDescriptors = false
        applySort(key, descending: descending)
    }

    private func applySort(_ key: SortKey?, descending: Bool) {
        guard key != sortKey || descending != sortDescending else { return }
        sortKey = key
        sortDescending = descending
        Prefs.set(key.map{Int($0.rawValue)},forKey:"sortKey")
        Prefs.set(descending,forKey:"sortDescending")
        runSearch()
    }

    // MARK: Keyboard in the search fields

    /// Only Cardinal's field keys are handled here; every other text-editing
    /// command (⌘⌫, ⌥⌫, ⌘←/→, ⌘↑/↓, ⌃K…) keeps its standard macOS behavior.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        // Cardinal: ↑/↓ walk recent searches; ↓ past the newest moves into the results.
        case #selector(NSResponder.moveDown(_:)):
            if control === searchField { newerHistory() } else { enterResults() }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if control === searchField { olderHistory(); return true }
            return false
        case #selector(NSResponder.moveLeft(_:)):
            return false
        case #selector(NSResponder.moveRight(_:)):
            return false
        case #selector(NSResponder.insertNewline(_:)):
            // Cardinal: ↩ in the field only commits the search (to history); it never opens a file.
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                revealSelection(nil)
            } else {
                history.record(searchField.stringValue)
                runSearch()
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            if control === searchField, model.count > 0 {
                window?.makeFirstResponder(table)
                return true
            }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            hide() // Cardinal: Esc hides the window and keeps the query
            return true
        default:
            return false
        }
    }

    private func olderHistory() {
        let items = history.items
        var next = (historyCursor ?? -1) + 1
        if historyCursor == nil {
            historyDraft = searchField.stringValue
            while next < items.count && items[next] == historyDraft { next += 1 }
        }
        guard next < items.count else { return }
        historyCursor = next
        showHistoryEntry(items[next])
    }

    private func newerHistory() {
        guard let cursor = historyCursor else { enterResults(); return }
        if cursor == 0 {
            historyCursor = nil
            showHistoryEntry(historyDraft)
        } else {
            historyCursor = cursor - 1
            showHistoryEntry(history.items[cursor - 1])
        }
    }

    private func showHistoryEntry(_ query: String) {
        setQuery(query)
        searchField.currentEditor()?.selectedRange = NSRange(location: query.utf16.count, length: 0)
    }

    private func enterResults() {
        guard model.count > 0 else { return }
        selectRow(0)
        window?.makeFirstResponder(table)
    }


    private func moveSelection(by delta: Int) {
        guard model.count > 0 else { return }
        let current = table.selectedRowIndexes.last ?? -1
        selectRow(min(max(current + delta, 0), model.count - 1))
    }

    private func selectRow(_ row: Int) {
        guard row >= 0, row < model.count else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
        let item = model.row(at: row)
        switch id.rawValue {
        case "name":
            cell.imageView?.image = item.map { IconCache.shared.icon(for: $0) }
            (cell as? NameCellView)?.show(item?.name ?? "…", highlights: item == nil ? [] : model.highlights)
        case "folder":
            cell.textField?.stringValue = item?.folder ?? ""
        case "size":
            cell.textField?.stringValue = item.map(Format.size) ?? ""
        case "created":
            cell.textField?.stringValue = item.map { Format.date($0.ctime) } ?? ""
        default:
            cell.textField?.stringValue = item.map { Format.date($0.mtime) } ?? ""
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = id.rawValue == "name" ? NameCellView() : NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.usesSingleLineMode = true
        text.cell?.wraps = false
        text.cell?.truncatesLastVisibleLine = true
        text.lineBreakMode = id.rawValue == "folder" ? .byTruncatingMiddle : .byTruncatingTail
        text.font = id.rawValue == "size" ? .monospacedDigitSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 13)
        if id.rawValue != "name" { text.textColor = .secondaryLabelColor }
        if id.rawValue == "size" { text.alignment = .right }
        cell.addSubview(text)
        cell.textField = text
        if id.rawValue == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectionPaths = model.cachedPaths(table.selectedRowIndexes);refreshQuickLook() }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let item = model.row(at: row) else { return nil }
        return URL(fileURLWithPath: item.path) as NSURL
    }

    // MARK: Actions

    private var selectedRows: [FileRow] {
        var indexes = table.selectedRowIndexes
        if indexes.isEmpty, table.clickedRow >= 0 { indexes = IndexSet(integer: table.clickedRow) }
        return model.rowsNow(indexes).filter { !$0.path.isEmpty }
    }

    private func actionRows() -> [FileRow] {
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
            return model.rowsNow(IndexSet(integer: clicked))
        }
        return selectedRows
    }

    @objc func openSelection(_ sender: Any?) {
        let rows = actionRows()
        guard !rows.isEmpty else { NSSound.beep(); return }
        history.record(searchField.stringValue)
        if Prefs.dryRun("open", rows.map(\.path)) { return }
        for row in rows { NSWorkspace.shared.open(URL(fileURLWithPath: row.path)) }
    }

    @objc func revealSelection(_ sender: Any?) {
        let rows = actionRows()
        guard !rows.isEmpty else { NSSound.beep(); return }
        history.record(searchField.stringValue)
        if Prefs.dryRun("reveal", rows.map(\.path)) { return }
        NSWorkspace.shared.activateFileViewerSelecting(rows.map { URL(fileURLWithPath: $0.path) })
    }

    @objc func copyPaths(_ sender: Any?) {
        let rows = actionRows()
        guard !rows.isEmpty, !Prefs.dryRun("copy paths", rows.map(\.path)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(rows.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc func copyNames(_ sender: Any?) {
        let rows = actionRows()
        guard !rows.isEmpty, !Prefs.dryRun("copy names", rows.map(\.path)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(rows.map(\.name).joined(separator: "\n"), forType: .string)
    }

    /// ⌘C: copies files when the table has focus, text otherwise.
    @objc func copy(_ sender: Any?) {
        let rows = actionRows()
        guard !rows.isEmpty, !Prefs.dryRun("copy files", rows.map(\.path)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(rows.map { URL(fileURLWithPath: $0.path) as NSURL })
    }

    @objc func moveToTrash(_ sender: Any?) {
        let rows = actionRows()
        guard !rows.isEmpty, !Prefs.dryRun("trash", rows.map(\.path)) else { return }
        let alert = NSAlert()
        alert.messageText = rows.count == 1
            ? "Move “\(rows[0].name)” to the Trash?"
            : "Move \(rows.count) items to the Trash?"
        alert.informativeText = "You can put items back from the Trash in Finder."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FileActions.recycle(rows.map { URL(fileURLWithPath: $0.path) }) { [weak self] _, error in
            if let error { NSApp.presentError(error) }
            self?.runSearch()
        }
    }

    /// `sift trash` moved files (AppActions): the list is searched again, as after the window's own Move to Trash.
    func resultsMayHaveChanged() { runSearch() }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    @objc func toggleFolderScope(_ sender: Any?) {
        focusSearch(nil) // Compatibility with a stored shortcut; the product has one input now.
    }

    @objc func toggleCase(_ sender: Any?) {
        caseInsensitive.toggle()
        caseButton.state = caseInsensitive ? .off : .on
        Prefs.set(caseInsensitive, forKey: "caseInsensitive")
        runSearch()
    }

    @objc private func toggleCaseFromButton() {
        caseInsensitive = caseButton.state == .off
        Prefs.set(caseInsensitive, forKey: "caseInsensitive")
        runSearch()
    }

    @objc func showHistory(_ sender: Any?) {
        // A pop-up menu tracks the real mouse and keyboard: never in verification runs.
        if Prefs.dryRun("history menu", history.items) { return }
        let menu = NSMenu()
        if history.items.isEmpty {
            menu.addItem(NSMenuItem(title: "No recent searches", action: nil, keyEquivalent: ""))
        } else {
            for q in history.items.prefix(20) {
                let item = NSMenuItem(title: q, action: #selector(pickHistory(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Recent Searches", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        let anchor = NSPoint(x: 0, y: historyButton.bounds.height + 4)
        menu.popUp(positioning: nil, at: anchor, in: historyButton)
    }

    @objc private func pickHistory(_ item: NSMenuItem) {
        setQuery(item.title)
        focusSearch(nil)
    }

    @objc private func clearHistory() { history.clear() }

    /// `sift history clear --yes` removed the saved list (AppDelegate hears of it): drop this window's copy as
    /// the menu item does, or the next recorded search would store the old list again.
    func clearRecentSearches() {
        history.clear()
        historyCursor = nil
    }

    @objc func sortMenu(_ item: NSMenuItem) {
        if let key = SortKey(rawValue: UInt8(item.tag)) { sortBy(key) }
    }

    @objc func rescan(_ sender: Any?) {
        guard engine.details()["paused"] as? Bool != true else { reportConfigurationError("索引已暂停，请先在设置中恢复后重建");return }
        engine.rescan()
        startStatusUpdates()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(rescan(_:)): return engine.details()["paused"] as? Bool != true
        case #selector(openSelection(_:)), #selector(revealSelection(_:)), #selector(copyPaths(_:)),
             #selector(copyNames(_:)), #selector(moveToTrash(_:)), #selector(toggleQuickLook(_:)),
             #selector(openWithSelection(_:)), #selector(showFileInfo(_:)), #selector(renameSelection(_:)):
            // Main-menu shortcuts act on files only while the list has focus, so
            // ⌘⌫, ⌘R, ⌘O… in the search field stay text edits or do nothing.
            if item.menu === table.menu { return table.clickedRow >= 0 }
            return window?.firstResponder === table && !table.selectedRowIndexes.isEmpty
        case #selector(copy(_:)):
            if item.menu === table.menu { return table.clickedRow >= 0 }
            return window?.firstResponder === table && !table.selectedRowIndexes.isEmpty
        case #selector(toggleFolderScope(_:)):
            return true
        case #selector(toggleCase(_:)):
            item.state = caseInsensitive ? .off : .on
            return true
        default:
            return true
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0 else { return }
        // Same items and shortcut hints as Cardinal's context menu, plus Trash.
        let entries: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Open", #selector(openSelection(_:)), "o", .command),
            ("Show in Finder", #selector(revealSelection(_:)), "r", .command),
            ("用其他应用打开…",#selector(openWithSelection(_:)),"",[]),
            ("文件信息",#selector(showFileInfo(_:)),"",[]),
            ("重命名…",#selector(renameSelection(_:)),"",[]),
            ("-", #selector(copy(_:)), "", []),
            ("Copy Name", #selector(copyNames(_:)), "n", [.command, .control, .shift]),
            ("Copy Path", #selector(copyPaths(_:)), "C", .command),
            ("Copy", #selector(copy(_:)), "c", .command),
            ("Quick Look", #selector(toggleQuickLook(_:)), " ", []),
            ("-", #selector(copy(_:)), "", []),
            ("Move to Trash", #selector(moveToTrash(_:)), String(UnicodeScalar(NSBackspaceCharacter)!), .command),
        ]
        for (title, action, key, mods) in entries {
            if title == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: SiftText.title(title), action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            if let binding = ShortcutAction.all.first(where:{$0.selector == NSStringFromSelector(action)}) {
                if SiftShortcuts.shared.scope(binding.id) == "app",let combo = SiftShortcuts.shared.combo(binding) { item.keyEquivalent = combo.menuKey;item.keyEquivalentModifierMask = combo.modifiers }
                else { item.keyEquivalent = "" }
            }
            item.target = self
            menu.addItem(item)
        }
    }

    // MARK: Quick Look

    @objc func saveCurrentSearch(_ sender:Any?) {
        guard !currentQuery.isEmpty,!Prefs.dryRun("save search",[]) else { return }
        let alert = NSAlert();alert.messageText = "保存常用搜索";alert.informativeText = currentQuery
        let name = NSTextField(frame:NSRect(x:0,y:0,width:300,height:24));name.placeholderString = "搜索名称";alert.accessoryView = name
        alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
        let query = currentQuery,folder = currentFolder,ci = caseInsensitive
        alert.beginSheetModal(for:(sender as? NSWindow) ?? window!) { result in
            guard result == .alertFirstButtonReturn else { return }
            do { try SavedSearches.add(name:name.stringValue,query:query,folder:folder,caseInsensitive:ci) } catch { NSApp.presentError(error) }
        }
    }
    @objc func showSavedSearches(_ sender:Any?) {
        guard !Prefs.dryRun("saved searches",[]) else { return }
        let menu = NSMenu()
        for saved in SavedSearches.items {
            let item = NSMenuItem(title:saved["name"] ?? "",action:#selector(pickSaved(_:)),keyEquivalent:"");item.target = self;item.representedObject = saved;menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(NSMenuItem(title:"尚无常用搜索，可保存当前搜索",action:nil,keyEquivalent:"")) }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:historyButton.bounds.height + 4),in:historyButton)
    }
    @objc private func pickSaved(_ item:NSMenuItem) {
        typeFilter.selectItem(at:0);dateFilter.selectItem(at:0);sizeFilter.selectItem(at:0)
        if let saved = item.representedObject as? [String:String] { restoreSavedSearch(saved) };focusSearch(nil)
    }
    func restoreSavedSearch(_ saved:[String:String]) {
        typeFilter.selectItem(at:0);dateFilter.selectItem(at:0);sizeFilter.selectItem(at:0)
        caseInsensitive = saved["caseInsensitive"] != "false";caseButton.state = caseInsensitive ? .off : .on
        Prefs.set(caseInsensitive,forKey:"caseInsensitive")
        setQuery(unifiedQuery(saved["query"] ?? "", folder: saved["folder"] ?? ""))
    }
    @objc func showFileInfo(_ sender:Any?) {
        let rows = actionRows();guard let row = rows.first,!Prefs.dryRun("file info",rows.map(\.path)) else { return }
        do { let info = try ProductFiles.info(row.path);let alert = NSAlert();alert.messageText = row.name;alert.informativeText = "路径：\(row.path)\n类型：\(info["kind"] ?? "")\n大小：\(info["size"] ?? 0) 字节\n可读：\(info["readable"] ?? false) · 可写：\(info["writable"] ?? false)";alert.beginSheetModal(for:window!,completionHandler:nil) }
        catch { NSApp.presentError(error) }
    }
    @objc func renameSelection(_ sender:Any?) {
        let rows = actionRows();guard rows.count == 1,let row = rows.first,!Prefs.dryRun("rename",[row.path]) else { return }
        let alert = NSAlert();alert.messageText = "重命名";alert.informativeText = "在原文件夹内改名，不覆盖已有文件。"
        let name = NSTextField(frame:NSRect(x:0,y:0,width:330,height:24));name.stringValue = row.name;alert.accessoryView = name
        alert.addButton(withTitle:"重命名");alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for:window!) { [weak self] result in guard result == .alertFirstButtonReturn else { return };do { _ = try ProductFiles.rename(row.path,to:name.stringValue);self?.runSearch() } catch { NSApp.presentError(error) } }
    }
    @objc func openWithSelection(_ sender:Any?) {
        let rows = actionRows();guard !rows.isEmpty,!Prefs.dryRun("open with",rows.map(\.path)) else { return }
        let panel = NSOpenPanel();panel.title = "选择打开应用";panel.directoryURL = URL(fileURLWithPath:"/Applications");panel.canChooseFiles = true;panel.canChooseDirectories = false;panel.allowsMultipleSelection = false;panel.allowedContentTypes = [.applicationBundle]
        panel.beginSheetModal(for:window!) { result in guard result == .OK,let application = panel.url else { return };NSWorkspace.shared.open(rows.map{URL(fileURLWithPath:$0.path)},withApplicationAt:application,configuration:NSWorkspace.OpenConfiguration()) { _,error in if let error { DispatchQueue.main.async { NSApp.presentError(error) } } } }
    }
    @objc func exportResults(_ sender:Any?) {
        guard let results = model.results,!Prefs.dryRun("export results",[]) else { return }
        ResultExporter.export(engine:engine,results:results,window:window!)
    }

    @objc func toggleQuickLook(_ sender: Any?) {
        if Prefs.dryRun("quick look", model.rowsNow(table.selectedRowIndexes).map(\.path)) { return }
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private var previewURLs: [URL] = []

    private func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else { return }
        previewURLs = model.rowsNow(table.selectedRowIndexes).map { URL(fileURLWithPath: $0.path) }
        QLPreviewPanel.shared().reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        previewURLs = model.rowsNow(table.selectedRowIndexes).map { URL(fileURLWithPath: $0.path) }
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension SearchWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs[index] as NSURL
    }

    /// Arrow keys in the preview move the selection, like Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125: moveSelection(by: 1); return true
        case 126: moveSelection(by: -1); return true
        default: return false
        }
    }
}

/// Name cell: matched text is bold in the row's own text color (as Cardinal
/// does), so it stays readable selected or not, in light and dark.
final class NameCellView: NSTableCellView {
    private var name = ""
    private var highlights: [String] = []

    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if oldValue != backgroundStyle { render() } }
    }

    func show(_ name: String, highlights: [String]) {
        self.name = name
        self.highlights = highlights
        render()
    }

    private func render() {
        let selected = backgroundStyle == .emphasized
        let base: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let s = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: base,
            .paragraphStyle: Self.truncating,
        ])
        let bold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let ns = name as NSString
        for needle in highlights where !needle.isEmpty {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: needle, options: [.caseInsensitive], range: search)
                if r.location == NSNotFound { break }
                s.addAttribute(.font, value: bold, range: r)
                let next = r.location + max(r.length, 1)
                if next >= ns.length { break }
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        textField?.attributedStringValue = s
    }
}
