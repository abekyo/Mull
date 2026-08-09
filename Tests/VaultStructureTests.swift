import XCTest
@testable import mull

/// End-to-end shape of the files mull writes, asserted against the real write
/// path (the vault root is a throwaway directory under XCTest).
///
/// These check structure, never content: what they defend is that a reader —
/// Obsidian, GitHub, VS Code, mull's own preview, or a model — sees one
/// document with one spine, and never mull's internals leaking through as
/// prose. Every assertion here corresponds to something the shipped vault got
/// wrong.
final class VaultStructureTests: XCTestCase {

    private var database: DatabaseService!
    private var savedLanguage: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // These assert structure, but they locate that structure by quoting the
        // headings — "### Right now", "# What I'm working on". Since `VaultText`
        // those headings follow the reader's language, so an unpinned suite passes
        // on an English Mac and fails on a Japanese one, and the failure reads as a
        // structural break rather than as a translation.
        savedLanguage = UserDefaults.standard.string(forKey: UserLanguage.preferenceKey)
        UserDefaults.standard.set(UserLanguage.Preference.english.rawValue,
                                  forKey: UserLanguage.preferenceKey)
        _ = MullDirectory.setup()      // the throwaway XCTest vault, not ~/mull
        database = try DatabaseService.temporary()
    }

    override func tearDown() {
        for name in ["me.md", "now.md", "full.md", "mull.md"] {
            _ = MullDirectory.delete(name)
        }
        UserDefaults.standard.set(savedLanguage, forKey: UserLanguage.preferenceKey)
        database = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Calendar and email are passed as nil: this asserts document shape, and
    /// neither test has any business near the user's real EventKit or Mail.
    private func generate() {
        XCTAssertNoThrow(try LiveContextGenerator.generate(
            analytics: AnalyticsEngine(database: database),
            database: database, calendar: nil, inbox: .none))
    }

    private func read(_ name: String) -> String {
        MullDirectory.read(name) ?? ""
    }

    /// Content lines, with Curator provenance markers and front matter removed —
    /// what a renderer actually lays out.
    private func renderedLines(_ text: String) -> [String] {
        MarkdownDoc.stripFrontMatter(ContextBlockFile.stripMarkers(text))
            .components(separatedBy: "\n")
    }

    private func assertSingleSpine(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = read(name)
        XCTAssertFalse(text.isEmpty, "\(name) was not written", file: file, line: line)

        let h1s = renderedLines(text).filter { $0.hasPrefix("# ") }
        XCTAssertEqual(h1s.count, 1, "\(name) must have exactly one H1, got \(h1s)",
                       file: file, line: line)
    }

    // MARK: - Structure

    func testEachContractFileHasOneTitleAndFrontMatter() {
        seedActivity()
        generate()
        for name in ["me.md", "now.md", "full.md", "mull.md"] {
            assertSingleSpine(name)
            XCTAssertTrue(read(name).hasPrefix("---\n"),
                          "\(name) must open with front matter, not prose")
        }
    }

    /// full.md used to append me.md and now.md whole — front matter, `# ` title
    /// and timestamp included — so the shipped file carried two H1s and printed
    /// its update time three times, twice from the middle of another document.
    func testFullDoesNotInheritTheEmbeddedFilesChrome() {
        seedActivity()
        generate()
        let full = read("full.md")

        XCTAssertTrue(full.contains("### Right now"),
                      "precondition: now.md must actually be embedded here")
        XCTAssertEqual(full.components(separatedBy: "generator: \"mull\"").count - 1, 1,
                       "one front-matter block, not one per embedded file")
        XCTAssertFalse(renderedLines(full).contains { $0.hasPrefix("# What I'm working on") },
                       "now.md's own title must not appear inside full.md")
        XCTAssertFalse(full.contains("survive the next update"),
                       "now.md's orientation note contradicts full.md's own")
        assertSingleSpine("full.md")
    }

    /// Metadata belongs in front matter. A timestamp in the body is the shape
    /// this replaced: three italic lines of housekeeping before the first fact.
    func testTheBodyCarriesNoTimestamp() {
        generate()
        let stamp = String(Curator.timestamp().prefix(4))   // the year
        for name in ["me.md", "now.md", "full.md"] {
            let body = MarkdownDoc.stripFrontMatter(read(name))
            XCTAssertFalse(body.contains(stamp),
                           "\(name) repeats its timestamp in the body")
        }
    }

    /// A `Label:` line is prose to markdown. now.md used to announce `Projects:`
    /// and `Recent days:` that way in the half written by the 60s pass, while the
    /// nightly half of the same file used real `##`.
    func testNoLabelColonLinesStandInForHeadings() {
        seedActivity()
        generate()

        let banned = ["Projects:", "Recent days:", "Key references:", "Recently:",
                      "What you were dealing with today:"]
        for name in ["me.md", "now.md", "full.md"] {
            for line in renderedLines(read(name)) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                XCTAssertFalse(banned.contains(trimmed),
                               "\(name): '\(trimmed)' is a heading written as prose")
            }
        }
    }

    /// Every heading level must have a parent one step above it: an `###` under
    /// an `#` means a level was skipped, and an `##` directly under another `##`
    /// that was meant to contain it is the inversion the nightly block shipped.
    func testHeadingLevelsNeverSkip() {
        seedActivity()
        generate()
        for name in ["me.md", "now.md", "full.md", "mull.md"] {
            var previous = 0
            var inFence = false
            for line in renderedLines(read(name)) {
                if line.hasPrefix("```") { inFence.toggle(); continue }
                guard !inFence, line.hasPrefix("#") else { continue }
                let level = line.prefix { $0 == "#" }.count
                guard line.dropFirst(level).hasPrefix(" ") else { continue }
                XCTAssertLessThanOrEqual(level, previous + 1,
                                         "\(name): '\(line)' jumps from H\(previous)")
                previous = level
            }
        }
    }

    /// The provenance markers are internal. They are stripped from every derived
    /// artifact, and a derived file that leaked one would show `hash=4e81ba2b…`
    /// to the reader.
    func testDerivedArtifactsCarryNoProvenanceMarkers() {
        generate()
        XCTAssertFalse(read("full.md").contains(ContextBlockFile.markerPrefix + " id=now:"),
                       "embedded blocks must arrive stripped")
    }

    /// mull captures a Mac on which mull's own files are open. If it stops
    /// recognising its own writing, the vault begins eating itself — and nothing
    /// about that failure is visible until the analytics are full of "generator".
    func testGeneratedFilesAreRecognisedAsMullsOwnOutput() {
        generate()
        for name in ["me.md", "now.md", "full.md", "mull.md"] {
            XCTAssertTrue(MarkdownDoc.isGeneratedByMull(read(name)),
                          "\(name) would be re-ingested as user activity")
        }
    }

    // MARK: - Foreign text

    /// A multi-line clipboard entry must not end the list it is placed in. This
    /// is the proactive.md failure, asserted on the shared formatter that all the
    /// generators route through.
    func testMultiLineCaptureCannotBreakAList() {
        let dump = "OneTab\nYouTube — 自動売買\nABEMA\nジャックロード"
        let bullet = "- \(MarkdownDoc.inline(dump))"
        XCTAssertEqual(bullet.components(separatedBy: "\n").count, 1)
    }

    // MARK: - Fixtures

    private func seedActivity() {
        let now = Date()
        for i in 0..<6 {
            database.insertEvent(RecordingEvent(
                timestamp: now.addingTimeInterval(Double(-i * 30)),
                eventType: .screenText, appName: "Code",
                windowTitle: "Mull — ContentView.swift",
                textContent: "Mull — ContentView.swift"))
            // Deliberately multi-line: this is the clipboard shape that used to
            // end the list it was rendered into.
            database.insertEvent(RecordingEvent(
                timestamp: now.addingTimeInterval(Double(-i * 31)),
                eventType: .clipboard, appName: "Code",
                windowTitle: nil,
                textContent: "let value = compute(\(i))\nsecond line \(i)\nthird line \(i)"))
        }
    }
}
