import Foundation

/// The immutable source zone (`_raw/<connector>/`). Pulled items are appended as
/// NDJSON — one JSON object per line — and de-duplicated by source id. This is
/// the "source code" of the second brain: never hand-edited, and what future,
/// better models re-synthesize the organized folders from (Direction v3).
enum RawStore {

    static func itemsPath(connector: String) -> String {
        "\(FolderOntology.rawRoot)/\(connector)/items.ndjson"
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Ids already stored for this connector (for dedup).
    static func existingIDs(connector: String) -> Set<String> {
        Set(load(connector: connector).map(\.id))
    }

    /// All stored items for a connector, oldest-first as written.
    static func load(connector: String) -> [IngestedItem] {
        guard let raw = MullDirectory.read(itemsPath(connector: connector)) else { return [] }
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? decoder.decode(IngestedItem.self, from: Data(line.utf8))
            }
    }

    /// Serializes the read-modify-write below. Without it, two overlapping pulls
    /// of the same connector both read the old file and the second write clobbers
    /// the first — silently dropping items from the immutable source zone.
    private static let writeLock = NSLock()

    /// Upper bound on items kept per connector. NDJSON is oldest-first, so when a
    /// file exceeds this the oldest lines are dropped — bounding both file growth
    /// and the per-pull decode/rewrite cost (which was O(n) and unbounded).
    private static let maxItems = 2000

    /// Append items not already stored. Returns the newly-added items (deduped).
    @discardableResult
    static func land(_ items: [IngestedItem], connector: String) -> [IngestedItem] {
        guard !items.isEmpty else { return [] }

        writeLock.lock()
        defer { writeLock.unlock() }

        let seen = existingIDs(connector: connector)
        // Build fresh items and their encoded lines together, so an item that
        // fails to encode is neither written NOR reported as landed.
        var fresh: [IngestedItem] = []
        var newLines: [String] = []
        var added = Set<String>()
        for item in items where !seen.contains(item.id) && !added.contains(item.id) {
            guard let data = try? encoder.encode(item),
                  let line = String(data: data, encoding: .utf8) else { continue }
            added.insert(item.id)
            fresh.append(item)
            newLines.append(line)
        }
        guard !newLines.isEmpty else { return [] }

        let existing = MullDirectory.read(itemsPath(connector: connector)) ?? ""
        var allLines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        allLines.append(contentsOf: newLines)
        if allLines.count > maxItems { allLines = Array(allLines.suffix(maxItems)) }

        _ = MullDirectory.write(allLines.joined(separator: "\n") + "\n", to: itemsPath(connector: connector))
        return fresh
    }
}
