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

    /// Apply owner-only permissions to a single file.
    ///
    /// Call this AFTER each write, not once at creation: `write(to:atomically:)`
    /// writes a temp file and renames it over the target, so the protected inode
    /// is replaced by a fresh umask-default one on every save.
    ///
    /// Deliberately NOT `.protectionKey`: this used to also stamp
    /// `.completeUnlessOpen`, whose class-B semantics (writable any time,
    /// re-openable only while unlocked) meant a file written here could later
    /// fail to open with EPERM — observed as read-after-write returning nil in
    /// unattended test runs, and once on the real me.md. mull is a daemon that
    /// reads its own vault around the clock, so a class that can refuse reads
    /// is worse than no class at all. At-rest encryption is FileVault's job;
    /// other-account access is what the 0600 mode bits are for.
    static func protectFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: ownerOnly], ofItemAtPath: url.path)
        } catch {
            logger.error("Could not set 0600 on \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
        }

        stripLegacyProtection(at: url)
    }

    /// Remove the `.completeUnlessOpen` stamp left by earlier builds, if present.
    ///
    /// Routine rewrites shed it on their own — the atomic write creates a fresh
    /// inode — but the files nothing rewrites (me.pinned.md, daily snapshots,
    /// kept reports, memory files, the sqlite file itself) would carry the
    /// read-refusal risk forever without this.
    static func stripLegacyProtection(at url: URL) {
        let raw = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey]
        let current = (raw as? FileProtectionType)?.rawValue ?? (raw as? String)
        guard let current, current != FileProtectionType.none.rawValue else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
    }

    /// One-shot repair pass over a directory tree. Called from
    /// `MullDirectory.setup()` so files that are only ever *read* — the ones the
    /// per-write path above never touches — get healed too.
    static func stripLegacyProtection(under root: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            stripLegacyProtection(at: url)
        }
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
