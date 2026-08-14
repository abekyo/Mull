import XCTest
@testable import mull

/// The files `eval/calendar/run.sh` compiles must stay reachable without a database or
/// a calendar.
///
/// SELECTION-LAYER §6.4 records the selection harness rotting twice, both times because
/// the code moved and the harness quietly stopped being able to build the thing it
/// claimed to score. `eval/` cannot defend itself here: it has no CI (CI has no
/// database) and it is not compiled by any target, so a single `import EventKit` added
/// to `CalendarMirror.swift` breaks the measurement and nothing says so until somebody
/// next goes looking for a number.
///
/// This is a lint wearing a test's clothes, like `ShippedVocabularyTests`. It reads the
/// files themselves rather than trusting a comment on them.
final class EvalReachabilityTests: XCTestCase {

    /// Everything in the calendar harness's compile list that lives under `Mull/`.
    /// Kept in step with `eval/calendar/run.sh` by `testTheHarnessListMatchesThisTest`
    /// below, so the two cannot drift apart silently — which is the whole failure mode.
    private static let harnessFiles = [
        "Mull/Core/ProjectNames.swift",
        "Mull/Core/TextScript.swift",
        "Mull/Core/TestInput.swift",
        "Mull/Core/SensitiveText.swift",
        "Mull/Core/InstructionText.swift",
        "Mull/Core/Redactor.swift",
        "Mull/Core/Preferences.swift",
        "Mull/Core/UserLanguage.swift",
        "Mull/Core/VaultText.swift",
        "Mull/Core/TimeFormatting.swift",
        "Mull/Core/EditDistance.swift",
        "Mull/Core/ContextBlock.swift",
        "Mull/Core/CorrectionCard.swift",
        "Mull/Core/CalendarEventHandle.swift",
        "Mull/Core/BlockSegmentation.swift",
        "Mull/Core/CalendarMirror.swift",
    ]

    /// What the harness cannot link. GRDB and EventKit are the two the split exists to
    /// keep out; SwiftUI and AppKit would mean a core file had reached the app layer,
    /// which `MullMCP` also forbids but only for files it happens to compile.
    private static let forbidden = ["GRDB", "EventKit", "SwiftUI", "AppKit", "Cocoa"]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/
            .deletingLastPathComponent()    // repo root
    }

    func testTheHarnessFilesImportNothingItCannotLink() throws {
        var offences: [String] = []

        for relative in Self.harnessFiles {
            let url = Self.root.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = String(trimmed.dropFirst("import ".count))
                    .trimmingCharacters(in: .whitespaces)
                if Self.forbidden.contains(module) {
                    offences.append("\(relative):\(index + 1) — import \(module)")
                }
            }
        }

        XCTAssertTrue(offences.isEmpty, """
            An import here breaks `./eval/calendar/run.sh`, which is the only thing
            measuring the titles mull writes to somebody's real calendar. Move whatever
            needs the framework to the layer that already has it — `TimeBlockEngine`
            for the database, `CalendarService` for EventKit:

            \(offences.joined(separator: "\n"))
            """)
    }

    /// The list above and the shell script must name the same files.
    ///
    /// Without this the test passes while guarding a set of files the harness no longer
    /// compiles — a green check over nothing, which is worse than no check.
    func testTheHarnessListMatchesThisTest() throws {
        let script = try String(contentsOf: Self.root.appendingPathComponent("eval/calendar/run.sh"),
                                encoding: .utf8)
        let named = script.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " \\", with: "") }
            .filter { $0.hasPrefix("Mull/") && $0.hasSuffix(".swift") }

        XCTAssertEqual(Set(named), Set(Self.harnessFiles), """
            eval/calendar/run.sh and EvalReachabilityTests have drifted.
            In the script but not the test: \(Set(named).subtracting(Self.harnessFiles).sorted())
            In the test but not the script: \(Set(Self.harnessFiles).subtracting(named).sorted())
            """)
    }

    /// Every file the list names still exists. A rename that updates the script and not
    /// this test would otherwise be caught; a rename that updates neither would not.
    func testEveryHarnessFileExists() {
        for relative in Self.harnessFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(relative).path),
                "\(relative) is in the harness list and not on disk")
        }
    }
}
