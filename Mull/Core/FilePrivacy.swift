import Foundation
import os.log

private let logger = Logger(subsystem: "com.mull.app", category: "FilePrivacy")

/// Locks down the on-disk permissions of the two stores that hold everything
/// mull knows: the SQLite database and the ~/mull vault.
///
/// Both were created under the process umask, which on a stock macOS account is
/// 022 — so mull.sqlite (every keystroke the user has ever typed, in plaintext)
/// and ~/mull/me.md landed group- and world-readable. Any other user account, and
/// any unsandboxed process running as another uid, could read them. Full
/// at-rest encryption (SQLCipher) is a dependency decision; this is the floor
/// beneath it: owner-only mode bits plus Data Protection where the platform
/// offers it.
///
/// Every call is best-effort and silent on failure. Locking permissions is a
/// hardening measure, not a precondition — a vault on a filesystem that does not
/// carry POSIX modes (an exFAT volume, a network mount) must still start the app.
enum FilePrivacy {

    /// Owner read/write, nothing for group or other.
    private static let ownerOnly = NSNumber(value: Int16(0o600))

    /// Apply owner-only permissions and file protection to a single file.
    ///
    /// Call this AFTER each write, not once at creation: `write(to:atomically:)`
    /// writes a temp file and renames it over the target, so the protected inode
    /// is replaced by a fresh umask-default one on every save.
    static func protectFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var attributes: [FileAttributeKey: Any] = [.posixPermissions: ownerOnly]
        // .completeUnlessOpen is a no-op on Macs without Data Protection, and
        // setting it is rejected outright on some volumes — hence its own
        // attempt below rather than riding along with the mode bits, which
        // matter more and must not be lost to an unrelated rejection.
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        } catch {
            logger.error("Could not set 0600 on \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
        }

        attributes = [.protectionKey: FileProtectionType.completeUnlessOpen]
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    /// Protect a SQLite database and the sidecars GRDB creates beside it.
    ///
    /// The `-wal` file is the one that actually matters day to day: in WAL mode
    /// the newest events live there, unmerged, for as long as the app is running.
    /// Protecting only mull.sqlite would leave the most recent keystrokes readable.
    /// The sidecars are created lazily by SQLite, so this is called after the pool
    /// is open and the first read has run.
    static func protectDatabase(atPath path: String) {
        for suffix in ["", "-wal", "-shm"] {
            protectFile(at: URL(fileURLWithPath: path + suffix))
        }
    }
}
