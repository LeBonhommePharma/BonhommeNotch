import Foundation
import BonhommeNotchCore
import Darwin

/// Unix-domain socket server: NDJSON in, optional gate reply out.
public final class SocketBridge: @unchecked Sendable {
    public let store: SessionStore
    public let socketPath: String
    public var statusPath: String
    public var defaultGateTimeout: TimeInterval = 1795

    private var listenFD: Int32 = -1
    private var acceptQueue: DispatchQueue?
    private var isRunning = false
    private let gateLock = NSLock()
    /// sessionID → waiter for blocking gate.
    private var gateWaiters: [String: GateWaiter] = [:]

    public init(store: SessionStore, socketPath: String? = nil, statusPath: String? = nil) {
        self.store = store
        self.socketPath = socketPath ?? BonhommePaths.socketPath()
        self.statusPath = statusPath ?? BonhommePaths.statusPath()
    }

    public func start() throws {
        guard !isRunning else { return }
        try prepareSocketPath()
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw SocketError.createFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cptr in
                for (i, b) in pathBytes.enumerated() {
                    cptr[i] = b
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(listenFD, sp, addrLen)
            }
        }
        guard bindResult == 0 else { throw SocketError.bindFailed(errno) }
        guard listen(listenFD, 16) == 0 else { throw SocketError.listenFailed(errno) }

        // Restrict to owner.
        _ = chmod(socketPath, 0o600)

