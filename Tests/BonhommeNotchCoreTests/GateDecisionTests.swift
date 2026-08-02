import XCTest
@testable import BonhommeNotchCore

final class GateDecisionTests: XCTestCase {
    func testClaudeAllowCarriesUpdatedInput() throws {
        let input: [String: Any] = ["command": "npm test", "description": "tests"]
        let d = GateDecisionBuilder.allow(source: .claude, toolInput: input)
        XCTAssertEqual(d.behavior, .allow)
        XCTAssertEqual(d.updatedInput?["command"] as? String, "npm test")
        let line = try d.socketJSONLine()
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(obj["behavior"] as? String, "allow")
        let updated = obj["updatedInput"] as? [String: Any]
        XCTAssertEqual(updated?["command"] as? String, "npm test")
    }

    func testClaudeDenyCarriesMessage() throws {
        let d = GateDecisionBuilder.deny(source: .claude)
        XCTAssertEqual(d.behavior, .deny)
        XCTAssertEqual(d.message, "Denied from BonhommeNotch")
        let obj = try JSONSerialization.jsonObject(with: Data(try d.socketJSONLine().utf8)) as! [String: Any]
        XCTAssertEqual(obj["behavior"] as? String, "deny")
        XCTAssertEqual(obj["message"] as? String, "Denied from BonhommeNotch")
        XCTAssertNil(obj["updatedInput"])
    }

    func testCodexAllowOmitsUpdatedInput() throws {
        let d = GateDecisionBuilder.allow(source: .codex, toolInput: ["command": "x"])
        XCTAssertEqual(d.behavior, .allow)
        XCTAssertNil(d.updatedInput)
        let obj = try JSONSerialization.jsonObject(with: Data(try d.socketJSONLine().utf8)) as! [String: Any]
        XCTAssertEqual(obj["behavior"] as? String, "allow")
        XCTAssertNil(obj["updatedInput"])
    }

    func testCodexDenyMessage() throws {
        let d = GateDecisionBuilder.deny(source: .codex, message: "Denied from BonhommeNotch")
        let obj = try JSONSerialization.jsonObject(with: Data(try d.socketJSONLine().utf8)) as! [String: Any]
        XCTAssertEqual(obj["behavior"] as? String, "deny")
        XCTAssertEqual(obj["message"] as? String, "Denied from BonhommeNotch")
    }

    func testCursorIsObserveOnly() {
        XCTAssertFalse(GateDecisionBuilder.supportsBlockingGate(.cursor))
        XCTAssertTrue(GateDecisionBuilder.supportsBlockingGate(.claude))
        XCTAssertTrue(GateDecisionBuilder.supportsBlockingGate(.codex))
        let allow = GateDecisionBuilder.allow(source: .cursor, toolInput: nil)
        XCTAssertEqual(allow.behavior, .passthrough)
        let deny = GateDecisionBuilder.deny(source: .cursor)
        XCTAssertEqual(deny.behavior, .passthrough)
    }

    func testClaudeHookStdoutWrapper() throws {
        let d = GateDecisionBuilder.allow(source: .claude, toolInput: ["command": "echo"])
        let out = try GateDecisionBuilder.claudeHookStdout(decision: d)
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        let hook = obj["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hook["hookEventName"] as? String, "PermissionRequest")
        let decision = hook["decision"] as! [String: Any]
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNotNil(decision["updatedInput"])
    }

    func testCodexHookStdoutWrapper() throws {
        let d = GateDecisionBuilder.deny(source: .codex)
        let out = try GateDecisionBuilder.codexHookStdout(decision: d)
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        XCTAssertEqual(obj["continue"] as? Bool, true)
        let hook = obj["hookSpecificOutput"] as! [String: Any]
        let decision = hook["decision"] as! [String: Any]
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertNotNil(decision["message"])
        XCTAssertNil(decision["updatedInput"])
    }
}
