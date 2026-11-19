import AppKit

enum SiftDiagnostics {
    static func summary(_ d: [String:Any]) -> String {
        let count = (d["files"] as? NSNumber)?.stringValue ?? "0"
        let error = d["configuration_error"] as? String ?? ""
        if !error.isEmpty { return String(localized: "Repair your settings. The last valid scope, or an empty scope, has been kept.") }
        if let problem = d["runtime_error"] as? String,!problem.isEmpty { return SiftText.title(problem) }
        if d["paused"] as? Bool == true { return String(localized: "Indexing paused · \(count) items. Search uses the existing index; resume to catch up with changes.") }
        if d["rebuild_required"] as? Bool == true {
            // The FSEvents details stay in `sift status` and exported diagnostics; the
            // window says only what the user sees and whether anything is needed of them.
            if d["auto_repair"] as? Bool == false { return String(localized: "Some file changes were missed. Automatic repair is off; press ⇧⌘R to rebuild the index.") }
            if d["repairing"] as? Bool == true { return String(localized: "Catching up on missed file changes in the background · search keeps working") }
            if d["repair_failed"] as? Bool == true { return String(localized: "Background catch-up did not finish and will retry. Press ⇧⌘R to rebuild now.") }
            return String(localized: "Some file changes were missed; catching up in the background shortly · search keeps working")
        }
        if d["repairing"] as? Bool == true { return String(localized: "Repairing in the background · \(count) items. Search continues using the existing index.") }
        let labels = ["starting":"Starting","loading":"Loading index","scanning":"Indexing","updating":"Catching up with changes","ready":"Ready","stopped":"Stopped"]
        let state = SiftText.title(labels[d["state"] as? String ?? ""] ?? "Unknown status")
        let walks = String(describing: d["walks"] ?? 0)
        return String(localized: "\(state) · \(count) items · \(walks) scans")
    }
    /// Orange only when something is asked of the user: indexing paused, automatic
    /// repair turned off, or a background repair that failed. A loss that Sift is
    /// already repairing by itself stays in the ordinary secondary colour.
    static func needsAttention(_ d: [String:Any]) -> Bool {
        d["paused"] as? Bool == true
            || (d["rebuild_required"] as? Bool == true && (d["auto_repair"] as? Bool == false || d["repair_failed"] as? Bool == true))
    }
    static func redacted(_ d:[String:Any]) -> [String:Any] {
        var value = d
        for key in ["root","support_dir","ignore_paths","include_paths"] { value.removeValue(forKey:key) }
        if let problem = value["configuration_error"] as? String, !problem.isEmpty { value["configuration_error"] = String(localized: "Settings could not be read (paths omitted). See Settings for the original error.") }
        value["diagnostic_scope"] = String(localized: "Search history, file contents, result paths, and index scope are excluded.")
        return value
    }
    static func export(engine:Engine,window:NSWindow?) {
        guard !Prefs.dryRun("export diagnostics",[]),let window else { return }
        let panel = NSSavePanel();panel.nameFieldStringValue = "Sift-diagnostics.json"
        panel.beginSheetModal(for:window) { response in
            guard response == .OK,let url = panel.url else { return }
            do { let data = try JSONSerialization.data(withJSONObject:redacted(engine.details()),options:[.prettyPrinted,.sortedKeys]);try data.write(to:url,options:.atomic) }
            catch { NSApp.presentError(SiftText.error(error)) }
        }
    }
    static func feedback(engine:Engine,window:NSWindow?) {
        guard !Prefs.dryRun("feedback",[]),let window else { return }
        let alert = NSAlert();alert.messageText = String(localized: "Report a Problem");alert.informativeText = String(localized: "Describe what you did, what you expected, and what happened. Save your note and redacted diagnostics to share with the maintainer. Nothing is sent automatically.")
        let input = NSTextField(frame:NSRect(x:0,y:0,width:380,height:80));input.placeholderString = String(localized: "For example: your query, the key you pressed, and what happened…");alert.accessoryView = input
        alert.addButton(withTitle:String(localized: "Save Report…"));alert.addButton(withTitle:String(localized: "Cancel"))
        alert.beginSheetModal(for:window) { result in
            guard result == .alertFirstButtonReturn else { return }
            let note = input.stringValue
            let panel = NSSavePanel();panel.nameFieldStringValue = "Sift-feedback.json"
            panel.beginSheetModal(for:window) { result in
                guard result == .OK,let url = panel.url else { return }
                do { let data = try JSONSerialization.data(withJSONObject:["description":note,"diagnostics":redacted(engine.details())],options:[.prettyPrinted,.sortedKeys]);try data.write(to:url,options:.atomic) }
                catch { NSApp.presentError(SiftText.error(error)) }
            }
        }
    }
}
