import XCTest
@testable import mull

/// The vault's markdown house style, and the four shipped defects it exists to
/// stop recurring. Each test names the artifact it was found in — these are not
/// hypothetical shapes, they are what `~/mull` contained.
final class MarkdownDocTests: XCTestCase {

    // MARK: - Front matter

    func testFrontMatterQuotesValues() {
        // The commonest value here is an ISO timestamp. Unquoted, its `:` makes
        // the line an invalid mapping and the whole block renders as visible junk.
        let matter = MarkdownDoc.frontMatter([("updated", "2026-08-09T00:11+08:00")])
        XCTAssertTrue(matter.contains(#"updated: "2026-08-09T00:11+08:00""#), matter)
        XCTAssertTrue(matter.hasPrefix("---\n"))
        XCTAssertTrue(matter.hasSuffix("\n---"))
    }

    func testFrontMatterEscapesQuotesAndNewlines() {
        let matter = MarkdownDoc.frontMatter([("note", "she said \"go\"\nand left")])
        XCTAssertEqual(matter.components(separatedBy: "\n").count, 3,
                       "a newline inside a value must not open a second key line")
        XCTAssertTrue(matter.contains(#"\""#), matter)
    }

    func testHeaderStampsTheGenerator() {
        let header = MarkdownDoc.header(title: "Who I am", meta: [("updated", "t")])
        XCTAssertTrue(header.contains(MarkdownDoc.generatorStamp), header)
        XCTAssertTrue(MarkdownDoc.isGeneratedByMull(header))
    }

    func testStripFrontMatterOnlyTakesALeadingBlock() {
        let doc = "---\nupdated: \"t\"\n---\n\n# Title\n\nbefore\n\n---\n\nafter"
        let stripped = MarkdownDoc.stripFrontMatter(doc)
        XCTAssertFalse(stripped.contains("updated:"))
        XCTAssertTrue(stripped.contains("\n---\n"), "a later --- is a horizontal rule, not metadata")
        XCTAssertEqual(MarkdownDoc.stripFrontMatter("# Title\n\nbody"), "# Title\n\nbody")
    }

    // MARK: - Embedding (the shipped full.md had two H1s and three timestamps)

    func testBodyDropsFrontMatterTitleAndOrientationNote() {
        let doc = MarkdownDoc.header(title: "What I'm working on",
                                     meta: [("updated", "2026-08-09T00:11+08:00")],
                                     note: "Edit any of this — your edits are kept.")
            + "\n\n## Right now\n\n- **Active:** Mull"
        let body = MarkdownDoc.body(of: doc)
        XCTAssertEqual(body, "## Right now\n\n- **Active:** Mull")
        XCTAssertFalse(body.contains("2026-08-09"))
        XCTAssertFalse(body.contains("your edits are kept"),
                       "the note is addressed to an editor of that file, not of the host")
    }

    func testBodyKeepsAQuoteThatIsNotTheOrientationNote() {
        let doc = "# Title\n\n## Section\n\n> a quote the user wrote\n"
        XCTAssertTrue(MarkdownDoc.body(of: doc).contains("> a quote the user wrote"))
    }

    func testEmbeddingLeavesExactlyOneH1() {
        // full.md used to append me.md and now.md whole. Reproduce that pairing
        // the correct way and assert the property that failed.
        let me = MarkdownDoc.header(title: "Who I am", meta: [("updated", "t1")]) + "\n\n- a fact"
        let now = MarkdownDoc.header(title: "What I'm working on", meta: [("updated", "t2")])
            + "\n\n## Right now\n\n- **Active:** Mull"

        let full = MarkdownDoc.header(title: "Full context", meta: [("updated", "t3")]) + "\n\n"
            + MarkdownDoc.join([
                MarkdownDoc.section("Who I am", MarkdownDoc.demoteHeadings(MarkdownDoc.body(of: me), by: 1)),
                MarkdownDoc.section("What I'm working on", MarkdownDoc.demoteHeadings(MarkdownDoc.body(of: now), by: 1)),
            ])

        let h1s = full.components(separatedBy: "\n").filter { $0.hasPrefix("# ") }
        XCTAssertEqual(h1s, ["# Full context"], "one spine per document")
        XCTAssertTrue(full.contains("### Right now"), "an embedded ## must drop to ###")
    }

    func testDemoteHeadingsSkipsFencedCodeAndClampsAtSix() {
        let text = "## Heading\n\n```sh\n# not a heading\n```\n\n###### Deep"
        let out = MarkdownDoc.demoteHeadings(text, by: 2)
        XCTAssertTrue(out.contains("#### Heading"))
        XCTAssertTrue(out.contains("\n# not a heading\n"), "a shell comment is not a heading")
        XCTAssertTrue(out.contains("###### Deep"), "clamp: ####### is not a heading at all")
    }

    func testDemoteHeadingsIgnoresHashesWithoutASpace() {
        XCTAssertEqual(MarkdownDoc.demoteHeadings("#hashtag", by: 1), "#hashtag")
    }

    // MARK: - Foreign text (the shipped proactive.md)

    func testInlineFlattensAMultiLineClipboardDump() {
        // The exact shape that broke proactive.md: a copied OneTab dump landed in
        // a `- ` bullet, ended the list at its first newline, and ran the rest
        // together as prose — four near-identical times in a row.
        let dump = """
            OneTab
            【超簡単！】ゼロから始めるバックテスト-MT5編- - YouTube
            パソコン博士taiki windows11 - YouTube
            """
        let flat = MarkdownDoc.inline(dump)
        XCTAssertFalse(flat.contains("\n"))
        XCTAssertTrue(flat.contains("OneTab · "), flat)
    }

    func testInlineTruncatesWithoutLeavingATrailingSpace() {
        let flat = MarkdownDoc.inline(String(repeating: "ab ", count: 200), limit: 20)
        XCTAssertTrue(flat.hasSuffix("…"))
        XCTAssertFalse(flat.contains(" …"))
        XCTAssertLessThanOrEqual(flat.count, 21)
    }

    func testQuotePrefixesEveryLineIncludingBlankOnes() {
        let quoted = MarkdownDoc.quote("first\n\nsecond")
        XCTAssertEqual(quoted, "> first\n>\n> second",
                       "a bare blank line would split the quote into two")
    }

    func testQuoteMarksTruncation() {
        XCTAssertTrue(MarkdownDoc.quote("a\nb\nc", maxLines: 2).hasSuffix("> …"))
    }

    // MARK: - Empty sections

    func testAnEmptySectionIsNotWritten() {
        XCTAssertNil(MarkdownDoc.section("Values", nil))
        XCTAssertNil(MarkdownDoc.section("Values", "   \n  "))
        XCTAssertNil(MarkdownDoc.section("Values", items: []))
        XCTAssertEqual(MarkdownDoc.section("Values", "- a"), "## Values\n\n- a")
        XCTAssertEqual(MarkdownDoc.section("Values", level: 3, "- a"), "### Values\n\n- a")
    }

    func testJoinDropsTheNilsAndSpacesTheRest() {
        XCTAssertEqual(MarkdownDoc.join([MarkdownDoc.section("A", "1"), nil,
                                         MarkdownDoc.section("B", "2")]),
                       "## A\n\n1\n\n## B\n\n2")
    }

    // MARK: - Self-recognition

    /// mull captures the clipboard and window text of a Mac with mull's own files
    /// open on it. Six detectors used to recognise those files by the phrase
    /// "auto-updated" in the header — an English fragment doing structural work,
    /// which this change reworded. Nothing fails visibly when that regresses; the
    /// vault just starts eating itself.
    func testRecognisesItsOwnOutputOldAndNew() {
        XCTAssertTrue(MarkdownDoc.isGeneratedByMull(Curator.nowHeader(timestamp: "t")))
        XCTAssertTrue(MarkdownDoc.isGeneratedByMull(Curator.meHeader(timestamp: "t")))
        XCTAssertTrue(MarkdownDoc.isGeneratedByMull(Curator.fullHeader(timestamp: "t")))
        XCTAssertTrue(MarkdownDoc.isGeneratedByMull("About the user (auto-updated: 02/04/2026)"),
                      "events recorded before the stamp existed are still in the database")
        XCTAssertTrue(MarkdownDoc.isGeneratedByMull("<!-- mull:block id=now:live src=agent -->"))

        XCTAssertFalse(MarkdownDoc.isGeneratedByMull("ViewController.swift — PantryApp"))
        XCTAssertFalse(MarkdownDoc.isGeneratedByMull("func startRecording()"))
    }

    // MARK: - Link resolution

    /// A vault that contains exactly the files these links name.
    private func vault(_ paths: Set<String>) -> (String) -> Bool {
        { paths.contains($0) }
    }

    /// The link form mull writes itself. `MEMORY.md` is a list of these and nothing
    /// else, and every one of them was inert: schemeless, so `NSWorkspace` and
    /// `openURL` both had nothing to open, and neither said so.
    func testRelativeVaultLinkResolves() {
        let target = MarkdownDoc.linkTarget("memory/obsidian.md", from: "MEMORY.md",
                                            exists: vault(["memory/obsidian.md"]))
        XCTAssertEqual(target, .vaultFile("memory/obsidian.md"))
    }

    /// Percent-encoding survives the markdown parser, and mull's own memory files
    /// are named in Japanese.
    func testPercentEncodedJapanesePathResolves() {
        let target = MarkdownDoc.linkTarget("memory/%E8%A8%AD%E8%A8%88.md", from: "MEMORY.md",
                                            exists: vault(["memory/設計.md"]))
        XCTAssertEqual(target, .vaultFile("memory/設計.md"))
    }

    func testRelativeLinkResolvesAgainstItsOwnFolder() {
        let target = MarkdownDoc.linkTarget("../me.md", from: "03_projects/mull.md",
                                            exists: vault(["me.md"]))
        XCTAssertEqual(target, .vaultFile("me.md"))
    }

    /// Obsidian-style: the extension is implied.
    func testMissingExtensionIsInferred() {
        let target = MarkdownDoc.linkTarget("memory/obsidian", from: "MEMORY.md",
                                            exists: vault(["memory/obsidian.md"]))
        XCTAssertEqual(target, .vaultFile("memory/obsidian.md"))
    }

    func testExternalLinkIsHandedToTheSystem() {
        XCTAssertEqual(MarkdownDoc.linkTarget("https://example.com/x"),
                       .external(URL(string: "https://example.com/x")!))
    }

    /// These documents are written by mull, by the user, and by any agent holding
    /// `write_note`. A link is untrusted input; a click is not consent to open an
    /// arbitrary file on the disk.
    func testLinkCannotClimbOutOfTheVault() {
        XCTAssertEqual(MarkdownDoc.linkTarget("../../.ssh/id_rsa", from: "MEMORY.md",
                                              exists: { _ in true }), .unresolved)
        XCTAssertEqual(MarkdownDoc.linkTarget("/etc/passwd", from: "MEMORY.md",
                                              exists: { _ in true }), .unresolved)
        XCTAssertEqual(MarkdownDoc.linkTarget("file:///etc/passwd"), .unresolved)
    }

    func testAnchorAndDeadLinkAreUnresolved() {
        XCTAssertEqual(MarkdownDoc.linkTarget("#section", from: "me.md", exists: { _ in true }),
                       .unresolved)
        XCTAssertEqual(MarkdownDoc.linkTarget("memory/gone.md", from: "MEMORY.md",
                                              exists: vault([])), .unresolved)
    }
}
