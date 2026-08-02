import Foundation
import BonhommeNotchCore
import Darwin

/// In-process self-test: real SocketBridge + NDJSON inject + gate reply assertions.
enum SocketSelfTest {
    static func run() -> Int {
        // macOS AF_UNIX path limit is ~104 bytes — keep socket path short.
        let shortID = String(UUID().uuidString.prefix(8))
        let tmp = URL(fileURLWithPath: "/tmp/bn-\(shortID)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let sock = tmp.appendingPathComponent("n.sock").path
        let status = tmp.appendingPathComponent("status.json").path
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = SessionStore()
        let bridge = SocketBridge(store: store, socketPath: sock, statusPath: status)
        // Short gate timeout for tests that expect fail-open — we approve actively.
        bridge.defaultGateTimeout = 30
        do {
            try bridge.start()
        } catch {
            fputs("FAIL: bridge start \(error)\n", stderr)
            return 1
        }
        defer { bridge.stop() }

        // Give accept loop a moment.
        Thread.sleep(forTimeInterval: 0.05)

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                print("PASS \(name)")
            } else {
                print("FAIL \(name) \(detail)")
                failures += 1
            }
        }

        // 1) Working session (cursor)
        sendFireAndForget(sock: sock, json: """
        {"v":1,"source":"cursor","session_id":"sess-cursor-1","action":"start","cwd":"/Users/demo/proj-a","model":"gpt-5"}
        """)
        sendFireAndForget(sock: sock, json: """
        {"v":1,"source":"cursor","session_id":"sess-cursor-1","action":"activity","status":"shell","title":"Running tests"}
        """)

        // 2) Needs-you pending (cursor observe)
        sendFireAndForget(sock: sock, json: """
        {"v":1,"source":"cursor","session_id":"sess-cursor-2","action":"pending","kind":"shell","command":"rm -rf /tmp/x","cwd":"/Users/demo/proj-b"}
        """)

        // 3) Claude working then gate
        sendFireAndForget(sock: sock, json: """
        {"v":1,"source":"claude","session_id":"sess-claude-1","action":"start","cwd":"/Users/demo/proj-c"}
        """)
        sendFireAndForget(sock: sock, json: """
        {"v":1,"source":"claude","session_id":"sess-claude-1","action":"busy","tool_name":"Bash","detail":"npm test"}
        """)

        Thread.sleep(forTimeInterval: 0.15)
        var ranked = store.ranked()
        check("multi-session count >= 3", ranked.count >= 3, "count=\(ranked.count)")
        check("needs-you ranks first", ranked.first?.attention == .needsYou, ranked.first.map { $0.focusLine } ?? "nil")
        check("primary is cursor pending", ranked.first?.sessionID == "sess-cursor-2", ranked.first?.sessionID ?? "")

        // 4) Blocking Claude gate — approve on another queue
        let toolInput: [String: Any] = ["command": "npm test", "description": "run tests"]
        let gateLineObj: [String: Any] = [
            "v": 1,
            "source": "claude",
            "session_id": "sess-claude-1",
            "action": "gate",
            "tool_name": "Bash",
            "detail": "npm test",
            "tool_input": toolInput
        ]
        let gateData = try! JSONSerialization.data(withJSONObject: gateLineObj)
        let gateLine = String(data: gateData, encoding: .utf8)!

