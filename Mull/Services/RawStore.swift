import Foundation

/// The immutable source zone (`_raw/<connector>/`). Pulled items are appended as
/// NDJSON — one JSON object per line — and de-duplicated by source id. This is
/// the "source code" of the second brain: never hand-edited, and what future,
/// better models re-synthesize the organized folders from (Direction v3).
enum RawStore {

    static func itemsPath(connector: String) -> String {
        "\(VaultLayout.rawRoot)/\(connector)/items.ndjson"
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

    /// Ids already stored for this connector, across the active file AND every
    /// rolled-over archive.
    ///
    /// Archives must be included or dedup silently breaks after the first
    /// rollover: an item whose id moved into an archive would look new and be
    /// re-landed on the next pull. Ids are pulled out with a substring scan
    /// rather than a full `JSONDecoder` pass, so this stays cheap as archives
    /// accumulate — decoding every archived item on every pull would not.
    static func existingIDs(connector: String) -> Set<String> {
        var ids = Set<String>()

        func collect(_ relativePath: String) {
            guard let raw = MullDirectory.read(relativePath) else { return }
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                if let id = extractID(from: line) { ids.insert(id) }
            }
        }

        collect(itemsPath(connector: connector))
        var i = 1
        while MullDirectory.exists(archivePath(connector: connector, index: i)) {
            collect(archivePath(connector: connector, index: i))
            i += 1
        }
        return ids
    }

    /// Pull `"id":"…"` out of one NDJSON line without decoding the whole object.
    /// Returns nil if the shape is unexpected, in which case the item is simply
    /// treated as unseen — the safe direction (a duplicate, never a silent drop).
    private static func extractID(from line: Substring) -> String? {
        guard let keyRange = line.range(of: "\"id\"") else { return nil }
        var rest = line[keyRange.upperBound...].drop { $0 == " " || $0 == ":" }
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
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
    ///
    /// The NSLock only covers this process; MullMCP runs as a separate one against
    /// the same vault, so the file lock below is what actually makes this safe.
    private static let writeLock = NSLock()

    /// Upper bound on items kept in the *active* file per connector. NDJSON is
    /// oldest-first, so when a file exceeds this the oldest lines roll over into
    /// a numbered archive beside it — bounding the per-pull decode/rewrite cost
    /// without deleting anything. This zone is documented as the immutable source
    /// future models re-synthesize from; silently discarding its oldest entries
    /// would make that claim false.
    private static let maxItems = 2000

    static func archivePath(connector: String, index: Int) -> String {
        "\(VaultLayout.rawRoot)/\(connector)/items.\(index).ndjson"
    }

    /// The next unused archive index for a connector.
    private static func nextArchiveIndex(connector: String) -> Int {
        var i = 1
        while MullDirectory.exists(archivePath(connector: connector, index: i)) { i += 1 }
        return i
    }

    /// Run `body` holding an exclusive advisory lock on this connector's file, so
    /// a concurrent pull in another process cannot interleave its read and write
    /// with ours.
    private static func withFileLock<T>(connector: String, _ body: () -> T) -> T {
        let lockPath = MullDirectory.url(for: itemsPath(connector: connector)).path + ".lock"
        // The connector directory may not exist yet on a first pull.
        try? FileManager.default.createDirectory(
            at: MullDirectory.url(for: itemsPath(connector: connector)).deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX) == 0 else {
            if fd >= 0 { close(fd) }
            return body()   // degraded, but a pull is better than no pull
        }
        defer { flock(fd, LOCK_UN); close(fd) }
        return body()
    }

    /// Append items not already stored. Returns the newly-added items (deduped).
    @discardableResult
    static func land(_ items: [IngestedItem], connector: String) -> [IngestedItem] {
        guard !items.isEmpty else { return [] }

        writeLock.lock()
        defer { writeLock.unlock() }

        return withFileLock(connector: connector) {
            landLocked(items, connector: connector)
        }
    }

    private static func landLocked(_ items: [IngestedItem], connector: String) -> [IngestedItem] {
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

        if allLines.count > maxItems {
            // Roll the overflow into an archive instead of dropping it. Only trim
            // the active file if the archive actually landed — losing source data
            // to save a rewrite is the one trade this zone must never make.
            let overflow = Array(allLines.prefix(allLines.count - maxItems))
            let archive = archivePath(connector: connector, index: nextArchiveIndex(connector: connector))
            if MullDirectory.write(overflow.joined(separator: "\n") + "\n", to: archive) {
                allLines = Array(allLines.suffix(maxItems))
            }
        }

        _ = MullDirectory.write(allLines.joined(separator: "\n") + "\n", to: itemsPath(connector: connector))
        return fresh
    }
}
