import AppKit
import SiftCore
import UniformTypeIdentifiers

enum Format {
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func size(_ row: FileRow) -> String {
        if row.isDirectory { return "—" }
        return row.known && row.size >= 0 ? sizeFormatter.string(fromByteCount: row.size) : ""
    }

    static func date(_ seconds: UInt32) -> String {
        seconds == 0 ? "" : dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func count(_ n: Int) -> String {
        countFormatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func count(_ n: UInt64) -> String { count(Int(n)) }
}

/// Small icon cache: one icon per file type, per-path only for bundles
/// (apps, packages) whose icon is their own.
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private let folder: NSImage
    private let generic: NSImage

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 2 * 1024 * 1024
        folder = Self.smallIcon(NSWorkspace.shared.icon(for: .folder))
        generic = Self.smallIcon(NSWorkspace.shared.icon(for: .data))
    }

    /// Rows show 16-point icons. Retaining the system image also retains its
    /// large representations; store only a concrete 32-pixel Retina bitmap.
    private static func smallIcon(_ source: NSImage) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero,
                    operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = image.size
        image.addRepresentation(bitmap)
        return image
    }

    func icon(for row: FileRow) -> NSImage {
        let ext = (row.path as NSString).pathExtension.lowercased()
        if row.isDirectory && ext.isEmpty { return folder }
        let perPath = row.isDirectory || ext == "app"
        let key = (perPath ? row.path : "ext:" + ext) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: NSImage = autoreleasepool {
            if perPath {
                return Self.smallIcon(NSWorkspace.shared.icon(forFile: row.path))
            } else if let type = UTType(filenameExtension: ext) {
                return Self.smallIcon(NSWorkspace.shared.icon(for: type))
            }
            return generic
        }
        cache.setObject(image, forKey: key, cost: 32 * 32 * 4)
        return image
    }
}

/// Preference writes go through here so verification runs (`--snapshot`,
/// `--ui-self-test`, `--headless`, `-lane_quiet YES`) never touch the user's saved settings.
enum Prefs {
    /// `-lane_quiet YES` (shared LaneSignal contract): the hidden cold-launch measurement of a copy of the app.
    /// It runs like a snapshot on its own temp index: no Dock icon, no window on screen, no hotkey, no writes.
    static let laneQuiet = LaneSignal.quiet
    static let readOnly = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--ui-self-test")
        || laneQuiet
    /// `--headless`: a real indexing instance for acceptance scripts (own SIFT_SUPPORT_DIR):
    /// no Dock icon, window or global hotkey, and no writes to the user's preferences.
    static let headless = CommandLine.arguments.contains("--headless")
    /// `--lifecycle-self-test`: this process as the running app for the real `sift config …` commands, on a throwaway
    /// copy of the bundle with its own index, folders and preference domain (LifecycleSelfTest). It writes there, so
    /// it is neither read-only nor headless; nothing of it reaches the screen, the Dock or a system-wide key.
    #if APP_STORE
    /// The Mac App Store build has no `sift` CLI for that self-test to drive (LifecycleSelfTest.swift is not in it).
    static let lifecycleSelfTest = false
    #else
    static let lifecycleSelfTest = CommandLine.arguments.contains(Lifecycle.selfTestFlag)
    #endif

    /// In verification runs, file actions (open, reveal, trash, pasteboard) are
    /// only logged so they can never reach other apps or the user's screen.
    static func dryRun(_ action: String, _ paths: [String]) -> Bool {
        guard readOnly || lifecycleSelfTest else { return false }
        fputs("dry-run \(action): \(paths.joined(separator: ", "))\n", stderr)
        return true
    }

    /// Run after this app stored one of its own preferences (key, new value or nil) and after Settings › Save &
    /// Re-index, so the lifecycle wiring can tell the app's own values from what a `sift config …` command or
    /// another Mac brought in (AppDelegate.installLifecycle).
    static var didWrite: ((String, Any?) -> Void)?
    static var didSaveIndexSettings: (() -> Void)?

    static func set(_ value: Any?, forKey key: String) {
        guard !readOnly, !headless else { return }
        UserDefaults.standard.set(value, forKey: key)
        UserDefaults.standard.synchronize()
        didWrite?(key, value)
    }

    static func remove(_ key: String) {
        guard !readOnly, !headless else { return }
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.synchronize()
        didWrite?(key, nil)
    }
}

/// Recent searches, newest first, de-duplicated.
final class SearchHistory {
    private static let key = "recentSearches"
    private static let limit = 50

    private(set) var items: [String]

    init() {
        items = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func record(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        items.removeAll { $0 == q }
        items.insert(q, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        Prefs.set(items, forKey: Self.key)
    }

    func clear() {
        items = []
        Prefs.remove(Self.key)
    }
}

// The Mac App Store build asks for a folder instead (IndexAccess, StoreAccess.swift): Full Disk Access does not
// lift the App Sandbox.
#if !APP_STORE
enum Permissions {
    /// Full Disk Access is required to index Mail, Messages, Safari data and
    /// other protected folders. Probed by reading a TCC-protected file, in the
    /// Rust core so `sift status` reports the same answer (TCC judges this process).
    static var hasFullDiskAccess: Bool { sift_full_disk_access() }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
