import Foundation
import os.log

private let logger = Logger(subsystem: "com.mull.app", category: "Directory")

/// Central manager for the ~/mull output directory.
/// Validates permissions on startup and before writes.
/// All code that reads/writes ~/mull should go through this.
enum MullDirectory {

    /// True when this process is an XCTest run.
    ///
    /// The test host is the app itself, so `AppState.init()` boots on every test
    /// run — and it calls `setup()` and `VaultLayout.migrate()`, which between them
    /// were rewriting files in the user's REAL vault every time anyone ran the suite
    /// (and now would MOVE them). Tests must never mutate real user data.
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }()

    /// Root directory: ~/mull — or a throwaway directory under XCTest.
    ///
    /// Redirecting the root (rather than guarding each writer) means every path
    /// into the vault is covered at once: Curator, VaultLayout's migration, RawStore,
    /// and the MCP write tools. It also makes those write paths safely
    /// testable, which they were not before.
    static let root: URL = {
        guard isRunningTests else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("mull")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mull-test-vault-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Subdirectories created on setup.
    static let daily: URL = root.appendingPathComponent("daily")
    static let memory: URL = root.appendingPathComponent("memory")
    static let notes: URL = root.appendingPathComponent("notes")

    // MARK: - Status

    enum Status: Equatable {
        case ready
        case directoryMissing
        case notWritable
        case notReadable
    }

    /// Current status of the output directory. Call `setup()` first.
    private(set) static var status: Status = .directoryMissing

    /// Human-readable description of the current issue, if any.
    static var issueDescription: String? {
        switch status {
        case .ready:
            return nil
        case .directoryMissing:
            return "~/mull directory could not be created. Context files will not be generated."
        case .notWritable:
            return "~/mull exists but is not writable. Check permissions: chmod u+rwx ~/mull"
        case .notReadable:
            return "~/mull exists but is not readable. Check permissions: chmod u+rwx ~/mull"
        }
    }

    // MARK: - Setup

    /// Create directory structure and validate permissions.
    /// Call once at app startup.
    @discardableResult
    static func setup() -> Status {
        let fm = FileManager.default

        // One-time migration from the pre-rename ~/Whatly location.
        // Preserves user-written notes/ and consolidated memory/ (me.md/now.md/full.md
        // regenerate on their own, but notes and memories do not).
        let legacyRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Whatly")
        if !fm.fileExists(atPath: root.path), fm.fileExists(atPath: legacyRoot.path) {
            do {
                try fm.moveItem(at: legacyRoot, to: root)
                logger.info("Migrated ~/Whatly → ~/mull")
            } catch {
                logger.error("Failed to migrate ~/Whatly → ~/mull: \(error.localizedDescription)")
            }
        }

        // Create root + subdirectories
        for dir in [root, daily, memory, notes] {
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    logger.error("Failed to create directory \(dir.path): \(error.localizedDescription)")
                    status = .directoryMissing
                    return status
                }
            }
        }

        // Check readable
        guard fm.isReadableFile(atPath: root.path) else {
            logger.error("~/mull is not readable")
            status = .notReadable
            return status
        }

        // Check writable with actual write test
        let testFile = root.appendingPathComponent(".mull-permission-test")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try fm.removeItem(at: testFile)
        } catch {
            logger.error("~/mull is not writable: \(error.localizedDescription)")
            status = .notWritable
            return status
        }

        // The vault root, entered by nobody but its owner. Applied on every setup
        // rather than only at creation: `createDirectory` uses the process umask
        // (0755 on a stock account), so vaults made by earlier builds are sitting
        // world-listable right now — and a listing of ~/mull is a list of the
        // user's projects and the days they worked, which is content, not metadata.
        // The root alone is enough: an unreadable directory cannot be traversed
        // into, so `daily/`, `notes/` and everything below inherit the answer.
        FilePrivacy.protectDirectory(at: root)

        // Heal files stamped .completeUnlessOpen by earlier builds — the stamp
        // can refuse reads (see FilePrivacy.protectFile), and files that are
        // never rewritten would otherwise carry it forever.
        FilePrivacy.stripLegacyProtection(under: root)

        logger.info("~/mull directory ready")
        status = .ready
        return status
    }

    // MARK: - Safe Write

    /// Write content to a file inside ~/mull, with pre-flight permission check.
    /// Returns `true` on success.
    @discardableResult
    static func write(_ content: String, to relativePath: String) -> Bool {
        guard status == .ready else {
            logger.warning("Skipping write to \(relativePath) — directory status: \(String(describing: status))")
            return false
        }

        let url = root.appendingPathComponent(relativePath)
        let dir = url.deletingLastPathComponent()

        do {
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            // Re-applied on every write, not once at creation: the atomic write
            // above replaces the file with a freshly created one, so whatever
            // permissions the previous inode carried are gone.
            FilePrivacy.protectFile(at: url)
            return true
        } catch {
            logger.error("Failed to write \(relativePath): \(error.localizedDescription)")
            // Re-check status in case permissions changed at runtime
            _ = setup()
            return false
        }
    }

    /// Read content from a file inside ~/mull.
    static func read(_ relativePath: String) -> String? {
        let url = root.appendingPathComponent(relativePath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Whether a file exists inside ~/mull. Used to scaffold user-owned files
    /// exactly once, without ever clobbering an existing one.
    static func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    /// Absolute URL for a path inside the vault. Prefer `read`/`write`; use this
    /// only where a URL is genuinely required (file coordination, NSWorkspace).
    static func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// Markdown files directly inside a vault subdirectory, as vault-relative
    /// paths, sorted. `index.md` is excluded: mull no longer writes one (DIRECTION
    /// §6.1), and one the user made is a table of contents rather than a document —
    /// callers here want the documents.
    static func markdownFiles(in relativeDir: String) -> [String] {
        let dir = root.appendingPathComponent(relativeDir, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".md") && $0 != "index.md" }
            .sorted()
            .map { "\(relativeDir)/\($0)" }
    }

    /// Every markdown file under a vault subdirectory, at any depth, as
    /// vault-relative paths, sorted.
    ///
    /// `markdownFiles(in:)` above deliberately reads one level, because the callers
    /// that browse a folder want its documents and not its subfolders' documents.
    /// `daily/` is the one place mull nests — `YYYY/MM/` — so the sweep that has to
    /// see all of it needs the other shape.
    static func markdownFilesRecursively(in relativeDir: String) -> [String] {
        let dir = root.appendingPathComponent(relativeDir, isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

        let prefix = root.standardizedFileURL.path + "/"
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "md" }
            .map { $0.standardizedFileURL.path }
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    /// Make a name safe to put on disk without rewriting what the user meant.
    ///
    /// Path separators become hyphens (a "/" sails through and quietly targets a
    /// folder that does not exist, so creation just fails), runs of whitespace become
    /// single hyphens, and leading dots are dropped (they would hide the file).
    /// Capitalisation is left alone: lowercasing turns "iOS-notes" into something
    /// nobody typed.
    ///
    /// The colon is the one that bites hardest on macOS, and it is why this lives in
    /// Core rather than in the Files tab where it started. `MullEngine` named memory
    /// files with `name.lowercased()` and a space→underscore swap and nothing else, so
    /// a memory called "Work rhythm: afternoons for editing" became
    /// `work_rhythm:_afternoons_for_editing.md` — and Finder shows a POSIX `:` as `/`,
    /// so mull and Finder displayed the same file under two different names. In a
    /// product whose promise is "it is just a folder of markdown you can open in
    /// anything", the name has to survive being looked at from outside.
    /// The separators become SPACES, not hyphens, and the existing whitespace pass
    /// then folds them away. Substituting a hyphen directly put two of them wherever a
    /// separator was followed by a space — "Work rhythm: afternoons" came out as
    /// `Work-rhythm--afternoons`, and a name of nothing but separators ("///") came out
    /// as `---`, which is not empty, so the caller's fallback never fired. Going
    /// through whitespace also leaves a hyphen the user typed themselves alone: only
    /// the ones this function introduces are collapsed.
    static func safeFileName(_ name: String) -> String {
        var value = name
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "：", with: " ")   // the full-width colon, same trap
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        while value.hasPrefix(".") { value.removeFirst() }
        return value
    }

    /// Delete one file inside ~/mull. Returns `true` if the file is gone
    /// afterwards (including when it was already absent).
    ///
    /// Nothing goes to the Trash: a file removed by the forget path is being
    /// removed *because* the user wants it gone, and a copy sitting in ~/.Trash
    /// would make the promise false.
    @discardableResult
    static func delete(_ relativePath: String) -> Bool {
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            logger.error("Failed to delete \(relativePath): \(error.localizedDescription)")
            return false
        }
    }

    /// Delete the entire vault. Only for the explicit "delete everything" action
    /// in Settings — everything else should delete a specific file.
    static func deleteEverything() throws {
        try FileManager.default.removeItem(at: root)
        status = .directoryMissing
    }
}
