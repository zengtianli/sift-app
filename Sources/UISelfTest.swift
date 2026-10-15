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
        search.prepareOffscreen(size: NSSize(width: 1000, height: 600))
        if !search.caseInsensitiveForTesting { search.toggleCase(nil) }
        NSApp.appearance = NSAppearance(named: .aqua)
        search.window?.appearance = NSApp.appearance
        search.setQuery("")
        let frames = outDir.appendingPathComponent("frames")
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let fps = 12, count = 216
        var events: [[String: Any]] = []
        var facts: [[String: Any]] = []
        let started = ProcessInfo.processInfo.systemUptime
        let field = search.searchFieldForTesting
        let rect = field.convert(field.bounds, to: search.window!.contentView!)
        let fieldBox: [Double] = [Double(rect.minX), Double(600 - rect.maxY), Double(rect.width), Double(rect.height)]
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
            "point_size": [1000, 600], "activation_policy": "prohibited", "visible": false,
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

    // MARK: Run

    private func run() async {
        mark("index")
        let ready = await waitUntil(40) { engine.status().state == .ready }
        let status = engine.status()
        check("index_ready", ready && status.files > 0, ["state": status.state.label, "files": status.files])

        mark("window")
        search.prepareOffscreen(size: NSSize(width: 1000, height: 600))
        check("search_window_built_offscreen", search.window?.contentView != nil && search.window?.isVisible == false)
        // Normalize the user's saved toggles (read-only here; nothing is written back).
        if !search.caseInsensitiveForTesting { search.toggleCase(nil) }
        if search.folderVisibleForTesting { search.toggleFolderScope(nil) }

        mark("query")
        let readme = await query("readme")
        check("query_rows", readme.count >= 2 && Set(readme).isSuperset(of: ["README.md", "readme-notes.txt"]), readme)
        let expanded = await query("nested notes")
        let expandedStatus = search.refreshStatusForTesting().status
        check("loosened_query_status", expanded == ["readme-notes.txt"] && expandedStatus.contains("Expanded folder query: (nested|*nested*/**) (notes|*notes*/**)"), expandedStatus)
        _ = await query("readme")
        check("strict_query_clears_loosened_status", !search.refreshStatusForTesting().status.contains("Expanded folder query:"))
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

        let beforeRows = search.cachedVisibleRowsForTesting
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
              && emptyStatus.status.hasPrefix("Type to search"), emptyStatus.status)

        mark("status")
        _ = await query("sortcase")
        let st = search.refreshStatusForTesting()
        check("status_bar_counts", st.state == .ready && st.count.hasSuffix(" files") && st.count != "0 files"
              && st.status.hasPrefix("3 results"), ["count": st.count, "status": st.status])
        check("rebuild_required_label", EngineState.rebuildRequired.label.hasPrefix("Index incomplete"),
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
            _ = await waitUntil(5) { search.snapshotReady }
            let searchURL = outDir.appendingPathComponent("search-\(mode).png")
            let settingsURL = outDir.appendingPathComponent("settings-\(mode).png")
            try? search.writeSnapshot(to: searchURL)
            try? settings.writeSnapshot(to:settingsURL)
            for tab in 1...4 {
                settings.selectTabForTesting(tab)
                let tabURL = outDir.appendingPathComponent("settings-tab\(tab)-\(mode).png")
                try? settings.writeSnapshot(to:tabURL)
                let stats = Self.imageStats(tabURL)
                check("png_settings_tab\(tab)_\(mode)",stats.map{$0.distinct >= 8 && $0.stddev > 0.02} ?? false)
                screenshots.append(tabURL.path)
            }
            settings.selectTabForTesting(0)
            let updateURL = outDir.appendingPathComponent("settings-updates-\(mode).png")
            try? settings.writeSnapshot(to:updateURL,showUpdates:true)
            check("png_updates_\(mode)",Self.imageStats(updateURL).map{$0.width >= 1000 && $0.distinct >= 8 && $0.stddev > 0.02} ?? false)
            screenshots.append(updateURL.path)
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
        var values: [Double] = []
        var colors = Set<UInt32>()
        let step = 3
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let a = c.alphaComponent
                let r = c.redComponent * a, g = c.greenComponent * a, b = c.blueComponent * a
                values.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
                colors.insert(UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(b * 255))
            }
        }
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return Stats(mean: (mean * 1000).rounded() / 1000, stddev: (variance.squareRoot() * 1000).rounded() / 1000,
                     distinct: colors.count, width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
