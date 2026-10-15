import Foundation
import ServiceManagement
import SiftCore

/// Engine states reported by the Rust core.
enum EngineState: UInt8 {
    case starting = 0, loading, scanning, updating, ready, stopped, rebuildRequired

    var label: String {
        switch self {
        case .starting: return "Starting"
        case .loading: return "Loading index"
        case .scanning: return "Indexing"
        case .updating: return "Catching up with changes"
        case .ready: return "Ready"
        case .stopped: return "Stopped"
        case .rebuildRequired: return "Index incomplete · Background repair pending"
        }
    }
}

struct EngineStatus {
    var state: EngineState
    var files: UInt64
    var events: UInt64
    var unsaved: Bool
}

enum SortKey: UInt8, CaseIterable {
    case name = 0, path, size, modified, created
}

struct FileRow: Equatable {
    let path: String
    let size: Int64
    let mtime: UInt32
    let ctime: UInt32
    let kind: UInt8   // 0 file, 1 dir, 2 symlink, 3 unknown
    let known: Bool   // metadata available

    var isDirectory: Bool { kind == 1 }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// Owns one Rust result set; freed when the last reference goes away.
final class ResultSet {
    fileprivate let raw: OpaquePointer
    let count: Int
    let highlights: [String]
    let loosened: String?
    /// Search time on the index thread (not time spent waiting for the index).
    let searchMillis: Double

    fileprivate init(raw: OpaquePointer) {
        self.raw = raw
        count = Int(sift_results_len(raw))
        searchMillis = Double(sift_results_micros(raw)) / 1000
        if let c = sift_results_loosened(raw) {
            loosened = String(cString: c)
            sift_string_free(c)
        } else { loosened = nil }
        if let c = sift_results_highlights(raw) {
            highlights = String(cString: c).split(separator: "\n").map(String.init)
            sift_string_free(c)
        } else {
            highlights = []
        }
    }

    deinit { sift_results_free(raw) }
}

enum SearchOutcome {
    case results(ResultSet)
    case cancelled
    case failed(String)
}

/// Thin Swift face of the Rust engine. All calls block until the engine thread
/// answers, so call them off the main thread.
final class Engine {
    private let raw: OpaquePointer

    init?(supportDirectory: URL) {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        guard let started = supportDirectory.path.withCString({ sift_engine_start($0) }) else { return nil }
        raw = started
        // `sift status` reports the login item live (Settings › Open Sift at login).
        sift_engine_set_login_item_probe(raw) {
            autoreleasepool { Int32(truncatingIfNeeded: LoginItem.status.rawValue) }
        }
    }

    /// `sift trash`, `sift hotkey …`, `sift login-item …` (AppActions): one JSON request in, one JSON reply out as a
    /// strdup'ed C string the core frees; called on the request's socket thread.
    func setActionHandler(_ handler: @escaping @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?) {
        sift_engine_set_action_handler(raw, handler)
    }

    func shutdown() {
        sift_engine_shutdown(raw)
    }

    func status() -> EngineStatus {
        var s = SiftStatus()
        sift_engine_status(raw, &s)
        return EngineStatus(
            state: EngineState(rawValue: s.state) ?? .starting,
            files: s.files, events: s.events, unsaved: s.dirty)
    }

    func details() -> [String: Any] {
        guard let text = sift_engine_details(raw) else { return [:] }
        defer { sift_string_free(text) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))) as? [String: Any] ?? [:]
    }
    func locate(_ results:ResultSet,paths:Set<String>) -> IndexSet {
        guard !paths.isEmpty,let data = try? JSONSerialization.data(withJSONObject:Array(paths)),
              let text = String(decoding:data,as:UTF8.self).withCString({sift_results_locate(raw,results.raw,$0)}) else { return [] }
        defer{sift_string_free(text)}
        let positions = (try? JSONSerialization.jsonObject(with:Data(String(cString:text).utf8))) as? [Int] ?? []
        return IndexSet(positions.filter{$0 >= 0 && $0 < results.count})
    }

    @discardableResult func control(_ request: [String: Any]) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let text = String(decoding: data, as: UTF8.self).withCString({ sift_engine_control(raw, $0) }) else { return ["ok": false] }
        defer { sift_string_free(text) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))) as? [String: Any] ?? ["ok": false]
    }

    func search(query: String, folder: String?, caseInsensitive: Bool, background: Bool = false) -> SearchOutcome {
        var code: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        let search = background ? sift_search_refresh : sift_search
        let result: OpaquePointer? = query.withCString { q in
            if let folder, !folder.isEmpty {
                return folder.withCString { f in
                    search(raw, q, f, caseInsensitive, &code, &error)
                }
            }
            return search(raw, q, nil, caseInsensitive, &code, &error)
        }
        switch code {
        case 0:
            guard let result else { return .failed("empty result") }
            return .results(ResultSet(raw: result))
        case 1:
            return .cancelled
        default:
            let message = error.map { String(cString: $0) } ?? "search failed"
            if let error { sift_string_free(error) }
            return .failed(message)
        }
    }

    /// Sorts in place; false when a newer search superseded it.
    func sort(_ results: ResultSet, by key: SortKey, descending: Bool) -> Bool {
        sift_results_sort(raw, results.raw, key.rawValue, descending)
    }

    func rows(_ results: ResultSet, start: Int, count: Int) -> [FileRow] {
        guard start < results.count, count > 0 else { return [] }
        let n = min(count, results.count - start)
        var buffer = [SiftRow](repeating: SiftRow(), count: n)
        let written = Int(buffer.withUnsafeMutableBufferPointer {
            sift_results_rows(raw, results.raw, UInt64(start), UInt64(n), $0.baseAddress)
        })
        var out: [FileRow] = []
        out.reserveCapacity(written)
        for i in 0..<written {
            let r = buffer[i]
            out.append(FileRow(
                path: r.path.map { String(cString: $0) } ?? "",
                size: r.size, mtime: r.mtime, ctime: r.ctime, kind: r.kind, known: r.state == 0))
        }
        buffer.withUnsafeMutableBufferPointer { sift_rows_free($0.baseAddress, UInt64(written)) }
        return out
    }

    func rescan() { sift_engine_rescan(raw) }

    func settingsJSON() -> Data? {
        guard let c = sift_config_json(raw) else { return nil }
        defer { sift_string_free(c) }
        return String(cString: c).data(using: .utf8)
    }

    /// Saves settings; the engine re-indexes when they changed.
    func updateSettings(_ json: Data) -> String? {
        var error: UnsafeMutablePointer<CChar>?
        let ok = String(decoding: json, as: UTF8.self).withCString {
            sift_config_update(raw, $0, &error)
        }
        if ok { return nil }
        let message = error.map { String(cString: $0) } ?? "could not save settings"
        if let error { sift_string_free(error) }
        return message
    }
}
