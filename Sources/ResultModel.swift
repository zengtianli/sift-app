import Foundation

/// The current result set plus a small page cache of materialized rows.
///
/// Rows are fetched lazily in pages as the table scrolls, so a result with
/// millions of hits costs only the index array in Rust plus the visible pages.
final class ResultModel {
    static let pageSize = 64
    private static let maxPages = 48

    private let engine: Engine
    private(set) var results: ResultSet?
    private var pages: [Int: [FileRow]] = [:]
    private var recent: [Int] = []
    private var inFlight: Set<Int> = []

    /// Called on the main thread with the row range that just arrived.
    var onRowsLoaded: ((Range<Int>) -> Void)?
    var onResultsInvalidated: (() -> Void)?

    init(engine: Engine) {
        self.engine = engine
    }

    var count: Int { results?.count ?? 0 }
    var highlights: [String] { results?.highlights ?? [] }
    func cachedPaths(_ indexes:IndexSet) -> Set<String> {
        var paths = Set<String>()
        for (page,rows) in pages { for (offset,row) in rows.enumerated() where indexes.contains(page * Self.pageSize + offset) { paths.insert(row.path) } }
        return paths
    }
    func cachedRows(in range: Range<Int>) -> [FileRow] {
        range.compactMap { index in
            guard index < count, let rows = pages[index / Self.pageSize], index % Self.pageSize < rows.count else { return nil }
            return rows[index % Self.pageSize]
        }
    }

    func matches(_ results: ResultSet?, pages prepared: [Int: [FileRow]]) -> Bool {
        count == (results?.count ?? 0) && highlights == (results?.highlights ?? [])
            && prepared.allSatisfy { pages[$0.key] == $0.value }
    }

    /// Prepare the visible pages before swapping the result set, so repainting never exposes an empty cache.
    static func prepare(_ results: ResultSet, engine: Engine, visible: Range<Int>) -> [Int: [FileRow]]? {
        guard results.count > 0 else { return [:] }
        let lower = min(max(0, visible.lowerBound), results.count - 1)
        let upper = min(max(lower + 1, visible.upperBound), results.count)
        var prepared: [Int: [FileRow]] = [:]
        for page in (lower / pageSize)...((upper - 1) / pageSize) {
            let start = page * pageSize
            let rows = engine.rows(results, start: start, count: pageSize)
            guard rows.count == min(pageSize, results.count - start) else { return nil }
            prepared[page] = rows
        }
        return prepared
    }

    func replace(with results: ResultSet?, prepared: [Int: [FileRow]] = [:]) {
        self.results = results
        pages = prepared
        recent = prepared.keys.sorted()
        inFlight.removeAll()
    }

    /// Returns the row if its page is loaded; otherwise schedules the page and
    /// returns nil (the table shows a placeholder until `onRowsLoaded`).
    func row(at index: Int) -> FileRow? {
        guard index >= 0 && index < count else { return nil }
        let page = index / Self.pageSize
        if let rows = pages[page] {
            touch(page)
            let offset = index - page * Self.pageSize
            return offset < rows.count ? rows[offset] : nil
        }
        load(page: page)
        return nil
    }

    /// Synchronous fetch for actions (open, reveal, copy) on selected rows.
    func rowsNow(_ indexes: IndexSet) -> [FileRow] {
        guard let results else { return [] }
        return indexes.compactMap { index in
            if let row = row(at: index) { return row }
            return engine.rows(results, start: index, count: 1).first
        }
    }

    private func load(page: Int) {
        guard let results, !inFlight.contains(page) else { return }
        inFlight.insert(page)
        let start = page * Self.pageSize
        DispatchQueue.global(qos: .userInitiated).async { [engine, weak self] in
            let rows = engine.rows(results, start: start, count: Self.pageSize)
            DispatchQueue.main.async {
                guard let self, self.results === results else { return }
                guard rows.count == min(Self.pageSize, results.count - start) else {
                    // Keep the request marked in flight until replacement: repeated drawing must not spin on stale rows.
                    self.onResultsInvalidated?()
                    return
                }
                self.inFlight.remove(page)
                self.pages[page] = rows
                self.touch(page)
                self.evict()
                self.onRowsLoaded?(start..<(start + rows.count))
            }
        }
    }

    private func touch(_ page: Int) {
        if let i = recent.firstIndex(of: page) { recent.remove(at: i) }
        recent.append(page)
    }

    private func evict() {
        while recent.count > Self.maxPages {
            pages.removeValue(forKey: recent.removeFirst())
        }
    }
}
