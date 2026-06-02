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

    /// Append items not already stored. Returns the newly-added items (deduped).
    @discardableResult
    static func land(_ items: [IngestedItem], connector: String) -> [IngestedItem] {
        guard !items.isEmpty else { return [] }

        var seen = existingIDs(connector: connector)
        var fresh: [IngestedItem] = []
        for item in items where !seen.contains(item.id) {
            seen.insert(item.id)
            fresh.append(item)
        }
        guard !fresh.isEmpty else { return [] }

        let newLines = fresh.compactMap { item -> String? in
            guard let data = try? encoder.encode(item) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        let existing = MullDirectory.read(itemsPath(connector: connector)) ?? ""
        var combined = existing
        if !combined.isEmpty && !combined.hasSuffix("\n") { combined += "\n" }
        combined += newLines.joined(separator: "\n") + "\n"

        _ = MullDirectory.write(combined, to: itemsPath(connector: connector))
        return fresh
    }
}
