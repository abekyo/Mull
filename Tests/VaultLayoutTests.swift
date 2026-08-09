import XCTest
@testable import mull

/// The one-way move off the numbered folders (DIRECTION §6.1).
///
/// This is the part of the retirement that touches files a person owns, so it gets
/// the tests. The rule it has to keep is the one in the Invariant Contract 契約2:
/// mull may delete its own scaffold, and may not delete a line the user wrote —
/// and since 2026-08-09 the folder indexes were editable in the Files tab, so
/// "the user wrote in one" is a real case, not a hypothetical.
///
/// `MullDirectory.root` already redirects to a throwaway directory under XCTest
/// (`isRunningTests`), so these run against that rather than the user's vault. The
/// root is shared for the whole process, so each test clears the paths it uses.
final class VaultLayoutTests: XCTestCase {

    private var root: URL { MullDirectory.root }

    /// Everything these tests create. Cleared before AND after: the root outlives a
    /// single test, so a leftover from one would silently become another's input.
    private static let scratch = [
        "00_identity", "02_work", "03_projects", "04_career", "05_people",
        "06_knowledge", "09_inbox", "projects", "corrections", "inbox.md",
        "notes/02_work.md", "notes/04_career.md", "notes/05_people.md",
        "notes/02_work", "notes/03_projects", "notes/04_career",
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = MullDirectory.setup()
        clean()
    }

    override func tearDownWithError() throws {
        clean()
        try super.tearDownWithError()
    }

    private func clean() {
        for path in Self.scratch {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
        }
    }

    // MARK: - The structural rule

    func testNumberedFolderIsMatchedByShapeNotByAList() {
        for name in ["00_identity", "09_inbox", "42_whatever"] {
            XCTAssertTrue(VaultLayout.isNumberedFolder(name), name)
        }
        for name in ["notes", "projects", "corrections", "_raw", "daily", "2026", "0_x", "00x"] {
            XCTAssertFalse(VaultLayout.isNumberedFolder(name), name)
        }
    }

    // MARK: - Destinations

    /// The three destinations are the ones with a writer behind them. A destination
    /// with no writer is exactly what the numbered scheme accumulated eight of.
    func testDestinationsAreFlatAndUnnumbered() {
        for path in [VaultLayout.projects, VaultLayout.corrections, VaultLayout.inboxFile] {
            XCTAssertFalse(path.contains("/"), "\(path) is not flat")
            XCTAssertFalse(VaultLayout.isNumberedFolder(path), "\(path) is still numbered")
        }
        // The ledger and the cards go to the same place, from two different files.
        XCTAssertEqual(CorrectionIndex.directory, VaultLayout.corrections)
        XCTAssertTrue(CorrectionIndex.ledgerPath.hasPrefix(VaultLayout.corrections + "/"))
        XCTAssertEqual(QuickCapture.relativePath, VaultLayout.inboxFile)
    }

    // MARK: - Migration

    func testProjectBriefingsMoveOutOfTheNumberedFolder() throws {
        write("03_projects/atr.md", "# ATR\n")
        write("03_projects/index.md", scaffold("03 Projects"))

        migrate()

        XCTAssertEqual(read("projects/atr.md"), "# ATR\n")
        XCTAssertFalse(exists("03_projects"), "the emptied folder should be gone")
        // `03_projects` moves wholesale, so a scaffold index left in it at that
        // moment rides along — putting the empty file back under a better name.
        XCTAssertFalse(exists("projects/index.md"), "the scaffold followed the briefings across")
    }

    func testCorrectionLedgerIsPromotedToTheRoot() throws {
        write("06_knowledge/corrections/ledger.md", "| a | b |\n")
        write("06_knowledge/corrections/2026-08-09-x.md", "card\n")
        write("06_knowledge/index.md", scaffold("06 Knowledge"))

        migrate()

        XCTAssertEqual(read("corrections/ledger.md"), "| a | b |\n")
        XCTAssertEqual(read("corrections/2026-08-09-x.md"), "card\n")
        XCTAssertFalse(exists("06_knowledge"))
    }

