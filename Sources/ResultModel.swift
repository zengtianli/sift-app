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

    init(engine: Engine) {
        self.engine = engine
    }

    var count: Int { results?.count ?? 0 }
    var highlights: [String] { results?.highlights ?? [] }

    func replace(with results: ResultSet?) {
        self.results = results
        pages.removeAll(keepingCapacity: true)
        recent.removeAll(keepingCapacity: true)
        inFlight.removeAll()
    }

    /// Returns the row if its page is loaded; otherwise schedules the page and
    /// returns nil (the table shows a placeholder until `onRowsLoaded`).
    func row(at index: Int) -> FileRow? {
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
