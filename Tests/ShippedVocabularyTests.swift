import XCTest
@testable import mull

/// Two prose rules, asserted against the source itself. This test is where they
/// live — there is no document to defer to, which is the point: a rule kept only in
/// prose is a rule enforced only where a reviewer happened to look.
///
/// **Rule 1: no emoji**, in the interface *and* in the text mull generates.
/// The interface half held; the generated half did not.
/// `list_files` shipped a 📁/📄 file tree and `get_projects` shipped ⚠️ STALLED,
/// because nothing was looking at the strings an agent reads. A rule that only a
/// human reviewer enforces is a rule that holds wherever someone happened to look.
///
/// So this walks every shipped `.swift` file and reads its string literals —
/// comments excluded, since a comment is not something anyone is shown. It is a
/// lint wearing a test's clothes, and it belongs here rather than in a CI script
/// because the same suite already defends the rest of what the vault says.
///
/// The moon (☽) is exempt: it is mull's mark, and a mark is not decoration.
final class ShippedVocabularyTests: XCTestCase {

    /// Directories that ship. `Tests/` is deliberately absent — a test may need an
    /// emoji as *data* (ReportWriterTests builds a family emoji to check grapheme
    /// clustering), and that is the opposite of prose.
    private static let shippedDirectories = ["Mull", "MullMCP"]

    private static let moon: UnicodeScalar = "\u{263D}"

    /// Emoji and pictographic dingbats. Arrows (→) and typographic marks (—, ·)
    /// are not here: they are punctuation the design uses on purpose.
    private static func isEmoji(_ scalar: UnicodeScalar) -> Bool {
        if scalar == moon { return false }
        switch scalar.value {
        case 0x1F300...0x1FAFF,   // pictographs, emoticons, symbols, supplemental
             0x2600...0x27BF,     // misc symbols + dingbats (⚠ ✨ ✅ ✓ …)
             0x2B00...0x2BFF,     // misc symbols and arrows (⬆️ ⭐️ …)
             0xFE0F,              // variation selector-16 — the emoji-presentation flag
             0x1F1E6...0x1F1FF:   // regional indicators (flags)
            return true
        default:
            return false
        }
    }

    // MARK: - The rules

    func testNoShippedStringLiteralCarriesAnEmoji() throws {
        var offences: [String] = []

        for file in try Self.shippedSwiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in Self.stringLiterals(in: source) {
                let found = literal.text.unicodeScalars.filter(Self.isEmoji)
                guard !found.isEmpty else { continue }
                let glyphs = String(String.UnicodeScalarView(found))
                offences.append("\(file.lastPathComponent):\(literal.line) — \(glyphs) in \"\(literal.text.prefix(60))\"")
            }
        }

        XCTAssertTrue(offences.isEmpty, """
            Emoji in shipped strings. They are banned from the UI and from
            generated text alike — say it in SF Symbols, or in words:

            \(offences.joined(separator: "\n"))
            """)
    }

    /// Rule 2: the two SF Symbols that read as the "an AI made this"
    /// face, and mull's whole claim is that it reports what it observed.
    func testNoShippedStringLiteralAsksForTheAIGlyphs() throws {
        let banned = ["sparkles", "wand.and.stars", "wand.and.rays"]
        var offences: [String] = []

        for file in try Self.shippedSwiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in Self.stringLiterals(in: source) where banned.contains(literal.text) {
                offences.append("\(file.lastPathComponent):\(literal.line) — \(literal.text)")
            }
        }

        XCTAssertTrue(offences.isEmpty,
                      "The ✨ glyphs, by name:\n\(offences.joined(separator: "\n"))")
    }

    // MARK: - Reading the source

    private static func shippedSwiftFiles() throws -> [URL] {
        // #filePath is baked in when this file compiles, so it points at the
        // checkout that produced the binary under test.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/
            .deletingLastPathComponent()    // repo root

        var found: [URL] = []
        for directory in shippedDirectories {
            let dir = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else {
                XCTFail("Could not read \(dir.path) — has the source moved?")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                found.append(url)
            }
        }

        // A silent zero would make both rules pass forever.
        XCTAssertFalse(found.isEmpty, "Found no Swift sources to scan under \(root.path)")
        return found
    }

    private struct Literal {
        let text: String
        let line: Int
    }

    /// Every string literal in `source`, with the line it starts on.
    ///
    /// Hand-rolled rather than regex because the two things that must not be
    /// confused — a `//` inside a URL literal and a `"` inside a comment — are
    /// exactly what a regex gets wrong. Interpolation segments are kept as written
    /// (`\(name)`): no emoji hides in an identifier, and dropping them would mean
    /// parsing Swift expressions.
    private static func stringLiterals(in source: String) -> [Literal] {
        enum State { case code, lineComment, blockComment, string, multilineString }

        var state: State = .code
        var blockDepth = 0
        var literals: [Literal] = []
        var buffer = ""
        var startLine = 1
        var line = 1

        let scalars = Array(source.unicodeScalars)
        var i = 0

        func peek(_ offset: Int) -> UnicodeScalar? {
            i + offset < scalars.count ? scalars[i + offset] : nil
        }

        while i < scalars.count {
            let c = scalars[i]
            if c == "\n" { line += 1 }

            switch state {
            case .code:
                if c == "/", peek(1) == "/" {
                    state = .lineComment; i += 2; continue
                }
                if c == "/", peek(1) == "*" {
                    state = .blockComment; blockDepth = 1; i += 2; continue
                }
                if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    state = .multilineString; buffer = ""; startLine = line; i += 3; continue
                }
                if c == "\"" {
                    state = .string; buffer = ""; startLine = line; i += 1; continue
                }

            case .lineComment:
                if c == "\n" { state = .code }

            case .blockComment:
                if c == "/", peek(1) == "*" { blockDepth += 1; i += 2; continue }
                if c == "*", peek(1) == "/" {
                    blockDepth -= 1
                    i += 2
                    if blockDepth == 0 { state = .code }
                    continue
                }

            case .string:
                if c == "\\" { i += 2; continue }   // an escape hides nothing readable
                if c == "\"" || c == "\n" {         // an unterminated literal ends at the newline
                    literals.append(Literal(text: buffer, line: startLine))
                    state = .code; i += 1; continue
                }
                buffer.unicodeScalars.append(c)

            case .multilineString:
                if c == "\\" { i += 2; continue }
                if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    literals.append(Literal(text: buffer, line: startLine))
                    state = .code; i += 3; continue
                }
                buffer.unicodeScalars.append(c)
            }

            i += 1
        }

        return literals
    }
}