    func testQuickCaptureBecomesOneFile() throws {
        write("09_inbox/captures.md", "- a thought\n")
        write("09_inbox/index.md", scaffold("09 Inbox"))

        migrate()

        XCTAssertEqual(read("inbox.md"), "- a thought\n")
        XCTAssertFalse(exists("09_inbox"))
    }

    /// 契約2. The index was editable, so this is text a person typed into a file
    /// whose own front matter told them to ("No automatic source — just write here").
    /// Deleting the folder must not delete it.
    func testProseTheUserWroteInAnIndexSurvivesAsANote() throws {
        write("02_work/index.md", scaffold("02 Work") + "\n- Runs three businesses; FX is the priority.\n")

        migrate()

        let rescued = read("notes/02_work.md")
        XCTAssertNotNil(rescued, "the user's line was deleted with the folder")
        XCTAssertTrue(rescued?.contains("Runs three businesses") ?? false, rescued ?? "nil")
        XCTAssertFalse(exists("02_work"))
    }

    /// A block the user edited is promoted to `src=human` by `Curator.merge`, and a
    /// file holding one is not mull's to delete. It is still not left in a folder
    /// that no longer exists — it moves to `notes/`, whole.
    func testAnIndexHoldingAHumanBlockIsKeptWhole() throws {
        let index = scaffold("04 Career")
            + "\n<!-- mull:block id=section:roles src=human -->\n## Roles\n\n- Founder\n"
        write("04_career/index.md", index)

        migrate()

        let kept = read("notes/04_career/index.md")
        XCTAssertNotNil(kept, "a human block was deleted")
        XCTAssertTrue(kept?.contains("- Founder") ?? false, kept ?? "nil")
        XCTAssertFalse(exists("04_career"))
    }

    /// Nothing but mull's own writing: the scaffold goes, and so does the folder.
    func testAScaffoldOnlyIndexIsDiscarded() throws {
        write("05_people/index.md", scaffold("05 People")
            + "\n<!-- mull:block id=section:key-people src=agent hash=abc -->\n## Key people\n\n- x\n")

        migrate()

        XCTAssertFalse(exists("05_people"))
        XCTAssertNil(read("notes/05_people.md"), "there was no prose of the user's to rescue")
    }

    /// A file the user filed in a numbered folder by hand belongs to them. It is not
    /// one of mull's destinations, so it lands under `notes/` rather than vanishing.
    func testAUserFileInANumberedFolderMovesToNotes() throws {
        write("02_work/acme-contract.md", "# Acme\n")

        migrate()

        XCTAssertEqual(read("notes/02_work/acme-contract.md"), "# Acme\n")
        XCTAssertFalse(exists("02_work"))
    }

    /// Run twice, land in the same place — `scaffold()` used to run on every launch
    /// and this replaced it, so it is called on every launch too.
    func testMigrationIsIdempotent() throws {
        write("03_projects/atr.md", "# ATR\n")
        write("09_inbox/captures.md", "- a thought\n")

        migrate()
        migrate()

        XCTAssertEqual(read("projects/atr.md"), "# ATR\n")
        XCTAssertEqual(read("inbox.md"), "- a thought\n")
    }

    /// A collision never overwrites the file already at the destination. Choosing a
    /// winner is not the mover's job — so the one that could not land is swept into
    /// `notes/` with everything else the folder held, rather than being dropped.
    func testACollisionNeverOverwritesAndNeverDiscards() throws {
        write("projects/atr.md", "the newer one\n")
        write("03_projects/atr.md", "the older one\n")

        migrate()

        XCTAssertEqual(read("projects/atr.md"), "the newer one\n")
        XCTAssertEqual(read("notes/03_projects/atr.md"), "the older one\n",
                       "the loser of a collision must still exist somewhere")
    }

    // MARK: - Helpers

    private func migrate() { VaultLayout.migrate() }

    private func scaffold(_ title: String) -> String {
        """
        ---
        generator: "mull"
        purpose: "Something."
        ---

        # \(title)

        > mull keeps its own blocks below up to date.

        """
    }

    private func write(_ relative: String, _ content: String) {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }
}
