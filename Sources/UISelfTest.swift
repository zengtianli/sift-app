import AppKit

/// `--ui-self-test [--out <dir>]`: in-process, offscreen check of the real search and settings
/// windows. Action code paths are called directly — no synthesized events, no menus, no activation,
/// no window is ever ordered onto the screen. Runs read-only (`Prefs.readOnly`, `SIFT_READONLY`):
/// no preference writes, no index writes, no IPC socket. Prints one final JSON line
/// `{"ok":…,"checks":{…},"screenshots":[…]}` and exits 0 (all passed) or 1; hard timeout 60 s.
///
/// Expected fixture (scripts/accept/native_ui.sh; built here into a temp dir when SIFT_SUPPORT_DIR
/// is unset): docs/README.md, docs/nested/readme-notes.txt, sorttest/sortcase-{alpha,beta,gamma}.dat
/// with sizes 3000/10/200 bytes and mtimes 2021/2029/2024, and `.hidden/` on the ignore list.
@MainActor
final class UISelfTest {
    private static var current: UISelfTest?
    nonisolated private static let timeoutSeconds = 60.0
    nonisolated(unsafe) private static var tempFixture: URL?

    private let engine: Engine
    private let search: SearchWindowController
    private let hotkey: GlobalHotkey
    private let outDir: URL
    private var checks: [(String, Bool)] = []
    private var details: [String: Any] = [:]
    private var screenshots: [String] = []
    /// Only populated by the explicitly isolated bilingual acceptance entry. Values are read
    /// from the real AppKit controls; user-entered text is never treated as product copy.
    private var localizationSurfaces: [String: [[String: String]]] = [:]
    private var localizationShared: [[String: String]] = []
    nonisolated private static let progress = NSLock()
    nonisolated(unsafe) private static var step = "start"

