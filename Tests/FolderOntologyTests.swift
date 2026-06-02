import XCTest
@testable import mull

/// Tests for the v3 folder ontology schema (pure data — no disk writes, so the
/// real ~/mull is never touched).
final class FolderOntologyTests: XCTestCase {

    func testFolderPathsAreNumbered() {
        XCTAssertEqual(FolderOntology.folder("00")?.path, "00_identity")
        XCTAssertEqual(FolderOntology.folder("03")?.path, "03_projects")
        XCTAssertEqual(FolderOntology.folder("09")?.indexPath, "09_inbox/index.md")
    }

    func testNumbersAreUnique() {
        let numbers = FolderOntology.folders.map(\.number)
        XCTAssertEqual(numbers.count, Set(numbers).count)
    }

    func testSectionBlockIdsAreUniqueWithinFolder() {
        for folder in FolderOntology.folders {
            let ids = folder.sections.map { "section:\(ContextBlockFile.slug($0))" }
            XCTAssertEqual(ids.count, Set(ids).count, "duplicate section id in \(folder.path)")
        }
    }

    func testCanonicalFilesMapToRootContract() {
        XCTAssertEqual(FolderOntology.folder("00")?.canonical, "me.md")
        XCTAssertEqual(FolderOntology.folder("01")?.canonical, "now.md")
        XCTAssertEqual(FolderOntology.folder("06")?.canonical, "MEMORY.md")
        // Non-mirrored folders have no canonical root file.
        XCTAssertNil(FolderOntology.folder("04")?.canonical)
    }

    func testConnectorRoutingResolvesToRealFolders() {
        for connector in FolderOntology.rawConnectors {
            if let dest = FolderOntology.primaryDestination(forConnector: connector) {
                XCTAssertTrue(FolderOntology.folders.contains { $0.number == dest.number },
                              "\(connector) routes to a non-existent folder")
            }
        }
        XCTAssertEqual(FolderOntology.primaryDestination(forConnector: "github")?.number, "03")
    }
}