        isRunning = true
        acceptQueue = DispatchQueue(label: "app.bonhommenotch.socket.accept", qos: .userInitiated)
        acceptQueue?.async { [weak self] in
            self?.acceptLoop()
        }
        writeStatus()
    }

    public func stop() {
        isRunning = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        gateLock.lock()
        for (_, w) in gateWaiters {
            w.failOpen()
        }
        gateWaiters.removeAll()
        gateLock.unlock()
    }

    /// Approve a waiting gate (Claude/Codex). Returns false if none waiting.
    @discardableResult
    public func approve(sessionID: String) -> Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        guard let waiter = gateWaiters[sessionID] else { return false }
        let input = store.session(id: sessionID)?.gateToolInput
        let decision = GateDecisionBuilder.allow(source: waiter.source, toolInput: input)
        waiter.complete(decision)
        gateWaiters.removeValue(forKey: sessionID)
        store.resolveGate(sessionID: sessionID)
        writeStatus()
        return true
    }

    @discardableResult
    public func deny(sessionID: String, message: String = "Denied from BonhommeNotch") -> Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        guard let waiter = gateWaiters[sessionID] else { return false }
        let decision = GateDecisionBuilder.deny(source: waiter.source, message: message)
        waiter.complete(decision)
        gateWaiters.removeValue(forKey: sessionID)
        store.resolveGate(sessionID: sessionID)
        writeStatus()
        return true
    }

    public func writeStatus() {
        let snap = StatusSnapshot.from(store: store)
        try? snap.write(to: statusPath)
    }

    private func prepareSocketPath() throws {
        let fm = FileManager.default
        let dir = (socketPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }
    }

    private func acceptLoop() {
        while isRunning {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if !isRunning { break }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        // Read until peer closes (EOF). Cursor (and batch senders) may put multiple
        // NDJSON lines on one connection — often as one write, sometimes split
        // across reads. Breaking on the first newline drops every later line.
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 {
                // EOF: flush any remaining complete lines (and a final line without \n).
                flushCompleteLines(from: &buffer, clientFD: fd, includeTrailingPartial: true)
                break
            }
            buffer.append(tmp, count: n)
            if buffer.count > 1_000_000 { return }
            flushCompleteLines(from: &buffer, clientFD: fd, includeTrailingPartial: false)
        }
    }

    /// Drain complete `\n`-terminated NDJSON lines from `buffer` and handle each.
    /// When `includeTrailingPartial` is true (EOF), also handle a final non-empty remnant.
    private func flushCompleteLines(from buffer: inout Data, clientFD: Int32, includeTrailingPartial: Bool) {
        while true {
            guard let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) else { break }
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            let next = buffer.index(after: nl)
            buffer.removeSubrange(buffer.startIndex..<next)
            if let line = String(data: lineData, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    handleLine(trimmed, clientFD: clientFD)
                }
            }
        }
        if includeTrailingPartial, !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    handleLine(trimmed, clientFD: clientFD)
                }
            }
            buffer.removeAll(keepingCapacity: false)
        }
    }

    private func handleLine(_ line: String, clientFD: Int32) {
        let message: HookMessage
        do {
            message = try HookProtocol.parse(line)
        } catch {
            return
        }

        // Cursor-class must never block the editor: convert gate → pending + passthrough.
        if message.action == .gate && !GateDecisionBuilder.supportsBlockingGate(message.source) {
            let pending = HookMessage(
                source: message.source,
                sessionID: message.sessionID,
                action: .pending,
                cwd: message.cwd,
                toolName: message.toolName,
                detail: message.detail,
                model: message.model,
                command: message.detail
            )
            store.apply(pending)
            writeStatus()
            let passthrough = GateDecision(behavior: .passthrough)
            if let data = try? (passthrough.socketJSONLine() + "\n").data(using: .utf8) {
                data.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                        _ = write(clientFD, base, data.count)
                    }
                }
            }
            return
        }

        if message.action == .gate {
            store.apply(message)
            writeStatus()
            let waiter = GateWaiter(source: message.source, timeout: defaultGateTimeout)
            gateLock.lock()
            gateWaiters[message.sessionID] = waiter
            gateLock.unlock()

            // Block this connection until approve/deny or timeout (fail-open).
            let decision = waiter.wait()
            gateLock.lock()
            gateWaiters.removeValue(forKey: message.sessionID)
            gateLock.unlock()

            if decision.behavior == .passthrough || decision.behavior == .allow || decision.behavior == .deny {
                if decision.behavior != .passthrough {
                    store.resolveGate(sessionID: message.sessionID)
                } else {
                    // timeout: leave needs-you so UI can still show, but clear waiter
                    store.resolveGate(sessionID: message.sessionID)
                }
            }
            writeStatus()

            // Fail-open: on timeout, write nothing so hook falls through to terminal.
            if decision.behavior == .passthrough {
                return
            }
            if let data = try? (decision.socketJSONLine() + "\n").data(using: .utf8) {
                data.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                        _ = write(clientFD, base, data.count)
                    }
                }
            }
            return
        }

        store.apply(message)
        writeStatus()
    }
}

private final class GateWaiter: @unchecked Sendable {
    let source: AgentSource
    let timeout: TimeInterval
    private let semaphore = DispatchSemaphore(value: 0)
    private var decision: GateDecision?
    private let lock = NSLock()

    init(source: AgentSource, timeout: TimeInterval) {
        self.source = source
        self.timeout = timeout
    }

    func complete(_ d: GateDecision) {
        lock.lock()
        decision = d
        lock.unlock()
        semaphore.signal()
    }

    func failOpen() {
        complete(GateDecision(behavior: .passthrough))
    }

    func wait() -> GateDecision {
        let ns = timeout > 0 ? DispatchTime.now() + timeout : DispatchTime.distantFuture
        _ = semaphore.wait(timeout: ns)
        lock.lock()
        defer { lock.unlock() }
        return decision ?? GateDecision(behavior: .passthrough)
    }
}

public enum SocketError: Error, CustomStringConvertible {
    case createFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case pathTooLong

    public var description: String {
        switch self {
        case .createFailed(let e): return "socket create failed: \(e)"
        case .bindFailed(let e): return "socket bind failed: \(e)"
        case .listenFailed(let e): return "socket listen failed: \(e)"
        case .pathTooLong: return "socket path too long"
        }
    }
}
