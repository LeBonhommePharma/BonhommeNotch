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
        XCTAssertEqual(snap.rankedSessionIDs.first, "a")
        XCTAssertEqual(snap.rankedBadges.first, "needs you")
    }
}
