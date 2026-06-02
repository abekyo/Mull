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
}
