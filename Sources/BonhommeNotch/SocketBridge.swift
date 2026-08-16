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
    private let runLock = NSLock()
    private var _isRunning = false
    private let gateLock = NSLock()
    /// Composite `source:sessionID` → waiter for blocking gate.
    private var gateWaiters: [String: GateWaiter] = [:]

    private let ioQueue = DispatchQueue(label: "app.bonhommenotch.socket.io")
    private var statusFlushItem: DispatchWorkItem?

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
        ioQueue.sync {
            statusFlushItem?.cancel()
            statusFlushItem = nil
        }
        try? FileManager.default.removeItem(atPath: statusPath)
        gateLock.lock()
        for (_, w) in gateWaiters {
            w.failOpen()
        }
        gateWaiters.removeAll()
        gateLock.unlock()
        // Unblocked waiters may still sendAll() on client fds that are already
        // closing at termination; sendAll treats EPIPE as failure and returns.
    }

    /// Approve a waiting gate (Claude/Codex). Returns false if none waiting.
    @discardableResult
    public func approve(sessionID: String) -> Bool {
        gateLock.lock()
        guard let found = findWaiter(for: sessionID) else {
            gateLock.unlock()
            return false
        }
        let waiter = found.waiter
        let input = store.session(source: waiter.source, sessionID: waiter.sessionID)?.gateToolInput
        let decision = GateDecisionBuilder.allow(source: waiter.source, toolInput: input)
        waiter.complete(decision)
        gateWaiters.removeValue(forKey: found.key)
        let source = waiter.source
        let sid = waiter.sessionID
        gateLock.unlock()

        store.resolveGate(source: source, sessionID: sid)
        scheduleWriteStatus()
        return true
    }

    @discardableResult
    public func deny(sessionID: String, message: String = "Denied from BonhommeNotch") -> Bool {
        gateLock.lock()
        guard let found = findWaiter(for: sessionID) else {
            gateLock.unlock()
            return false
        }
        let waiter = found.waiter
        let decision = GateDecisionBuilder.deny(source: waiter.source, message: message)
        waiter.complete(decision)
        gateWaiters.removeValue(forKey: found.key)
        let source = waiter.source
        let sid = waiter.sessionID
        gateLock.unlock()

        store.resolveGate(source: source, sessionID: sid)
        scheduleWriteStatus()
        return true
    }

    /// Immediate status write (cancels a pending debounce). Used by `--status` observers and tests.
    public func writeStatus() {
        ioQueue.sync {
            statusFlushItem?.cancel()
            statusFlushItem = nil
            writeStatusNow()
        }
    }

    private var isRunning: Bool {
        get {
            runLock.lock()
            defer { runLock.unlock() }
            return _isRunning
        }
        set {
            runLock.lock()
            _isRunning = newValue
            runLock.unlock()
        }
    }

    private func scheduleWriteStatus() {
        ioQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.statusFlushItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.writeStatusNow()
            }
            self.statusFlushItem = item
            self.ioQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
        }
    }

    /// Must run on `ioQueue`.
    private func writeStatusNow() {
        guard isRunning else { return }
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

    private func findWaiter(for sessionID: String) -> (key: String, waiter: GateWaiter)? {
        if let w = gateWaiters[sessionID] {
            return (sessionID, w)
        }
        let matches = gateWaiters.filter { $0.value.sessionID == sessionID }
        guard matches.count == 1, let only = matches.first else { return nil }
        return (only.key, only.value)
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
                _ = flushCompleteLines(from: &buffer, clientFD: fd, includeTrailingPartial: true)
                break
            }
            buffer.append(tmp, count: n)
            if buffer.count > 1_000_000 { return }
            if flushCompleteLines(from: &buffer, clientFD: fd, includeTrailingPartial: false) {
                return
            }
        }
    }

    /// Drain complete `\n`-terminated NDJSON lines from `buffer` and handle each.
    /// When `includeTrailingPartial` is true (EOF), also handle a final non-empty remnant.
    /// Returns true if the caller should close the client (timeout fail-open).
    @discardableResult
    private func flushCompleteLines(from buffer: inout Data, clientFD: Int32, includeTrailingPartial: Bool) -> Bool {
        var start = buffer.startIndex
        while start < buffer.endIndex {
            let region = buffer[start..<buffer.endIndex]
            guard let nl = region.firstIndex(of: UInt8(ascii: "\n")) else { break }
            let lineData = buffer[start..<nl]
            start = buffer.index(after: nl)
            if let line = String(data: Data(lineData), encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if handleLine(trimmed, clientFD: clientFD) {
                        if start > buffer.startIndex {
                            buffer.removeSubrange(buffer.startIndex..<start)
                        }
                        return true
                    }
                }
            }
        }
        if start > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<start)
        }
        if includeTrailingPartial, !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if handleLine(trimmed, clientFD: clientFD) {
                        buffer.removeAll(keepingCapacity: true)
                        return true
                    }
                }
            }
            buffer.removeAll(keepingCapacity: true)
        }
        return false
    }

    /// Returns true if the client connection should close (timeout fail-open).
    @discardableResult
    private func handleLine(_ line: String, clientFD: Int32) -> Bool {
        let message: HookMessage
        do {
            message = try HookProtocol.parse(line)
        } catch {
            return false
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
            scheduleWriteStatus()
            let passthrough = GateDecision(behavior: .passthrough)
            if let data = try? (passthrough.socketJSONLine() + "\n").data(using: .utf8) {
                _ = SocketIO.sendAll(fd: clientFD, data: data)
            }
            return false
        }

        if message.action == .gate {
            store.apply(message)
            scheduleWriteStatus()
            let waiter = GateWaiter(
                source: message.source,
                sessionID: message.sessionID,
                timeout: defaultGateTimeout
            )
            let key = AgentSession.storeKey(source: message.source, sessionID: message.sessionID)
            gateLock.lock()
            gateWaiters[key] = waiter
            gateLock.unlock()

            // Block this connection until approve/deny or timeout (fail-open).
            let decision = waiter.wait()
            gateLock.lock()
            gateWaiters.removeValue(forKey: key)
            gateLock.unlock()

            if decision.behavior == .passthrough {
                // Timeout: leave needs-you so the HUD still shows the pending
                // decision after the agent falls through to its own prompt.
                // Close the client so the hook's recv returns empty immediately
                // instead of sitting on the 1795s socket timeout.
                store.releaseGateWaiter(source: message.source, sessionID: message.sessionID)
                scheduleWriteStatus()
                return true
            }
            if decision.behavior == .allow || decision.behavior == .deny {
                store.resolveGate(source: message.source, sessionID: message.sessionID)
            }
            scheduleWriteStatus()

            if let data = try? (decision.socketJSONLine() + "\n").data(using: .utf8) {
                _ = SocketIO.sendAll(fd: clientFD, data: data)
            }
            return false
        }

        store.apply(message)
        scheduleWriteStatus()
        return false
    }
}

private final class GateWaiter: @unchecked Sendable {
    let source: AgentSource
    let sessionID: String
    let timeout: TimeInterval
    private let semaphore = DispatchSemaphore(value: 0)
    private var decision: GateDecision?
    private let lock = NSLock()

    init(source: AgentSource, sessionID: String, timeout: TimeInterval) {
        self.source = source
        self.sessionID = sessionID
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

enum SocketIO {
    /// Loop until every byte is written. A single `write()` can truncate past PIPE_BUF.
    @discardableResult
    static func sendAll(fd: Int32, data: Data) -> Bool {
        if data.isEmpty { return true }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                sent += n
            }
            return true
        }
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
