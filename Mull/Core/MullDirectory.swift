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
    /// run — and it calls `setup()` and `FolderOntology.scaffold()`, which were
    /// rewriting the eight `*/index.md` files in the user's REAL vault every
    /// time anyone ran the suite. Tests must never mutate real user data.
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }()

    /// Root directory: ~/mull — or a throwaway directory under XCTest.
    ///
    /// Redirecting the root (rather than guarding each writer) means every path
    /// into the vault is covered at once: Curator, FolderOntology, FolderFiller,
    /// RawStore, and the MCP write tools. It also makes those write paths safely
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
    /// paths, sorted. `index.md` is excluded — it is folder scaffolding written
    /// by FolderOntology, not content.
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
