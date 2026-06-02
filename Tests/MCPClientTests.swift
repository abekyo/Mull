import XCTest
@testable import mull

/// Tests for the MCP client's pure framing/parsing + connector mapping. The
/// subprocess transport is integration-only (needs a real server) and is not
/// unit-tested here.
final class MCPClientTests: XCTestCase {

    func testEncodeRequestIsNewlineTerminatedJSONRPC() {
        let data = MCPClient.encodeRequest(id: 7, method: "tools/list", params: [:])
        XCTAssertEqual(data.last, 0x0A) // newline-delimited framing

        let line = String(data: data.dropLast(), encoding: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj["id"] as? Int, 7)
        XCTAssertEqual(obj["method"] as? String, "tools/list")
        XCTAssertNil(obj["params"]) // empty params omitted
    }

    func testParseToolTextConcatenatesTextContent() {
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": "hello"],
                ["type": "text", "text": "world"],
            ]
        ]
        XCTAssertEqual(MCPClient.parseToolText(from: result), "hello\nworld")
    }

    func testMapItemsParsesJSONArray() {
        let json = """
        [{"id":"m1","title":"Standup","summary":"daily sync"},
         {"subject":"Invoice","snippet":"due Friday"}]
        """
        let items = MCPConnector.mapItems(json, source: "gmail")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "m1")
        XCTAssertEqual(items[0].title, "Standup")
        XCTAssertEqual(items[1].title, "Invoice")     // falls back to "subject"
        XCTAssertEqual(items[1].summary, "due Friday") // falls back to "snippet"
        XCTAssertEqual(items[1].source, "gmail")
    }

    func testMapItemsFallsBackToSingleItemForPlainText() {
        let items = MCPConnector.mapItems("just some text", source: "notion")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].source, "notion")
        XCTAssertEqual(items[0].summary, "just some text")
    }

    func testMapItemsEmptyForBlankText() {
        XCTAssertTrue(MCPConnector.mapItems("   \n ", source: "x").isEmpty)
    }
}
