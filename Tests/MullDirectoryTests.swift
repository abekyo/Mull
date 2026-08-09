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
}
