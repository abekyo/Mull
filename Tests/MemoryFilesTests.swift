import XCTest
@testable import mull

/// What a memory is called on disk, and the repair for the names that predate the
/// rule. The repair moves a file AND the database row that points at it, so it gets
/// tests for the same reason `VaultLayout` does: it touches the user's data.
final class MemoryFilesTests: XCTestCase {

    private var created: [String] = []

    override func tearDownWithError() throws {
        for path in created { _ = MullDirectory.delete(path) }
        created.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - The rule

    /// The colon is the one that mattered. Finder renders a POSIX `:` as `/`, so
    /// `work_rhythm:_afternoons_for_editing.md` was one file with two names — mull's
    /// and Finder's — in a vault whose whole claim is that you can open it in anything.
    func testColonsAndSlashesNeverReachTheFileSystem() {
        for name in ["Work rhythm: afternoons for editing", "台本：3大理論", "a/b"] {
            let file = MemoryFiles.fileName(for: name)
            XCTAssertFalse(file.contains(":"), file)
            XCTAssertFalse(file.contains("："), file)
            XCTAssertFalse(file.contains("/"), file)
            XCTAssertTrue(file.hasSuffix(".md"), file)
        }
    }

    /// Capitalisation is the writer's. The old rule lowercased everything, which
    /// turned "VS Code" into "vs_code" — a name nobody typed.
    func testCapitalisationSurvives() {
        XCTAssertEqual(MemoryFiles.fileName(for: "VS Code habits"), "VS-Code-habits.md")
    }

    /// A leading dot would hide the file; a name that sanitises away to nothing would
    /// produce a bare ".md".
    func testDegenerateNamesStillProduceAUsableFile() {
        XCTAssertEqual(MemoryFiles.fileName(for: ".hidden"), "hidden.md")
        XCTAssertEqual(MemoryFiles.fileName(for: "   "), "memory.md")
        XCTAssertEqual(MemoryFiles.fileName(for: "///"), "memory.md")
    }

    func testTheRuleIsAFixedPoint() {
        let once = MemoryFiles.fileName(for: "Work rhythm: afternoons")
        XCTAssertEqual(MemoryFiles.fileName(for: String(once.dropLast(3))), once,
                       "running the repair twice must not keep renaming the same file")
    }

    // MARK: - The repair

    func testALegacyNameIsRenamedAndTheRowFollowsIt() throws {
        let db = FakeMemoryStore(entries: [entry(name: "Work rhythm: afternoons",
                                                path: "memory/work_rhythm:_afternoons.md")])
        write("memory/work_rhythm:_afternoons.md", "body")

        XCTAssertEqual(MemoryFiles.repairLegacyNames(database: db), 1)

        XCTAssertEqual(MullDirectory.read("memory/Work-rhythm-afternoons.md"), "body")
        XCTAssertNil(MullDirectory.read("memory/work_rhythm:_afternoons.md"))
        XCTAssertEqual(db.entries.first?.filePath, "memory/Work-rhythm-afternoons.md",
                       "a file renamed without its row is a memory the user cannot edit or forget")
    }

    func testAlreadyCorrectNamesAreLeftAlone() throws {
        let db = FakeMemoryStore(entries: [entry(name: "Plain name", path: "memory/Plain-name.md")])
        write("memory/Plain-name.md", "body")

        XCTAssertEqual(MemoryFiles.repairLegacyNames(database: db), 0)
        XCTAssertEqual(db.updateCount, 0, "a clean vault must not be rewritten on every launch")
    }

    /// Two memories whose names differ only in punctuation collapse to one file name.
    /// Moving the second over the first would delete a memory the user still has.
    func testACollisionIsSkippedRatherThanOverwriting() throws {
        let db = FakeMemoryStore(entries: [entry(name: "Same name", path: "memory/same_name.md")])
        write("memory/same_name.md", "the one being moved")
        write("memory/Same-name.md", "the one already there")

        XCTAssertEqual(MemoryFiles.repairLegacyNames(database: db), 0)
        XCTAssertEqual(MullDirectory.read("memory/Same-name.md"), "the one already there")
        XCTAssertEqual(MullDirectory.read("memory/same_name.md"), "the one being moved")
    }

    /// A row whose file is already gone is not a reason to touch the row: the path is
    /// the only record of what it pointed at.
    func testARowWithNoFileIsLeftUntouched() {
        let db = FakeMemoryStore(entries: [entry(name: "Gone: away", path: "memory/gone:_away.md")])

        XCTAssertEqual(MemoryFiles.repairLegacyNames(database: db), 0)
        XCTAssertEqual(db.entries.first?.filePath, "memory/gone:_away.md")
    }

    // MARK: - Helpers

    private func entry(name: String, path: String) -> MemoryEntry {
        MemoryEntry(name: name, description: "d", memoryType: .reference, content: "c",
                    filePath: path, createdAt: Date(), updatedAt: Date())
    }

    /// Registers both where the file starts and where a repair could move it, so a
    /// failing test cannot leave either behind for the next one to trip over.
    private func write(_ relative: String, _ content: String) {
        _ = MullDirectory.write(content, to: relative)
        created.append(relative)
        let name = (relative as NSString).lastPathComponent
        created.append("memory/" + MemoryFiles.fileName(for: String(name.dropLast(3))))
    }
}

/// Stands in for the database so the repair can be tested without one. The protocol
/// it satisfies is deliberately two methods wide — the repair changes a path and
/// nothing else about a memory.
private final class FakeMemoryStore: MemoryWriting {
    var entries: [MemoryEntry]
    private(set) var updateCount = 0

    init(entries: [MemoryEntry]) { self.entries = entries }

    func fetchAllMemories() -> [MemoryEntry] { entries }

    func updateMemory(_ entry: MemoryEntry) {
        updateCount += 1
        if let idx = entries.firstIndex(where: { $0.name == entry.name }) {
            entries[idx] = entry
        }
    }
}
