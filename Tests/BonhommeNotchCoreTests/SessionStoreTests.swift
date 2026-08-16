import XCTest
@testable import BonhommeNotchCore

final class SessionStoreTests: XCTestCase {
    func testNeedsYouRanksAboveWorking() throws {
        let store = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1_000)
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"work","action":"start","cwd":"/a"}"#
        ), now: t0)
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"cursor","session_id":"need","action":"pending","command":"rm","cwd":"/b"}"#
        ), now: t0.addingTimeInterval(1))

        let ranked = store.ranked()
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].sessionID, "need")
        XCTAssertEqual(ranked[0].attention, .needsYou)
        XCTAssertEqual(ranked[1].sessionID, "work")
        XCTAssertEqual(ranked[1].attention, .working)
        XCTAssertTrue(store.primaryFocusLine.contains("needs you"))
    }

    func testGateQuestionPlanAllNeedsYou() throws {
        let store = SessionStore()
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"g","action":"gate","tool_name":"Bash","detail":"ls"}"#
        ))
        store.apply(try HookProtocol.parse(
            "{\"v\":1,\"source\":\"claude\",\"session_id\":\"q\",\"action\":\"marker\",\"kind\":\"question\",\"detail\":\"Which?\"}"
        ))
        store.apply(try HookProtocol.parse(
            "{\"v\":1,\"source\":\"claude\",\"session_id\":\"p\",\"action\":\"marker\",\"kind\":\"plan\",\"detail\":\"Exit plan\"}"
        ))
        store.apply(try HookProtocol.parse(
            "{\"v\":1,\"source\":\"codex\",\"session_id\":\"w\",\"action\":\"start\"}"
        ))

        let ranked = store.ranked()
        XCTAssertEqual(ranked.filter { $0.attention == .needsYou }.count, 3)
        XCTAssertEqual(ranked.last?.sessionID, "w")
        XCTAssertEqual(ranked.last?.attention, .working)
    }

    func testStartBusyDoneLifecycle() throws {
        let store = SessionStore()
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"s1","action":"start","cwd":"/proj"}"#
        ))
        XCTAssertEqual(store.session(id: "s1")?.attention, .working)

        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"s1","action":"busy","tool_name":"Read","detail":"a.swift"}"#
        ))
        XCTAssertEqual(store.session(id: "s1")?.attention, .working)
        XCTAssertEqual(store.session(id: "s1")?.activityTitle, "a.swift")

        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"s1","action":"done"}"#
        ))
        XCTAssertEqual(store.session(id: "s1")?.attention, .finished)
    }

    func testPendingClearReturnsToWorking() throws {
        let store = SessionStore()
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"cursor","session_id":"c","action":"pending","command":"git push"}"#
        ))
        XCTAssertEqual(store.session(id: "c")?.attention, .needsYou)
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"cursor","session_id":"c","action":"pending-clear"}"#
        ))
        XCTAssertEqual(store.session(id: "c")?.attention, .working)
        XCTAssertNil(store.session(id: "c")?.needsYouKind)
    }

    func testStatusSnapshotFromStore() throws {
        let store = SessionStore()
        store.apply(try HookProtocol.parse(
            "{\"v\":1,\"source\":\"claude\",\"session_id\":\"a\",\"action\":\"marker\",\"kind\":\"question\",\"detail\":\"OK?\"}"
        ))
        store.apply(try HookProtocol.parse(
            "{\"v\":1,\"source\":\"codex\",\"session_id\":\"b\",\"action\":\"start\"}"
        ))
        let snap = StatusSnapshot.from(store: store)
        XCTAssertEqual(snap.sessionCount, 2)
        XCTAssertEqual(snap.needsYouCount, 1)
        XCTAssertEqual(snap.workingCount, 1)
        XCTAssertFalse(snap.primaryFocusLine.isEmpty)
        XCTAssertEqual(snap.rankedSessionIDs.first, "claude:a")
        XCTAssertEqual(snap.rankedBadges.first, "needs you")
    }

    func testCrossSourceSessionIDsDoNotCollide() throws {
        let store = SessionStore()
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"same","action":"start","cwd":"/claude"}"#
        ))
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"cursor","session_id":"same","action":"pending","command":"rm","cwd":"/cursor"}"#
        ))
        XCTAssertEqual(store.count, 2)
        XCTAssertNil(store.session(id: "same"))
        XCTAssertEqual(store.session(source: .claude, sessionID: "same")?.cwd, "/claude")
        XCTAssertEqual(store.session(source: .cursor, sessionID: "same")?.attention, .needsYou)
        XCTAssertEqual(store.session(id: "claude:same")?.source, .claude)
        XCTAssertEqual(store.session(id: "cursor:same")?.source, .cursor)
        let ranked = store.ranked()
        XCTAssertEqual(ranked.first?.id, "cursor:same")
        XCTAssertEqual(Set(ranked.map(\.id)), ["claude:same", "cursor:same"])
    }

    func testClearResetsStaleFields() throws {
        let store = SessionStore()
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"s","action":"gate","tool_name":"Bash","detail":"ls","reason":"network"}"#
        ))
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"s","action":"activity","title":"Working on ls"}"#
        ))
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"s","action":"clear"}"#
        ))
        let s = store.session(id: "s")
        XCTAssertEqual(s?.attention, .working)
        XCTAssertNil(s?.needsYouKind)
        XCTAssertNil(s?.detail)
        XCTAssertNil(s?.options)
        XCTAssertNil(s?.activityTitle)
        XCTAssertNil(s?.reason)
        XCTAssertNil(s?.toolName)
        XCTAssertFalse(s?.gateWaiting ?? true)
    }

    func testActivityDoesNotClobberToolName() throws {
        let store = SessionStore()
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"s","action":"busy","tool_name":"Bash","detail":"npm test"}"#
        ))
        XCTAssertEqual(store.session(id: "s")?.toolName, "Bash")
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"s","action":"activity","status":"shell","title":"Running tests"}"#
        ))
        XCTAssertEqual(store.session(id: "s")?.toolName, "Bash")
        XCTAssertEqual(store.session(id: "s")?.activityTitle, "Running tests")
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"s","action":"activity","status":"running"}"#
        ))
        XCTAssertEqual(store.session(id: "s")?.toolName, "Bash")
        XCTAssertEqual(store.session(id: "s")?.activityTitle, "running")
    }

    func testFocusLineClipsToEightyCharacters() throws {
        let store = SessionStore()
        let long = String(repeating: "x", count: 200)
        let lineJSON = "{\"v\":1,\"source\":\"claude\",\"session_id\":\"clip\",\"action\":\"busy\",\"detail\":\"\(long)\",\"cwd\":\"/p\"}"
        store.apply(try HookProtocol.parse(lineJSON))
        let focus = store.session(id: "clip")!.focusLine
        let clipped = focus.components(separatedBy: " · ").last!
        XCTAssertEqual(clipped.count, 80)
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    func testReleaseGateWaiterKeepsNeedsYou() throws {
        let store = SessionStore()
        store.apply(try HookProtocol.parse(
            #"{"v":1,"source":"claude","session_id":"g","action":"gate","tool_name":"Bash","detail":"ls"}"#
        ))
        XCTAssertEqual(store.session(id: "g")?.attention, .needsYou)
        XCTAssertEqual(store.session(id: "g")?.gateWaiting, true)
        store.releaseGateWaiter(source: .claude, sessionID: "g")
        let s = store.session(id: "g")
        XCTAssertEqual(s?.attention, .needsYou)
        XCTAssertEqual(s?.needsYouKind, .gate)
        XCTAssertEqual(s?.gateWaiting, false)
        store.resolveGate(source: .claude, sessionID: "g")
        XCTAssertEqual(store.session(id: "g")?.attention, .working)
        XCTAssertNil(store.session(id: "g")?.needsYouKind)
    }
}
