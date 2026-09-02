import XCTest
@testable import mull

/// Forgetting a note mull wrote about you is a correction, and it has to be recorded
/// as one.
///
/// "Notes mull keeps" is captioned "They are about you, and you can correct or delete
/// any of them", and its two buttons are the only per-line correction controls in the
/// app — the vault editor that used to be the other one went with the Files tab
/// (DIRECTION §6.2). Until 2026-08-18 both threw the verdict away: the row changed,
/// the markdown file changed, and nothing downstream heard. No card for
/// `get_corrections`, no delta in the ledger `Selection` reads.
///
/// That is the same wire that was missing on the calendar, and it is the reason
/// `~/mull/corrections/` did not exist as a directory nine days after the loop was
/// declared open.
final class MemoryCorrectionTests: XCTestCase {

    private func memory(_ name: String, _ description: String) -> MemoryEntry {
        MemoryEntry(name: name, description: description, memoryType: .user,
                    content: "…", filePath: "memory/\(name).md",
                    createdAt: Date(), updatedAt: Date())
    }

    // MARK: - What a forget says

    /// Empty `kept` is the whole verdict. `dropped` then holds mull's line, so folding
    /// it puts a negative delta on that text — which is right beyond this screen: a
    /// sentence not worth keeping in me.md is not worth a slot in a context window.
    func testAForgottenNoteBecomesADroppedLine() {
        let entry = memory("Messaging preference", "Used LINE on 17 August 2026.")
        let card = CorrectionCard(path: "memory", blockID: entry.filePath, date: Date(),
                                  kept: "", wouldWrite: entry.description, context: nil)

        XCTAssertEqual(card.dropped, ["Used LINE on 17 August 2026."])
        XCTAssertTrue(card.survived.isEmpty)

        let index = CorrectionIndex.fold([card])
        XCTAssertLessThan(index.delta(for: "Used LINE on 17 August 2026."), 0,
                          "a line the human deleted must weigh less, not the same")
    }

    /// A rewrite says two things at once: mull's wording was wrong, and this is right.
    func testARewriteDropsMullsWordingAndKeepsTheHumans() {
        let entry = memory("Work rhythm", "Did heavy editing in the afternoon on 17 August 2026.")
        let card = CorrectionCard(path: "memory", blockID: entry.filePath, date: Date(),
                                  kept: "Reviews in the afternoon; mornings are for uninterrupted work.",
                                  wouldWrite: entry.description, context: nil)

        XCTAssertEqual(card.dropped, ["Did heavy editing in the afternoon on 17 August 2026."])
        XCTAssertEqual(card.added, ["Reviews in the afternoon; mornings are for uninterrupted work."])
    }

    /// Opening the editor and closing it again is not a correction. Recording one
    /// would put a verdict in the ledger that nobody rendered.
    func testAnUntouchedEditorRecordsNothing() {
        let entry = memory("x", "Prefers terse answers.")
        let before = MullDirectory.read(CorrectionIndex.ledgerPath)

        HeldMemoryStore.recordCorrection(of: entry, keeping: entry.description)
        XCTAssertEqual(MullDirectory.read(CorrectionIndex.ledgerPath), before)

        // Whitespace is not an edit either.
        HeldMemoryStore.recordCorrection(of: entry, keeping: "  Prefers terse answers.  ")
        XCTAssertEqual(MullDirectory.read(CorrectionIndex.ledgerPath), before)
    }

    // MARK: - Every gesture goes through one writer

    /// Three callers wrote the same eleven lines, and this made a fourth. The point of
    /// folding them into `Curator.record` is that a correction cannot arrive by a route
    /// that forgets the ledger — which is exactly what the calendar's did.
    func testEveryCorrectionGoesThroughTheOneWriter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        for file in ["Mull/Services/CalendarMirrorRunner.swift",
                     "Mull/Views/Settings/NotesSection.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("Curator.record(cards:"),
                          "\(file) must record through the shared writer")
            XCTAssertFalse(text.contains("CorrectionIndex.merge("),
                           "\(file) is folding the ledger itself again")
        }
    }

    func testForgetAndCorrectBothRecord() throws {
        let notes = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Mull/Views/Settings/NotesSection.swift"),
            encoding: .utf8)

        // A forget keeps nothing — that is the strongest verdict the card can carry.
        XCTAssertTrue(notes.contains("HeldMemoryStore.recordCorrection(of: memory, keeping: \"\")"),
                      "the Forget button must record the deletion as a correction")
        XCTAssertTrue(notes.contains("HeldMemoryStore.recordCorrection(of: memory, keeping: updated.description)"),
                      "the Correct button must record the rewrite")
    }
}