        let gateResult = LockedBox<String?>(nil)
        let gateDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let reply = sendAndWait(sock: sock, json: gateLine, timeout: 10)
            gateResult.value = reply
            gateDone.signal()
        }

        // Wait until gate is registered
        var waited = 0
        while store.session(id: "sess-claude-1")?.gateWaiting != true && waited < 50 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 1
        }
        check("claude gate waiting", store.session(id: "sess-claude-1")?.gateWaiting == true)

        ranked = store.ranked()
        check("after gate, needs-you still first", ranked.first?.attention == .needsYou)

        let approved = bridge.approve(sessionID: "sess-claude-1")
        check("approve returned true", approved)

        _ = gateDone.wait(timeout: .now() + 5)
        let reply = gateResult.value ?? ""
        check("gate reply non-empty", !reply.isEmpty, reply)
        if let data = reply.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            check("allow behavior", obj["behavior"] as? String == "allow", "\(obj)")
            let updated = obj["updatedInput"] as? [String: Any]
            check("claude allow has updatedInput", updated != nil)
            check("updatedInput.command", updated?["command"] as? String == "npm test", "\(String(describing: updated))")
        } else {
            check("gate reply parseable JSON", false, reply)
        }

        // 5) Codex deny shape
        sendFireAndForget(sock: sock, json: """
        {"v":1,"source":"codex","session_id":"sess-codex-1","action":"start","cwd":"/Users/demo/api"}
        """)
        let codexGate = """
        {"v":1,"source":"codex","session_id":"sess-codex-1","action":"gate","tool_name":"shell","detail":"curl evil","reason":"network"}
        """
        let codexBox = LockedBox<String?>(nil)
        let codexDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            codexBox.value = sendAndWait(sock: sock, json: codexGate, timeout: 10)
            codexDone.signal()
        }
        waited = 0
        while store.session(id: "sess-codex-1")?.gateWaiting != true && waited < 50 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 1
        }
        let denied = bridge.deny(sessionID: "sess-codex-1")
        check("deny returned true", denied)
        _ = codexDone.wait(timeout: .now() + 5)
        let codexReply = codexBox.value ?? ""
        if let data = codexReply.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            check("codex deny behavior", obj["behavior"] as? String == "deny")
            check("codex deny message", (obj["message"] as? String)?.contains("Denied") == true, "\(obj)")
            check("codex deny no updatedInput", obj["updatedInput"] == nil)
        } else {
            check("codex reply parseable", false, codexReply)
        }

        // 6) Status file non-empty roster
        bridge.writeStatus()
        do {
            let snap = try StatusSnapshot.load(from: status)
            check("status sessionCount > 0", snap.sessionCount > 0, "\(snap.sessionCount)")
            check("status primary non-empty", !snap.primaryFocusLine.isEmpty)
            check("status ranked IDs non-empty", !snap.rankedSessionIDs.isEmpty)
            print("STATUS \(snap.primaryFocusLine)")
            print("RANKED \(snap.rankedSessionIDs.joined(separator: ","))")
            print("BADGES \(snap.rankedBadges.joined(separator: ","))")
        } catch {
            check("status load", false, "\(error)")
        }

        // 7) Cursor gate must not block — passthrough reply quickly
        let cursorGateStart = Date()
        let cursorReply = sendAndWait(sock: sock, json: """
        {"v":1,"source":"cursor","session_id":"sess-cursor-3","action":"gate","detail":"should not block"}
        """, timeout: 3)
        let cursorElapsed = Date().timeIntervalSince(cursorGateStart)
        check("cursor gate returns quickly", cursorElapsed < 2.5, "elapsed=\(cursorElapsed)")
        // passthrough or empty both OK for fail-open; if JSON, behavior passthrough
        if let data = cursorReply?.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            check("cursor gate not allow/deny freeze", obj["behavior"] as? String == "passthrough" || obj["behavior"] as? String == nil, "\(obj)")
        } else {
            check("cursor gate fail-open empty or passthrough", true)
        }

        // 8) Multi-line same connection (Cursor bridge batches pending + activity).
        // Write line A, sleep so a buggy server would close after first \n, then line B.
        let multiOK = sendMultiLineSameConnection(
            sock: sock,
            lines: [
                #"{"v":1,"source":"cursor","session_id":"sess-multi","action":"pending","command":"rm -rf /tmp/x","cwd":"/Users/demo/multi"}"#,
                #"{"v":1,"source":"cursor","session_id":"sess-multi","action":"activity","status":"shell","title":"Running: rm -rf /tmp/x"}"#
            ],
            interLineSleep: 0.15
        )
        check("multi-line same connection send OK", multiOK)
        Thread.sleep(forTimeInterval: 0.1)
        let multi = store.session(id: "sess-multi")
        check("multi-line first msg applied (pending/needs-you)", multi?.attention == .needsYou, multi.map { $0.attention.badge } ?? "nil")
        check("multi-line second msg applied (activity title)", multi?.activityTitle == "Running: rm -rf /tmp/x", multi?.activityTitle ?? "nil")
        check("multi-line session present after split writes", multi != nil)

        // 9) Multi-line batch write (single sendall of two lines) — Cursor shape.
        let batchPayload = [
            #"{"v":1,"source":"cursor","session_id":"sess-batch","action":"pending","command":"git push","cwd":"/Users/demo/batch"}"#,
            #"{"v":1,"source":"cursor","session_id":"sess-batch","action":"activity","status":"shell","title":"Running: git push"}"#
        ].map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined()
        let batchOK = sendRaw(sock: sock, payload: batchPayload, closeAfter: true)
        check("multi-line batch sendall OK", batchOK)
        Thread.sleep(forTimeInterval: 0.1)
        let batch = store.session(id: "sess-batch")
        check("batch first+second applied", batch?.attention == .needsYou && batch?.activityTitle == "Running: git push",
              batch.map { "\($0.attention.badge)/\($0.activityTitle ?? "")" } ?? "nil")

        if failures == 0 {
            print("SOCKET SELFTEST OK")
            return 0
        }
        print("SOCKET SELFTEST FAILURES=\(failures)")
        return 1
    }

    /// Cursor-style: one AF_UNIX connection, write line A, pause, write line B, then close.
    /// A server that stops reading after the first newline will drop B (BrokenPipe / never apply).
    private static func sendMultiLineSameConnection(sock: String, lines: [String], interLineSleep: TimeInterval) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard connectUnix(fd: fd, path: sock) else { return false }
        for (i, line) in lines.enumerated() {
            var payload = line
            if !payload.hasSuffix("\n") { payload += "\n" }
            let data = payload.data(using: .utf8)!
            let wrote = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return write(fd, base, data.count)
            }
            if wrote < 0 { return false }
            if i + 1 < lines.count {
                Thread.sleep(forTimeInterval: interLineSleep)
            }
        }
        return true
    }

    private static func sendRaw(sock: String, payload: String, closeAfter: Bool) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { if closeAfter { close(fd) } else { close(fd) } }
        guard connectUnix(fd: fd, path: sock) else { return false }
        let data = payload.data(using: .utf8)!
        let wrote = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return write(fd, base, data.count)
        }
        return wrote >= 0
    }

    private static func connectUnix(fd: Int32, path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cptr in
                for (i, b) in pathBytes.enumerated() { cptr[i] = b }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        } == 0
    }

    private static func sendFireAndForget(sock: String, json: String) {
        _ = sendAndWait(sock: sock, json: json, timeout: 0.5, waitForReply: false)
    }

    private static func sendAndWait(sock: String, json: String, timeout: TimeInterval, waitForReply: Bool = true) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connectUnix(fd: fd, path: sock) else { return nil }

        var payload = json
        if !payload.hasSuffix("\n") { payload += "\n" }
        let data = payload.data(using: .utf8)!
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                _ = write(fd, base, data.count)
            }
        }

        if !waitForReply {
            return nil
        }

        // Set receive timeout
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buf, buf.count)
        if n <= 0 { return nil }
        return String(bytes: buf[0..<n], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