    /// Called before the engine starts: without a private support dir the test builds its own
    /// fixture, so it never opens the user's index. `settle: false` is the hidden cold-launch measurement
    /// (`-lane_quiet`): it only needs an index of its own, and the wait would be counted as launch time.
    static func prepareEnvironment(settle: Bool = true) {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["SIFT_SUPPORT_DIR"], !dir.isEmpty { return }
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sift-uitest-\(getpid())")
        let root = base.appendingPathComponent("fixture"), support = base.appendingPathComponent("support")
        let fm = FileManager.default
        func file(_ path: String, _ bytes: Int, year: Int? = nil) {
            let url = root.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(repeating: 0x61, count: bytes))
            if let year {
                let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 1, day: 1))!
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
        }
        file("docs/README.md", 2); file("docs/nested/readme-notes.txt", 2); file("docs/nested/deep/alpha.pdf", 2)
        file("space dir (1)/file with space!.txt", 2); file(".hidden/secret.key", 2); file("docs/big.bin", 4096)
        file("sorttest/sortcase-alpha.dat", 3000, year: 2021); file("sorttest/sortcase-beta.dat", 10, year: 2029)
        file("sorttest/sortcase-gamma.dat", 200, year: 2024)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        let config: [String: Any] = ["root": root.path, "ignore_paths": [root.appendingPathComponent(".hidden").path], "include_paths": []]
        try? JSONSerialization.data(withJSONObject: config).write(to: support.appendingPathComponent("config.json"))
        setenv("SIFT_SUPPORT_DIR", support.path, 1)
        #if APP_STORE
        if Bundle.main.bundleIdentifier?.hasPrefix(Lifecycle.isolatedBundlePrefix) == true {
            setenv(IndexAccess.testGrantVariable,root.path,1)
        }
        #endif
        tempFixture = base
        // Let the fixture's own file events age past the engine's FSEvents start: files created
        // milliseconds before the first walk were otherwise indexed twice (walk + replayed create).
        if settle { Thread.sleep(forTimeInterval: 1.5) }
    }

    static func start(engine: Engine, searchWindow: SearchWindowController, hotkey: GlobalHotkey, args: [String]) {
        hotkey.unregister()
        let out: URL
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            out = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        } else if let env = ProcessInfo.processInfo.environment["SOP_SELF_TEST_OUT"], !env.isEmpty {
            out = URL(fileURLWithPath: env, isDirectory: true).appendingPathComponent("native_ui-shots")
        } else {
            out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sift-ui-self-test-\(getpid())")
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            progress.lock(); let at = step; progress.unlock()
            let json: [String: Any] = ["ok": false, "checks": [String: Bool](), "screenshots": [String](),
                                       "summary": "界面自检超过 \(Int(timeoutSeconds)) 秒未完成（停在 \(at)）"]
            emit(json)
            cleanupFixture()
            exit(1)
        }
        let test = UISelfTest(engine: engine, search: searchWindow, hotkey: hotkey, outDir: out)
        current = test
        Task { @MainActor in
            if args.contains("--demo-capture") { await test.recordDemo() }
            else { await test.run() }
        }
    }

    private init(engine: Engine, search: SearchWindowController, hotkey: GlobalHotkey, outDir: URL) {
        self.engine = engine
        self.search = search
        self.hotkey = hotkey
        self.outDir = outDir
    }

    // MARK: Helpers

    /// Continuous, hidden native-view capture. Calls the same search/sort actions as the UI;
    /// recorded pointer events describe these in-process actions, never system input.
    private func recordDemo() async {
        mark("demo capture")
        guard Prefs.readOnly, NSApp.activationPolicy() == .prohibited,
              await waitUntil(20, { engine.status().state == .ready }) else { exit(1) }
        #if APP_STORE
        let pointSize = NSSize(width:1280,height:800)
        let frameCount = 336
        #else
        let pointSize = NSSize(width:1000,height:600)
        let frameCount = 216
        #endif
        search.prepareOffscreen(size:pointSize)
        if !search.caseInsensitiveForTesting { search.toggleCase(nil) }
        NSApp.appearance = NSAppearance(named: .aqua)
        search.window?.appearance = NSApp.appearance
        search.setQuery("")
        let frames = outDir.appendingPathComponent("frames")
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let fps = 12, count = frameCount
        var events: [[String: Any]] = []
        var facts: [[String: Any]] = []
        let started = ProcessInfo.processInfo.systemUptime
        let field = search.searchFieldForTesting
        let rect = field.convert(field.bounds, to: search.window!.contentView!)
        let fieldBox: [Double] = [Double(rect.minX), Double(pointSize.height - rect.maxY), Double(rect.width), Double(rect.height)]
        func event(_ type: String, _ t: Double, _ box: [Double], _ key: String? = nil) {
            var e: [String: Any] = ["type": type, "t": t, "x": box[0] + box[2]/2, "y": box[1] + box[3]/2, "bbox": box,
                                    "source": "in_process_product_action"]
            if let key { e["key"] = key }
            events.append(e)
        }
        event("move", 0, fieldBox)
        for i in 0..<count {
            let t = Double(i) / Double(fps)
            if i == 18 || i == 96 {
                event("move", t, fieldBox); event("down", t, fieldBox); event("up", t + 0.01, fieldBox)
                search.focusSearch(nil)
                if i == 96 { search.setQuery("") }
            }
            if (24..<42).contains(i), i % 3 == 0 {
                let text = String("readme".prefix((i - 24)/3 + 1))
                search.setQuery(text); event("key", t, fieldBox, String(text.suffix(1)))
            }
            if i == 66 {
                event("key", t, fieldBox, "ArrowDown")
                search.moveSelectionForTesting(by: 1)
            }
            if (102..<138).contains(i), i % 3 == 0 {
                let text = String("nested notes".prefix((i - 102)/3 + 1))
                search.setQuery(text); event("key", t, fieldBox, String(text.suffix(1)))
            }
            if i == 174 {
                NSApp.appearance = NSAppearance(named: .darkAqua); search.window?.appearance = NSApp.appearance
            }
            #if APP_STORE
            if i == 216 {
                NSApp.appearance = NSAppearance(named:.aqua);search.window?.appearance = NSApp.appearance
                search.setQuery("alpha")
                event("key",t,fieldBox,"alpha")
            }
            if i == 252 {
                let filter = search.typeFilterFrameForTesting
                let box = [Double(filter.minX),Double(pointSize.height - filter.maxY),Double(filter.width),Double(filter.height)]
                event("move",t,box);event("down",t,box);event("up",t + 0.01,box)
                search.applyFiltersForTesting(type:1,date:0,size:0)
            }
            if i == 300 {
                facts.append(["t":t,"query":search.queryForTesting,"rows":search.rowNamesForTesting(limit:10),
                              "status":search.refreshStatusForTesting().status,"filter":"PDF"])
            }
            #endif
            if i == 60 || i == 156 {
                facts.append(["t": t, "query": search.queryForTesting, "rows": search.rowNamesForTesting(limit: 10),
                              "status": search.refreshStatusForTesting().status])
            }
            if search.window?.isVisible == true { exit(1) }
            try? search.writeSnapshot(to: frames.appendingPathComponent(String(format: "%04d.png", i)))
            let delay = started + Double(i + 1)/Double(fps) - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        }
        let report: [String: Any] = ["fps": fps, "frames": count, "duration": Double(count)/Double(fps),
            "elapsed": ProcessInfo.processInfo.systemUptime - started, "events": events, "facts": facts,
            "point_size": [Int(pointSize.width),Int(pointSize.height)], "activation_policy": "prohibited", "visible": false,
            "method": "continuous native NSView frames; isolated fixture; direct product actions; no system input"]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: outDir.appendingPathComponent("capture.json")) } catch { exit(1) }
        Self.cleanupFixture()
        exit(0)
    }

    private func mark(_ name: String) {
        Self.progress.lock(); Self.step = name; Self.progress.unlock()
    }

    private func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
        checks.append((name, ok))
        if let detail { details[name] = detail }
        if !ok { fputs("ui-self-test FAIL \(name): \(detail.map { "\($0)" } ?? "")\n", stderr) }
    }

    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return true
    }

    /// Waits for the latest search to be applied; then returns the first names (synchronous fetch).
    private func settled(_ limit: Int = 10) async -> [String] {
        _ = await waitUntil(10) { search.searchSettledForTesting }
        return search.rowNamesForTesting(limit: limit)
    }

    private func query(_ q: String) async -> [String] {
        search.setQuery(q)
        return await settled()
    }

    private var fieldEditor: NSTextView? {
        search.window?.fieldEditor(true, for: search.searchFieldForTesting) as? NSTextView
    }

    /// The search field's key handling, called as the field editor calls it (no event is created).
    @discardableResult
    private func fieldCommand(_ selector: Selector) -> Bool {
        guard let editor = fieldEditor else { return false }
        return search.control(search.searchFieldForTesting, textView: editor, doCommandBy: selector)
    }

    private var localizationLanguage: String? {
        ProcessInfo.processInfo.environment["SIFT_L10N_TEST_LANGUAGE"]
    }

    /// A Chinese brand name may remain alongside the English name. Everything else in these
    /// private fixtures is ASCII, so a Han character in a product control is untranslated copy.
    private static func containsChinese(_ value: String) -> Bool {
        value.replacingOccurrences(of: "速寻", with: "").unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
        }
    }

    private func strings(in root: NSView, path: String, excluding: Set<ObjectIdentifier> = []) -> [[String: String]] {
        var found: [[String: String]] = []
        func add(_ property: String, _ value: String?, _ at: String) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            found.append(["path": at, "property": property, "text": value])
        }
        func walk(_ view: NSView, _ at: String) {
            guard !excluding.contains(ObjectIdentifier(view)), !view.isHidden else { return }
            add("toolTip", view.toolTip, at)
            if let field = view as? NSTextField {
                add("placeholder", field.placeholderString, at)
                // Search terms, file paths and saved-search names are user data.
                if !field.isEditable { add("stringValue", field.stringValue, at) }
            }
            if let text = view as? NSTextView, !text.isEditable { add("string", text.string, at) }
            if let button = view as? NSButton {
                add("title", button.title, at)
                add("alternateTitle", button.alternateTitle, at)
            }
            if let popup = view as? NSPopUpButton, let menu = popup.menu {
                found += strings(in: menu, path: at + "/items", update: false).product
            }
            if let segmented = view as? NSSegmentedControl {
                for index in 0..<segmented.segmentCount { add("segment.\(index)", segmented.label(forSegment: index), at) }
            }
            if let table = view as? NSTableView {
                for (index, column) in table.tableColumns.enumerated() { add("column.\(index)", column.title, at) }
            }
            if let menu = view.menu {
                found += strings(in: menu, path: at + "/menu", update: true).product
            }
            if let search = view as? NSSearchField, let menu = search.searchMenuTemplate {
                found += strings(in: menu, path: at + "/searchMenu", update: false).product
            }
            for (index, child) in view.subviews.enumerated() {
                walk(child, at + "/\(String(describing: type(of: child)))[\(index)]")
            }
        }
        walk(root, path)
        return found
    }

    private func strings(in menu: NSMenu, path: String, update: Bool) -> (product: [[String: String]], shared: [[String: String]]) {
        if update { menu.delegate?.menuNeedsUpdate?(menu) }
        var product: [[String: String]] = [], shared: [[String: String]] = []
        if !menu.title.isEmpty { product.append(["path": path, "property": "menu.title", "text": menu.title]) }
        for (index, item) in menu.items.enumerated() where !item.isSeparatorItem && !item.isHidden {
            let at = path + "/item[\(index)]"
            let value = ["path": at, "property": "title", "text": item.title]
            // These menu items are supplied by the shared lifecycle source, which this product
            // task must not edit. Keep their actual text in the separate follow-up report.
            let isShared = item.target.map { String(describing: type(of: $0)).contains("AppLifecycleUI") } ?? false
            if isShared { shared.append(value) } else { product.append(value) }
            if let child = item.submenu {
                let values = strings(in: child, path: at, update: update)
                product += values.product; shared += values.shared
            }
        }
        return (product, shared)
    }

    private func auditLocalization(_ name: String, views: [NSView], title: String? = nil) {
        guard localizationLanguage != nil else { return }
        var values = views.enumerated().flatMap { strings(in: $0.element, path: "\(name)/view[\($0.offset)]") }
        if let title { values.append(["path": name, "property": "window.title", "text": title]) }
        localizationSurfaces[name] = values
    }

    private func finishLocalization(settings: SettingsWindowController) {
        guard let language = localizationLanguage else { return }
        if let menu = NSApp.mainMenu {
            let values = strings(in: menu, path: "main-menu", update: true)
            localizationSurfaces["main-menu"] = values.product
            localizationShared += values.shared
        }
        for (index, menu) in search.interfaceMenusForTesting.enumerated() {
            let values = strings(in: menu, path: "search-menu[\(index)]", update: false)
            localizationSurfaces["search-menu-\(index)"] = values.product
            localizationShared += values.shared
        }
        localizationSurfaces["engine-state-labels"] = (0...6).compactMap { EngineState(rawValue: UInt8($0)) }.map {
            ["path": "engine-state/\($0.rawValue)", "property": "label", "text": SiftText.title($0.label)]
        }
        let groups = settings.groups()
        if let window = groups.first?.window, let view = window.contentView {
            localizationShared += strings(in: view, path: "shared-settings", excluding: Set(groups.map(ObjectIdentifier.init)))
            localizationShared.append(["path": "shared-settings", "property": "window.title", "text": window.title])
        }
        let remaining = localizationSurfaces.sorted(by: { $0.key < $1.key }).flatMap { name, rows in
            // The language options name each language in itself (shared LifecycleLanguage): 简体中文 stays Chinese.
            rows.filter { Self.containsChinese($0["text"] ?? "") && !LifecycleLanguage.allCases.map(\.title).contains($0["text"] ?? "") }.map { row -> [String: String] in
                var result = row; result["surface"] = name; return result
            }
        }
        let preferred = Bundle.main.preferredLocalizations.first ?? ""
        let domain = Bundle.main.bundleIdentifier ?? ""
        check("localization_private_readonly_instance", domain.hasPrefix(Lifecycle.isolatedBundlePrefix)
              && Prefs.readOnly && Lifecycle.isolated && Self.tempFixture != nil,
              ["preference_domain": domain, "support_directory": AppDelegate.supportDirectory.path])
        check("localization_requested_language_loaded", preferred == language || (language == "zh-Hans" && preferred.hasPrefix("zh")),
              ["requested": language, "preferred": preferred])
        check("localization_windows_remain_offscreen", NSApp.activationPolicy() == .prohibited && NSApp.windows.allSatisfy { !$0.isVisible })
        check("english_major_views_no_chinese", language != "en" || remaining.isEmpty, remaining)
        details["localization"] = ["language": language, "preferred_localizations": Bundle.main.preferredLocalizations,
            "preference_domain": domain, "support_directory": AppDelegate.supportDirectory.path,
            "surfaces": localizationSurfaces, "remaining_chinese": remaining,
            "shared_remaining_chinese": localizationShared.filter { Self.containsChinese($0["text"] ?? "") },
            "excluded_user_data": "Editable control values; fixture file names, paths and search terms are ASCII. The Chinese brand name 速寻 is allowed."]
    }

    // MARK: Run

    private func run() async {
        mark("index")
        let ready = await waitUntil(40) { engine.status().state == .ready }
        let status = engine.status()
        check("index_ready", ready && status.files > 0, ["state": status.state.label, "files": status.files])

        mark("window")
        #if APP_STORE
        search.prepareOffscreen(size:NSSize(width:1280,height:800))
        #else
        search.prepareOffscreen(size: NSSize(width: 1000, height: 600))
        #endif
        check("search_window_built_offscreen", search.window?.contentView != nil && search.window?.isVisible == false)
        // Normalize the user's saved toggles (read-only here; nothing is written back).
        if !search.caseInsensitiveForTesting { search.toggleCase(nil) }
        if search.folderVisibleForTesting { search.toggleFolderScope(nil) }

        mark("query")
        let readme = await query("readme")
        check("query_rows", readme.count >= 2 && Set(readme).isSuperset(of: ["README.md", "readme-notes.txt"]), readme)
        let expanded = await query("nested notes")
        let expandedStatus = search.refreshStatusForTesting().status
        let expandedQuery = "(nested|*nested*/**) (notes|*notes*/**)"
        let expandedLabel = String(localized: " · Expanded folder query: \(expandedQuery)", table: "Search")
        check("loosened_query_status", expanded == ["readme-notes.txt"] && expandedStatus.contains(expandedLabel), expandedStatus)
        auditLocalization("search-expanded", views: search.window?.contentView.map { [$0] } ?? [], title: search.window?.title)
        _ = await query("readme")
        let expandedPrefix = String(localized: " · Expanded folder query: \(String())", table: "Search")
        check("strict_query_clears_loosened_status", !search.refreshStatusForTesting().status.contains(expandedPrefix))
        let sorted = await query("sortcase")
        check("query_fixture_rows", sorted.count == 3 && Set(sorted) == ["sortcase-alpha.dat", "sortcase-beta.dat", "sortcase-gamma.dat"], sorted)
        check("first_row_selected", search.selectedRowForTesting == 0, search.selectedRowForTesting)

        mark("sort")
        search.sortBy(.name)
        let byName = await settled()
        check("sort_name_ascending", byName == ["sortcase-alpha.dat", "sortcase-beta.dat", "sortcase-gamma.dat"]
              && search.sortForTesting.key == .name && !search.sortForTesting.descending, byName)
        search.sortBy(.size)
        let bySize = await settled()
        let sizes = search.rowsForTesting(limit: 3).map(\.size)
        check("sort_size_descending", bySize == ["sortcase-alpha.dat", "sortcase-gamma.dat", "sortcase-beta.dat"]
              && sizes == sizes.sorted(by: >), ["names": bySize, "sizes": sizes])
        search.sortBy(.modified)
        let byModified = await settled()
        check("sort_modified_descending", byModified == ["sortcase-beta.dat", "sortcase-gamma.dat", "sortcase-alpha.dat"], byModified)
        search.sortBy(.modified) // same key again flips direction, as a second header click does
        let byModifiedAsc = await settled()
        check("sort_toggle_direction", byModifiedAsc == ["sortcase-alpha.dat", "sortcase-gamma.dat", "sortcase-beta.dat"]
              && !search.sortForTesting.descending, byModifiedAsc)
        search.sortBy(.name)
        _ = await settled()

        mark("case")
        let insensitive = await query("README")
        search.toggleCase(nil)
        let sensitive = await settled()
        check("case_toggle_changes_results", insensitive.count >= 2 && sensitive == ["README.md"]
              && search.caseButtonOnForTesting && !search.caseInsensitiveForTesting,
              ["insensitive": insensitive, "sensitive": sensitive])
        search.toggleCase(nil)
        let back = await settled()
        check("case_toggle_back", back.count == insensitive.count && search.caseInsensitiveForTesting, back)

        mark("folder")
        let allReadme = await query("readme")
        search.restoreSavedSearch(["query":"readme","folder":"nested","caseInsensitive":"true"])
        let scoped = await settled()
        check("legacy_folder_scope_uses_single_query", !search.folderVisibleForTesting && search.queryForTesting.contains("nested") && scoped == ["readme-notes.txt"]
              && allReadme.count > scoped.count, ["all": allReadme, "in_nested": scoped])
        let unscoped = await query("readme")
        check("single_query_restores_unscoped_results", !search.folderVisibleForTesting && unscoped.count == allReadme.count, unscoped)

        mark("filters and export")
        _ = await query("alpha")
        search.applyFiltersForTesting(type:1,date:1,size:0)
        let pdfToday = await settled()
        check("type_and_date_filters_find_fixture_pdf",pdfToday == ["alpha.pdf"],pdfToday)
        #if APP_STORE
        try? search.writeSnapshot(to:outDir.appendingPathComponent("search-filtered.png"))
        screenshots.append(outDir.appendingPathComponent("search-filtered.png").path)
        #endif
        search.applyFiltersForTesting(type:0,date:0,size:1)
        let tooSmall = await query("sortcase")
        check("size_filter_excludes_small_files",tooSmall.isEmpty,tooSmall)
        search.applyFiltersForTesting(type:0,date:0,size:0)
        _ = await query("sortcase")
        if case .results(let results) = engine.search(query:"sortcase",folder:nil,caseInsensitive:true) {
            do {
                let json = outDir.appendingPathComponent("results.json")
                let csv = outDir.appendingPathComponent("results.csv")
                let paths = outDir.appendingPathComponent("results.txt")
                let counts = try [ResultExporter.write(engine:engine,results:results,to:json,format:0),
                                  ResultExporter.write(engine:engine,results:results,to:csv,format:1),
                                  ResultExporter.write(engine:engine,results:results,to:paths,format:2)]
                let object = try JSONSerialization.jsonObject(with:Data(contentsOf:json)) as? [String:Any]
                let csvRows = try String(contentsOf:csv,encoding:.utf8).split(whereSeparator:\.isNewline)
                let pathRows = try String(contentsOf:paths,encoding:.utf8).split(whereSeparator:\.isNewline)
                check("export_json_csv_paths_match_result_count",counts == [3,3,3] && object?["exported"] as? Int == 3
                    && csvRows.count == 4 && pathRows.count == 3,["counts":counts,"csv_rows":csvRows.count,"paths":pathRows.count])
            } catch { check("export_json_csv_paths_match_result_count",false,error.localizedDescription) }
        } else { check("export_json_csv_paths_match_result_count",false,"search failed") }

        let beforeRows = search.cachedVisibleRowsForTesting
        search.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: search.window))
        search.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: search.window))
        check("offscreen_window_does_not_poll_status", !search.statusPollingForTesting)
        let beforeRetries = search.backgroundSearchesForTesting
        search.retryBackgroundRefreshForTesting()
        try? await Task.sleep(nanoseconds: 250_000_000)
        check("background_revision_retry_waits_for_visible_tick", search.backgroundSearchesForTesting == beforeRetries
              && search.searchSettledForTesting && search.cachedVisibleRowsForTesting == beforeRows)
        let icons = beforeRows.map { IconCache.shared.icon(for: $0) }
        check("row_icons_retain_only_small_retina_bitmaps", !icons.isEmpty && icons.allSatisfy {
            $0.size == NSSize(width: 16, height: 16) && !$0.representations.isEmpty
                && $0.representations.allSatisfy { $0.pixelsWide == 32 && $0.pixelsHigh == 32 }
        }, icons.map { $0.representations.map { [$0.pixelsWide, $0.pixelsHigh] } })
        let beforeReloads = search.resultReloadsForTesting
        let beforeSelected = search.selectedRowForTesting
        let beforeFrame = search.window!.frame
        var blank = false
        for _ in 0..<8 {
            search.refreshResultsForTesting()
            while !search.searchSettledForTesting {
                if search.cachedVisibleRowsForTesting != beforeRows { blank = true }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        check("background_refresh_never_blanks_or_reloads_unchanged_rows", !blank && !beforeRows.isEmpty
              && search.cachedVisibleRowsForTesting == beforeRows && search.resultReloadsForTesting == beforeReloads
              && search.selectedRowForTesting == beforeSelected && search.window!.frame == beforeFrame,
              ["reloads":search.resultReloadsForTesting-beforeReloads,"blank":blank])

        mark("ignore")
        let ignored = await query("secret")
        check("ignored_folder_not_indexed", ignored.isEmpty, ignored)

        mark("selection")
        _ = await query("sortcase")
        search.focusSearch(nil)
        fieldCommand(#selector(NSResponder.moveDown(_:)))  // ↓ from the field enters the list
        let entered = (search.selectedRowForTesting, search.focusForTesting)
        search.moveSelectionForTesting(by: 1)
        let down = search.selectedRowForTesting
        search.moveSelectionForTesting(by: 10)
        let clamped = search.selectedRowForTesting
        search.moveSelectionForTesting(by: -1)
        let up = search.selectedRowForTesting
        check("selection_moves", entered.0 == 0 && entered.1 == "table" && down == 1 && clamped == 2 && up == 1,
              ["enter": [entered.0, entered.1], "down": down, "clamped": clamped, "up": up])

        mark("history")
        let stored = UserDefaults.standard.stringArray(forKey: "recentSearches")
        search.focusSearch(nil)
        fieldCommand(#selector(NSResponder.insertNewline(_:)))  // ↩ in the field commits to history
        let recorded = search.historyForTesting.first
        _ = await query("alpha")
        fieldCommand(#selector(NSResponder.moveUp(_:)))  // ↑ walks to the newest recent search
        let recalled = search.queryForTesting
        _ = await settled()
        fieldCommand(#selector(NSResponder.moveDown(_:)))  // ↓ back to the draft
        let draft = search.queryForTesting
        _ = await settled()
        let storedAfter = UserDefaults.standard.stringArray(forKey: "recentSearches")
        check("history_records_in_memory", recorded == "sortcase" && recalled == "sortcase" && draft == "alpha",
              ["recorded": recorded ?? "", "recalled": recalled, "draft": draft])
        check("history_not_persisted", stored == storedAfter)

        mark("empty")
        let empty = await query("")
        let emptyStatus = search.refreshStatusForTesting()
        check("empty_query_lists_nothing", empty.isEmpty && search.resultCountForTesting == 0
              && emptyStatus.status == String(localized: "Type to search · ↓ to results · ↩ open · ⌘R reveal · Space Quick Look · ⌘Y history", table: "Search"), emptyStatus.status)
        auditLocalization("search-empty", views: search.window?.contentView.map { [$0] } ?? [], title: search.window?.title)

        mark("status")
        _ = await query("sortcase")
        let st = search.refreshStatusForTesting()
        let fileCount = Format.count(engine.status().files)
        let resultCount = Format.count(3)
        let expectedResults = String(localized: "\(resultCount) results · \(String()) ms", table: "Search").components(separatedBy: " · ").first ?? ""
        check("status_bar_counts", st.state == .ready && st.count == String(localized: "\(fileCount) files", table: "Search")
              && engine.status().files > 0 && !expectedResults.isEmpty && st.status.hasPrefix(expectedResults), ["count": st.count, "status": st.status])
        auditLocalization("search-results", views: search.window?.contentView.map { [$0] } ?? [], title: search.window?.title)
        check("rebuild_required_label", EngineState.rebuildRequired.label == "Catching up in the background",
              "state mapping only: a lost-event rebuild cannot be induced on the offline fixture")
        let filesBefore = engine.status().files
        search.rescan(nil)
        let rescanned = await waitUntil(30) { engine.status().state == .ready && engine.status().files == filesBefore }
        check("rescan_returns_ready", rescanned, ["files": engine.status().files, "before": filesBefore])

        mark("settings")
        let settings = SettingsWindowController(engine: engine, hotkey: hotkey)
        let s = settings.stateForTesting()
        check("settings_built_offscreen", settings.window?.contentView != nil && settings.window?.isVisible == false)
        settings.showSystemSettings()
        let layoutPasses = settings.layoutPassesForTesting
        for _ in 0..<5 { settings.showSystemSettings() }
        check("unchanged_settings_skip_layout", settings.layoutPassesForTesting == layoutPasses)
        check("settings_ignore_list", s.ignore.contains { $0.hasSuffix("/.hidden") } && !s.root.isEmpty,
              ["root": s.root, "ignore": s.ignore])
        check("settings_hotkey_recorder", s.recorderInWindow && !s.recorderTitle.isEmpty, s.recorderTitle)

        mark("screenshots")
        _ = await query("sortcase")
        search.moveSelectionForTesting(by: 1)
        var luminance: [String: Double] = [:]
        for (mode, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = NSAppearance(named: name)
            NSApp.appearance = appearance
            // These windows are never ordered in. In a run with the display asleep (2026-10-05 03:09) the
            // app-level change had not reached them and both captures came out light; set it on the windows too.
            search.window?.appearance = appearance
            settings.window?.appearance = appearance
            try? await Task.sleep(nanoseconds: 200_000_000)
            if localizationLanguage != nil {
                for (state, term) in [("empty", ""), ("no-results", "sift-l10n-no-such-file-73b4")] {
                    _ = await query(term)
                    _ = search.refreshStatusForTesting()
                    let url = outDir.appendingPathComponent("search-\(state)-\(mode).png")
                    try? search.writeSnapshot(to: url)
                    check("png_search_\(state)_\(mode)", Self.imageStats(url).map { $0.distinct >= 8 && $0.stddev > 0.02 } ?? false)
                    screenshots.append(url.path)
                    auditLocalization("search-\(state)-\(mode)", views: search.window?.contentView.map { [$0] } ?? [], title: search.window?.title)
                }
                _ = await query("sortcase")
                search.moveSelectionForTesting(by: 1)
                _ = search.refreshStatusForTesting()
            }
            _ = await waitUntil(5) { search.snapshotReady }
            let searchURL = outDir.appendingPathComponent("search-\(mode).png")
            let settingsURL = outDir.appendingPathComponent("settings-\(mode).png")
            try? search.writeSnapshot(to: searchURL)
            try? settings.writeSnapshot(to:settingsURL)
            auditLocalization("settings-tab0-\(mode)", views: settings.groups(), title: settings.window?.title)
            for tab in 1...4 {
                settings.selectTabForTesting(tab)
                let tabURL = outDir.appendingPathComponent("settings-tab\(tab)-\(mode).png")
                try? settings.writeSnapshot(to:tabURL)
                let stats = Self.imageStats(tabURL)
                check("png_settings_tab\(tab)_\(mode)",stats.map{$0.distinct >= 8 && $0.stddev > 0.02} ?? false)
                screenshots.append(tabURL.path)
                auditLocalization("settings-tab\(tab)-\(mode)", views: settings.groups(), title: settings.window?.title)
            }
            settings.selectTabForTesting(0)
            #if APP_STORE
            check("store_channel_and_granted_root_controls",settings.storeChannelForTesting)
            #else
            let updateURL = outDir.appendingPathComponent("settings-updates-\(mode).png")
            try? settings.writeSnapshot(to:updateURL,showUpdates:true)
            check("png_updates_\(mode)",Self.imageStats(updateURL).map{$0.width >= 1000 && $0.distinct >= 8 && $0.stddev > 0.02} ?? false)
            screenshots.append(updateURL.path)
            #endif
            for url in [searchURL, settingsURL] {
                let stats = Self.imageStats(url)
                let key = url.deletingPathExtension().lastPathComponent
                check("png_\(key)_not_blank", stats.map { $0.distinct >= 8 && $0.stddev > 0.02 } ?? false,
                      stats.map { ["mean": $0.mean, "stddev": $0.stddev, "distinct": $0.distinct, "size": [$0.width, $0.height]] } ?? "unreadable")
                luminance[key] = stats?.mean
                screenshots.append(url.path)
            }
        }
        for window in ["search", "settings"] {
            let light = luminance["\(window)-light"] ?? 0, dark = luminance["\(window)-dark"] ?? 1
            check("\(window)_dark_differs_from_light", dark + 0.2 < light, ["light": light, "dark": dark])
        }
        finishLocalization(settings: settings)

        mark("close")
        let hidesBefore = search.hideRequestsForTesting
        search.focusSearch(nil)
        let escHandled = fieldCommand(#selector(NSResponder.cancelOperation(_:)))  // Esc hides, keeps the query
        let keepsWindow = search.windowShouldClose(search.window!) == false  // red button → hide, not close
        check("esc_and_close_hide_window", escHandled && keepsWindow && search.hideRequestsForTesting == hidesBefore + 2
              && search.window?.isVisible == false && search.queryForTesting == "sortcase")
        settings.close()
        check("settings_close_not_visible", settings.window?.isVisible == false)

        finish()
    }

    private func finish() {
        mark("done")
        let map = Dictionary(checks, uniquingKeysWith: { $0 && $1 })
        let failed = checks.filter { !$0.1 }.map(\.0)
        let ok = !checks.isEmpty && failed.isEmpty
        let summary = ok
            ? "离屏真实搜索窗与设置窗 \(checks.count) 项断言全部通过（查询/排序/大小写/文件夹/选择/历史/空查询/状态/重扫/设置/关闭），明暗截图 \(screenshots.count) 张"
            : "离屏界面自检 \(failed.count)/\(checks.count) 项失败：\(failed.joined(separator: ", "))"
        Self.emit(["ok": ok, "checks": map, "screenshots": screenshots, "summary": summary, "details": details])
        Self.cleanupFixture()
        exit(ok ? 0 : 1)
    }

    // MARK: Output

    nonisolated private static func emit(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else {
            print(#"{"ok":false,"checks":{},"screenshots":[],"summary":"JSON encode failed"}"#)
            fflush(stdout)
            return
        }
        print(line)
        fflush(stdout)
    }

    nonisolated static func cleanupFixture() {
        if let base = tempFixture { try? FileManager.default.removeItem(at: base) }
    }

    /// Offscreen render of a window's content with its window background painted underneath.
    private static func render(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        out.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        image.draw(in: view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }

    private struct Stats { let mean: Double; let stddev: Double; let distinct: Int; let width: Int; let height: Int }

    /// Luminance statistics on a sampled grid: a blank or single-color image fails.
    private static func imageStats(_ url: URL) -> Stats? {
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data),
              rep.pixelsWide > 100, rep.pixelsHigh > 100 else { return nil }
        // Convert once, rather than allocating/converting an NSColor for every grid pixel.
        // Keep the same grid and premultiplied RGB statistics, including every screenshot check.
        guard let source = rep.cgImage,
              let bitmap = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh,
                                     bitsPerComponent: 8, bytesPerRow: rep.pixelsWide * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                         | CGBitmapInfo.byteOrder32Big.rawValue),
              let storage = bitmap.data else { return nil }
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        let pixels = storage.assumingMemoryBound(to: UInt8.self)
        var values: [Double] = []
        var colors = Set<UInt32>()
        let step = 3
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                let offset = y * bitmap.bytesPerRow + x * 4
                let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
                let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
                values.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
                colors.insert(UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue))
            }
        }
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return Stats(mean: (mean * 1000).rounded() / 1000, stddev: (variance.squareRoot() * 1000).rounded() / 1000,
                     distinct: colors.count, width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
