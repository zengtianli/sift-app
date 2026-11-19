import AppKit

/// Existing local copy overrides, with standard String Catalogs as the bundled defaults.
/// Legacy flat ui.json values remain Chinese; bilingual payloads use copy.en / copy.zh-Hans.
enum SiftText {
    static let language = Bundle.preferredLocalizations(from: ["en", "zh-Hans"]).first ?? "en"
    private static let titles: [String: String] = [
        "About Sift":"menu.about", "Settings…":"menu.settings", "Hide Sift":"menu.hide",
        "Hide Others":"menu.hide.others", "Show All":"menu.show.all", "Quit Sift":"menu.quit",
        "File":"menu.file", "Edit":"menu.edit", "Search":"menu.search", "Window":"menu.window",
        "Open":"menu.open", "Show in Finder":"menu.reveal", "Quick Look":"menu.preview", "Move to Trash":"menu.trash",
        "Undo":"menu.undo", "Redo":"menu.redo", "Cut":"menu.cut", "Copy":"menu.copy", "Paste":"menu.paste", "Select All":"menu.select.all",
        "Copy Path":"menu.copy.path", "Copy Name":"menu.copy.name", "Find":"menu.find", "Focus Search Field":"menu.focus",
        "Recent Searches":"menu.history", "Limit to Folders":"menu.scope", "Match Case":"menu.case",
        "Sort by Name":"menu.sort.name", "Sort by Folder":"menu.sort.folder", "Sort by Size":"menu.sort.size",
        "Sort by Date Modified":"menu.sort.modified", "Sort by Date Created":"menu.sort.created", "Re-index Everything":"menu.reindex",
        "Search Window":"menu.show", "Minimize":"menu.minimize", "Choose Folder to Index…":"index.choose", "Grant Full Disk Access…":"index.access",
        "Search file names":"search.placeholder", "In folders matching…":"search.folder", "Name":"column.name", "Folder":"column.folder",
        "Size":"column.size", "Modified":"column.modified", "Created":"column.created", "No recent searches":"history.empty", "Clear Recent Searches":"history.clear"
    ]
    private static let copy: [String: String] = {
        func read(_ url: URL?) -> [String: String] {
            guard let url, let data = try? Data(contentsOf: url), data.count <= 65536,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let copy = object["copy"] as? [String: Any] else { return [:] }
            let values: [String: String]
            if let legacy = copy as? [String: String] { values = legacy }
            else {
                var result = copy[language == "en" ? "zh-Hans" : "en"] as? [String: String] ?? [:]
                for (key, value) in copy[language] as? [String: String] ?? [:] { result[key] = value }
                values = result
            }
            guard values.count <= 256, values.values.allSatisfy({ !$0.isEmpty && $0.count <= 2048 }) else { return [:] }
            return values
        }
        var values = read(Bundle.main.url(forResource: "UI.zh-Hans", withExtension: "json"))
        if language == "en" {
            for (key, value) in read(Bundle.main.url(forResource: "UI.en", withExtension: "json")) { values[key] = value }
        }
        let external = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIFT_SUPPORT_DIR"]
            ?? (NSHomeDirectory() + "/Library/Application Support/cyou.tianli.sift")).appendingPathComponent("ui.json")
        for (key, value) in read(external) { values[key] = value }
        return values
    }()
    static func title(_ original: String) -> String {
        if let key = titles[original], let value = copy[key] { return value }
        let localized = String(localized: String.LocalizationValue(original))
        guard localized == original else { return localized }
        // Engine/CLI errors retain their bytes. Translate fixed clauses only at the GUI boundary.
        for separator in ["：", "；"] {
            if let range = original.range(of: separator) {
                let head = String(original[..<range.lowerBound]), tail = String(original[range.upperBound...])
                let translated = title(head)
                if translated != head {
                    return translated + (language == "en" ? (separator == "：" ? ": " : "; ") : separator) + title(tail)
                }
            }
        }
        return original
    }
    static func value(_ key: String, fallback: String) -> String {
        if let value = copy[key] { return value }
        let localized = String(localized: String.LocalizationValue(key))
        return localized == key ? title(fallback) : localized
    }
    static func error(_ error: Error) -> Error {
        let source = error as NSError
        var info = source.userInfo
        for key in [NSLocalizedDescriptionKey, NSLocalizedFailureReasonErrorKey, NSLocalizedRecoverySuggestionErrorKey] {
            if let text = info[key] as? String { info[key] = title(text) }
        }
        return NSError(domain: source.domain, code: source.code, userInfo: info)
    }
    static func menu(_ menu: NSMenu) {
        menu.title = title(menu.title)
        for item in menu.items { item.title = title(item.title); if let submenu = item.submenu { self.menu(submenu) } }
    }
}
