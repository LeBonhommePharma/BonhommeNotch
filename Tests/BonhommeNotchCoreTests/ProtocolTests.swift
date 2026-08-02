import XCTest
@testable import BonhommeNotchCore

final class ProtocolTests: XCTestCase {
    func testParseClaudeStart() throws {
        let line = #"{"v":1,"source":"claude","session_id":"abc-123","action":"start","cwd":"/tmp/proj"}"#
        let msg = try HookProtocol.parse(line)
        XCTAssertEqual(msg.v, 1)
        XCTAssertEqual(msg.source, .claude)
        XCTAssertEqual(msg.sessionID, "abc-123")
        XCTAssertEqual(msg.action, .start)
        XCTAssertEqual(msg.cwd, "/tmp/proj")
    }

    func testParseCursorPending() throws {
        let line = #"{"v":1,"source":"cursor","session_id":"c1","action":"pending","kind":"shell","command":"ls","model":"gpt-5"}"#
        let msg = try HookProtocol.parse(line)
        XCTAssertEqual(msg.source, .cursor)
        XCTAssertEqual(msg.action, .pending)
        XCTAssertEqual(msg.command, "ls")
        XCTAssertEqual(msg.model, "gpt-5")
    }

    func testParseGateWithToolInput() throws {
        let line = #"{"v":1,"source":"claude","session_id":"s","action":"gate","tool_name":"Bash","tool_input":{"command":"echo hi"}}"#
        let msg = try HookProtocol.parse(line)
        XCTAssertEqual(msg.action, .gate)
        XCTAssertEqual(msg.toolName, "Bash")
        XCTAssertEqual(msg.toolInput?["command"]?.value as? String, "echo hi")
    }

    func testParsePendingClearAction() throws {
        let line = #"{"v":1,"source":"cursor","session_id":"s","action":"pending-clear"}"#
        let msg = try HookProtocol.parse(line)
        XCTAssertEqual(msg.action, .pendingClear)
    }

    func testMissingSessionIDThrows() {
        XCTAssertThrowsError(try HookProtocol.parse(#"{"v":1,"source":"claude","action":"start"}"#)) { err in
            XCTAssertEqual(err as? ProtocolError, .missingSessionID)
        }
    }

    func testEncodeRoundTrip() throws {
        let original = HookMessage(
            source: .codex,
            sessionID: "sess",
            action: .busy,
            cwd: "/w",
            toolName: "shell",
            detail: "pwd"
        )
        let line = try HookProtocol.encodeLine(original)
        let parsed = try HookProtocol.parse(line)
        XCTAssertEqual(parsed.source, .codex)
        XCTAssertEqual(parsed.sessionID, "sess")
        XCTAssertEqual(parsed.action, .busy)
        XCTAssertEqual(parsed.detail, "pwd")
    }
}
