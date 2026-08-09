import XCTest
@testable import mull

/// The question "does mull write this file?" had two answers living in two files, and
/// they disagreed. The MCP server refused to let an agent raw-overwrite `full.md`,
/// `mull.md`, `proactive.md` and the folder `index.md` files; the Files tab offered
/// those same four for editing, with a Save button.
///
/// `mull.md` was where that cost work. It is written with a wholesale
/// `MullDirectory.write` rather than through the Curator, so it carries no provenance
/// markers and there is no hand edit to promote to `.human` and protect — whatever was
/// typed into it was gone at the next 60-second pass, with nothing said.
///
/// These tests exist so the answer stays in one place. Note that unifying the two
/// lists did not mean picking `.mull` for everything: a file mull curates rather than
/// assembles is `.shared` — see `testAnAgentMayNotStampOverACuratedFile` for why the
/// editor gets a different answer there than the MCP server does.
final class VaultOwnershipTests: XCTestCase {

    func testEveryFileMullGeneratesIsMullWritten() {
        for name in ["me.md", "now.md", "full.md", "MEMORY.md", "mull.md", "proactive.md"] {
            XCTAssertEqual(VaultOwnership.of(path: name), .mull, name)
            XCTAssertEqual(VaultOwnership.of(path: absolute(name)), .mull,
                           "\(name): the answer must not depend on being asked with a full path")
        }
    }

    /// Three of the four that regressed. `mull.md` is the one that cost work: it is
    /// written with a wholesale `MullDirectory.write`, so there is no hand edit to
    /// promote and protect.
    func testTheFilesTheEditorUsedToOfferAreNotEditable() {
        XCTAssertEqual(VaultOwnership.of(path: "full.md"), .mull)
        XCTAssertEqual(VaultOwnership.of(path: "mull.md"), .mull)
        XCTAssertEqual(VaultOwnership.of(path: "proactive.md"), .mull)
    }

    /// The fourth — a folder's `index.md` — no longer exists to have an answer.
    /// mull stopped writing folder indexes when the numbered folders were retired
    /// (DIRECTION §6.1); one in the vault now is a file the user made, and theirs.
    func testAFolderIndexIsNowJustAUserFile() {
        for path in ["index.md", "notes/index.md", "notes/deep/index.md"] {
            XCTAssertEqual(VaultOwnership.of(path: path), .user, path)
        }
    }

    /// What `.shared` describes now: the two directories mull writes into through
    /// the Curator. It owns the blocks it stamped; every other line is the user's.
    func testCuratedDirectoriesAreSharedAtAnyDepth() {
        for path in ["projects/mull.md", "corrections/ledger.md",
                     "corrections/2026-08-09-abc.md", absolute("projects/atr.md")] {
            XCTAssertEqual(VaultOwnership.of(path: path), .shared, path)
        }
    }

    /// The distinction `.shared` exists to draw: the person at the keyboard is
    /// editing the file, an agent would be replacing it.
    ///
    /// These two questions are asked by different callers and must keep giving
    /// different answers — the Files tab asks `isMullWritten` to decide whether to
    /// show an editor, the MCP server asks `refusesWholesaleWrite` to decide whether
    /// to let `write_note` through.
    func testAnAgentMayNotStampOverACuratedFile() {
        XCTAssertFalse(VaultOwnership.isMullWritten(path: "projects/mull.md"),
                       "the Files tab asks this — a locked briefing is the bug")
        XCTAssertTrue(VaultOwnership.refusesWholesaleWrite(path: "projects/mull.md"),
                      "the MCP server asks this — write_note would flatten the markers")
    }

    /// `VaultProvenance` used to answer this same question from a second copy of the
    /// list. It was deleted on 2026-08-09: nothing in production ever called it, the
    /// `VaultProvenanceTests` its own doc comment cited did not exist, and its two
    /// tables had already drifted from these — `_raw/` was generated in one and absent
    /// from the other. A duplicate nobody reads is still a duplicate that can disagree.
    func testCuratedDirectoriesAreTheOnesWithACuratorBehindThem() {
        for path in ["projects/mull.md", "corrections/ledger.md"] {
            XCTAssertEqual(VaultOwnership.of(path: path), .shared, path)
        }
    }

    /// Everything under a generated folder is wholly mull's, whatever it is called.
    func testAnythingInsideAGeneratedFolderStaysMulls() {
        XCTAssertEqual(VaultOwnership.of(path: "memory/index.md"), .mull)
        XCTAssertEqual(VaultOwnership.of(path: "daily/2026/index.md"), .mull)
    }

    func testGeneratedFoldersAreMullWrittenThroughout() {
        for path in ["daily/2026-08-09.md", "memory/some-fact.md",
                     absolute("daily/2026-08-09.md")] {
            XCTAssertEqual(VaultOwnership.of(path: path), .mull, path)
        }
    }

    /// The user's own file is `.user` even though mull does write to it — it lays the
    /// scaffold down and maintains the onboarding section. What it never rewrites is a
    /// line the user wrote, and that is the distinction this type draws (CLAUDE.md §7.4).
    /// Getting this wrong the other way would take away the one file they can correct
    /// mull in.
    func testThePinnedFileStaysTheUsers() {
        XCTAssertEqual(VaultOwnership.of(path: Curator.pinnedFileName), .user)
        XCTAssertEqual(VaultOwnership.of(path: absolute(Curator.pinnedFileName)), .user)
    }

    func testOrdinaryNotesAreTheUsers() {
        for path in ["notes/idea.md", "notes/2026/trip.md", "README.md",
                     "notes/daily-standup.md"] {
            XCTAssertEqual(VaultOwnership.of(path: path), .user, path)
        }
    }

    /// A root file's name only means something AT the root. Matched anywhere, it
    /// locked `projects/mull.md` — the path `write_note`'s own description offers as
    /// its example — and any note the user happened to name `now.md`.
    func testARootFileNameOnlyCountsAtTheRoot() {
        XCTAssertEqual(VaultOwnership.of(path: "notes/mull.md"), .user)
        XCTAssertEqual(VaultOwnership.of(path: "notes/2026/now.md"), .user)
        XCTAssertEqual(VaultOwnership.of(path: "projects/mull.md"), .shared)
        XCTAssertEqual(VaultOwnership.of(path: "mull.md"), .mull)
    }

    private func absolute(_ relative: String) -> String {
        MullDirectory.root.appendingPathComponent(relative).path
    }

    /// A folder the user names "daily" under their own notes stays theirs.
    ///
    /// This assertion used to run the other way, recording the old
    /// `path.contains("/daily/")` behaviour "so a change to it is a decision, not a
    /// surprise". The change was then made, deliberately, and the reason is written
    /// on `VaultOwnership.mullWrittenFolders`: matching at any depth locked a user's
    /// own `notes/daily/` read-only and closed it to agents. mull creates `daily/`
    /// and `memory/` at the top of the vault and nowhere else, so the top is the only
    /// place the name means anything. This is that decision arriving in the test.
    func testAFolderNamedDailyOnlyCountsAtTheRoot() {
        XCTAssertEqual(VaultOwnership.of(path: "notes/daily/monday.md"), .user)
        XCTAssertEqual(VaultOwnership.of(path: "daily/monday.md"), .mull)
    }
}
