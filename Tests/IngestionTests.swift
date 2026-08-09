import XCTest
@testable import mull

private struct FakeConnector: IngestionConnector {
    let id: String
    let items: [IngestedItem]
    func pull() async throws -> [IngestedItem] { items }
}

/// Tests for Phase B ingestion: RawStore dedup + IngestionService landing/digest.
/// Each test uses a unique connector id and cleans up after itself. The vault it
/// writes into is `MullDirectory.root`, which is a throwaway temp directory under
/// XCTest — the real `~/mull` is never touched.
final class IngestionTests: XCTestCase {

    private var createdConnectors: [String] = []

    override func setUp() {
        super.setUp()
        _ = MullDirectory.setup()
    }

    override func tearDown() {
        let fm = FileManager.default
        for conn in createdConnectors {
            try? fm.removeItem(at: MullDirectory.root.appendingPathComponent("_raw/\(conn)"))
            try? fm.removeItem(at: MullDirectory.root.appendingPathComponent("09_inbox/\(conn).md"))
        }
        createdConnectors.removeAll()
        super.tearDown()
    }

    private func newConnectorID() -> String {
        let id = "test-\(UUID().uuidString)"
        createdConnectors.append(id)
        return id
    }

    private func item(_ id: String) -> IngestedItem {
        IngestedItem(id: id, timestamp: Date(), source: "test", title: "Item \(id)", summary: "s\(id)")
    }

    func testRawStoreLandsAndDeduplicates() {
        let conn = newConnectorID()
        let added = RawStore.land([item("1"), item("2")], connector: conn)
        XCTAssertEqual(added.count, 2)

        // Re-landing one existing + one new → only the new lands.
        let added2 = RawStore.land([item("2"), item("3")], connector: conn)
        XCTAssertEqual(added2.map(\.id), ["3"])

        XCTAssertEqual(RawStore.load(connector: conn).count, 3)
        XCTAssertEqual(RawStore.existingIDs(connector: conn), ["1", "2", "3"])
    }

    func testIngestionServiceRunsLandsAndWritesDigest() async {
        let conn = newConnectorID()
        let service = IngestionService(connectors: [FakeConnector(id: conn, items: [item("a"), item("b")])])

        let outcomes = await service.runOnce()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.pulled, 2)
        XCTAssertEqual(outcomes.first?.new, 2)
        XCTAssertNil(outcomes.first?.error)

        // Raw landed.
        XCTAssertEqual(RawStore.load(connector: conn).count, 2)
        // Inbox digest written and mentions an item.
        let digest = MullDirectory.read("09_inbox/\(conn).md")
        XCTAssertNotNil(digest)
        XCTAssertTrue(digest?.contains("Item a") ?? false)
    }

    func testFailingConnectorIsIsolated() async {
        struct Boom: IngestionConnector {
            let id = "boom"
            func pull() async throws -> [IngestedItem] { throw NSError(domain: "x", code: 1) }
        }
        let service = IngestionService(connectors: [Boom()])
        let outcomes = await service.runOnce()
        XCTAssertEqual(outcomes.first?.new, 0)
        XCTAssertNotNil(outcomes.first?.error)
    }
}
