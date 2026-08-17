import XCTest
@testable import mull

/// Tests for MullDirectory — file I/O safety layer.
final class MullDirectoryTests: XCTestCase {

    // MARK: - Setup

    func testSetupReturnsReady() {
        let status = MullDirectory.setup()
        XCTAssertEqual(status, .ready)
    }

    func testSetupCreatesSubdirectories() {
        _ = MullDirectory.setup()
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: MullDirectory.root.path))
        XCTAssertTrue(fm.fileExists(atPath: MullDirectory.daily.path))
        XCTAssertTrue(fm.fileExists(atPath: MullDirectory.memory.path))
        XCTAssertTrue(fm.fileExists(atPath: MullDirectory.notes.path))
    }

    // MARK: - Write & Read

    func testWriteAndRead() {
        _ = MullDirectory.setup()

        let content = "Test content \(Date())"
        let path = "test-\(UUID().uuidString).md"

        let success = MullDirectory.write(content, to: path)
        XCTAssertTrue(success)

        let read = MullDirectory.read(path)
        XCTAssertEqual(read, content)

        // Cleanup
        try? FileManager.default.removeItem(at: MullDirectory.root.appendingPathComponent(path))
    }

    func testWriteCreatesIntermediateDirectories() {
        _ = MullDirectory.setup()

        let subdir = "test-subdir-\(UUID().uuidString)"
        let path = "\(subdir)/nested.md"

        let success = MullDirectory.write("nested content", to: path)
        XCTAssertTrue(success)
        XCTAssertEqual(MullDirectory.read(path), "nested content")

        // Cleanup
        try? FileManager.default.removeItem(
            at: MullDirectory.root.appendingPathComponent(subdir)
        )
    }

    func testReadNonexistentFileReturnsNil() {
        XCTAssertNil(MullDirectory.read("nonexistent-\(UUID()).md"))
    }

    func testWriteOverwritesExistingFile() {
        _ = MullDirectory.setup()

        let path = "overwrite-test-\(UUID().uuidString).md"
        MullDirectory.write("first", to: path)
        MullDirectory.write("second", to: path)

        XCTAssertEqual(MullDirectory.read(path), "second")

        // Cleanup
        try? FileManager.default.removeItem(at: MullDirectory.root.appendingPathComponent(path))
    }

    // MARK: - Permissions

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    /// Files are 0600, which is what stops another account reading them — but the
    /// vault was created under the process umask, so the directory itself was 0755
    /// and any other user on the machine could list it. For ~/mull the listing IS
    /// content: project names, the days worked, `projects/<client>.md`.
    func testTheVaultRootIsOwnerOnly() throws {
        _ = MullDirectory.setup()
        XCTAssertEqual(try mode(of: MullDirectory.root), 0o700)
    }

    /// Applied on every setup, not only at creation — vaults made by earlier builds
    /// are sitting world-listable right now and have to be healed in place.
    func testAnExistingWorldReadableVaultIsLockedDownOnSetup() throws {
        _ = MullDirectory.setup()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: MullDirectory.root.path)

        _ = MullDirectory.setup()

        XCTAssertEqual(try mode(of: MullDirectory.root), 0o700)
    }

    /// An unreadable directory cannot be traversed into, so the root alone settles
    /// it for everything underneath — which is why `daily/` and `notes/` are not
    /// chased individually.
    func testFilesInTheVaultAreOwnerOnly() throws {
        _ = MullDirectory.setup()
        let path = "permissions-\(UUID().uuidString).md"
        XCTAssertTrue(MullDirectory.write("private", to: path))

        XCTAssertEqual(try mode(of: MullDirectory.url(for: path)), 0o600)

        try? FileManager.default.removeItem(at: MullDirectory.url(for: path))
    }

    // MARK: - Relocating the vault (`vaultPath`)

    /// A throwaway defaults domain, so setting the key never touches the real one.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "com.mull.tests.vaultPath.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// Normalised the same way `configuredRoot` normalises, so `/var` vs `/private/var`
    /// never decides a test.
    private func normalised(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mull-vaultpath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The test host must never be steered by a real `vaultPath`: `root` short-circuits
    /// to a throwaway directory before the preference is ever consulted. Asserted
    /// rather than assumed, because the whole suite writes through this path.
    func testTheTestVaultIsAlwaysAThrowawayDirectory() {
        XCTAssertTrue(MullDirectory.root.path.hasPrefix(
            normalised(FileManager.default.temporaryDirectory)))
        XCTAssertNotEqual(normalised(MullDirectory.root), normalised(MullDirectory.defaultRoot))
    }

    func testNoPreferenceMeansTheDefaultVault() {
        withDefaults { defaults in
            XCTAssertNil(MullDirectory.configuredRoot(defaults: defaults))
        }
    }

    func testAnAbsolutePathUnderAnExistingParentIsHonoured() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("mull", isDirectory: true)

        withDefaults { defaults in
            defaults.set(target.path, forKey: MullDirectory.pathPreferenceKey)
            XCTAssertEqual(MullDirectory.configuredRoot(defaults: defaults).map(normalised),
                           normalised(target))
        }
    }

    func testATildePathIsExpanded() {
        withDefaults { defaults in
            defaults.set("~/mull-vaultpath-tilde", forKey: MullDirectory.pathPreferenceKey)
            XCTAssertEqual(MullDirectory.configuredRoot(defaults: defaults).map(normalised),
                           normalised(FileManager.default.homeDirectoryForCurrentUser
                               .appendingPathComponent("mull-vaultpath-tilde")))
        }
    }

    func testARelativePathIsRefused() {
        withDefaults { defaults in
            defaults.set("mull", forKey: MullDirectory.pathPreferenceKey)
            XCTAssertNil(MullDirectory.configuredRoot(defaults: defaults))
        }
    }

    /// The reason this resolves at the root rather than following the link later:
    /// `FileManager`'s enumerator hands back physical paths, so a symlinked root made
    /// `markdownFilesRecursively` filter away every file it had just found.
    func testASymlinkedPathIsResolvedToItsTarget() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let real = parent.appendingPathComponent("real", isDirectory: true)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        withDefaults { defaults in
            defaults.set(link.path, forKey: MullDirectory.pathPreferenceKey)
            XCTAssertEqual(MullDirectory.configuredRoot(defaults: defaults).map(normalised),
                           normalised(real))
        }
    }

    /// `setup()` chmods the root to 0700 and `deleteEverything()` removes it whole, so
    /// a root at or above home would turn "delete everything" into deleting the account.
    func testHomeAndItsAncestorsAreRefused() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for candidate in [home.path, home.deletingLastPathComponent().path, "/", "~"] {
            withDefaults { defaults in
                defaults.set(candidate, forKey: MullDirectory.pathPreferenceKey)
                XCTAssertNil(MullDirectory.configuredRoot(defaults: defaults),
                             "\(candidate) must not be usable as a vault root")
            }
        }
    }

    /// What a typo looks like, and also what an iCloud Drive that is not set up on
    /// this Mac looks like. Falling back beats building a vault nobody meant.
    func testAPathWhoseParentIsMissingIsRefused() {
        withDefaults { defaults in
            defaults.set("/nonexistent-\(UUID().uuidString)/mull",
                         forKey: MullDirectory.pathPreferenceKey)
            XCTAssertNil(MullDirectory.configuredRoot(defaults: defaults))
        }
    }

    /// The other half of the symlink fix: the recursive sweep normalises both sides,
    /// so it still reports vault-relative paths rather than an empty list.
    func testTheRecursiveSweepReportsVaultRelativePaths() throws {
        _ = MullDirectory.setup()
        let dir = "sweep-\(UUID().uuidString)"
        XCTAssertTrue(MullDirectory.write("x", to: "\(dir)/2026/08/17.md"))
        defer { try? FileManager.default.removeItem(at: MullDirectory.url(for: dir)) }

        XCTAssertEqual(MullDirectory.markdownFilesRecursively(in: dir),
                       ["\(dir)/2026/08/17.md"])
    }
}
