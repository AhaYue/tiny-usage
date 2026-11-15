import Foundation

/// Cache a bounded shortlist rather than walking years of sessions every background tick.
final class SessionFileIndex: @unchecked Sendable {
    static let shared = SessionFileIndex()
    private let lock = NSLock()
    private var cache: [String: (date: Date, files: [URL])] = [:]
    func files(in directory: URL, now: Date = Date()) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        if let saved = cache[directory.path], now.timeIntervalSince(saved.date) < 300,
           saved.files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return saved.files }
        var newest: [(URL, Date)] = []
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                newest.append((file, modified))
                newest.sort { $0.1 > $1.1 }
                if newest.count > 8 { newest.removeLast() }
            }
        }
        if cache.count >= 32 { cache = cache.filter { now.timeIntervalSince($0.value.date) < 300 } }
        let files = newest.map(\.0)
        cache[directory.path] = (now, files)
        return files
    }
}
