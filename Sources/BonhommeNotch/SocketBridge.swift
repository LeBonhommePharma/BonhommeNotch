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
    private let clientQueue = DispatchQueue(
        label: "app.bonhommenotch.socket.client",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let gateTimeoutQueue = DispatchQueue(label: "app.bonhommenotch.socket.gate-timeout")
    private let runLock = NSLock()
    private var _isRunning = false
    private let gateLock = NSLock()
    /// Composite `source:sessionID` → waiter for a held client fd (no thread parked).
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
        let pending = Array(gateWaiters.values)
        gateWaiters.removeAll()
        gateLock.unlock()
        // Close held client fds; sendAll treats EPIPE as failure if the peer is gone.
        for waiter in pending {
            finishWaiter(waiter, decision: GateDecision(behavior: .passthrough))
        }
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
        gateWaiters.removeValue(forKey: found.key)
        gateLock.unlock()

        let input = store.session(source: waiter.source, sessionID: waiter.sessionID)?.gateToolInput
        let decision = GateDecisionBuilder.allow(source: waiter.source, toolInput: input)
        return finishWaiter(waiter, decision: decision)
    }

    @discardableResult
    public func deny(sessionID: String, message: String = "Denied from BonhommeNotch") -> Bool {
        gateLock.lock()
        guard let found = findWaiter(for: sessionID) else {
            gateLock.unlock()
            return false
        }
        let waiter = found.waiter
        gateWaiters.removeValue(forKey: found.key)
        gateLock.unlock()

        let decision = GateDecisionBuilder.deny(source: waiter.source, message: message)
        return finishWaiter(waiter, decision: decision)
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
            clientQueue.async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    private enum ClientDisposition {
        case keepReading
        case holdForGate
    }

    private func handleClient(_ fd: Int32) {
        var disposition: ClientDisposition = .keepReading
        defer {
            if disposition != .holdForGate {
                close(fd)
            }
        }
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
                disposition = flushCompleteLines(from: &buffer, clientFD: fd, includeTrailingPartial: true)
                break
            }
            buffer.append(tmp, count: n)
            if buffer.count > 1_000_000 { return }
            let next = flushCompleteLines(from: &buffer, clientFD: fd, includeTrailingPartial: false)
            switch next {
            case .keepReading:
                continue
            case .holdForGate:
                disposition = next
                return
            }
        }
    }

    /// Drain complete `\n`-terminated NDJSON lines from `buffer` and handle each.
    /// When `includeTrailingPartial` is true (EOF), also handle a final non-empty remnant.
    @discardableResult
    private func flushCompleteLines(from buffer: inout Data, clientFD: Int32, includeTrailingPartial: Bool) -> ClientDisposition {
        var start = buffer.startIndex
        while start < buffer.endIndex {
            let region = buffer[start..<buffer.endIndex]
            guard let nl = region.firstIndex(of: UInt8(ascii: "\n")) else { break }
            let lineData = buffer[start..<nl]
            start = buffer.index(after: nl)
            if let line = String(data: Data(lineData), encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let d = handleLine(trimmed, clientFD: clientFD)
                    if d != .keepReading {
                        if start > buffer.startIndex {
                            buffer.removeSubrange(buffer.startIndex..<start)
                        }
                        return d
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
                    let d = handleLine(trimmed, clientFD: clientFD)
                    buffer.removeAll(keepingCapacity: true)
                    return d
                }
            }
            buffer.removeAll(keepingCapacity: true)
        }
        return .keepReading
    }

    private func handleLine(_ line: String, clientFD: Int32) -> ClientDisposition {
        let message: HookMessage
        do {
            message = try HookProtocol.parse(line)
        } catch {
            return .keepReading
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
            return .keepReading
        }

        if message.action == .gate {
            store.apply(message)
            scheduleWriteStatus()
            let key = AgentSession.storeKey(source: message.source, sessionID: message.sessionID)
            let waiter = GateWaiter(
                source: message.source,
                sessionID: message.sessionID,
                clientFD: clientFD
            )
            let timeout = defaultGateTimeout
            if timeout > 0 {
                let item = DispatchWorkItem { [weak self] in
                    _ = self?.fulfillGate(key: key, decision: GateDecision(behavior: .passthrough))
                }
                waiter.timeoutItem = item
                gateLock.lock()
                gateWaiters[key] = waiter
                gateLock.unlock()
                gateTimeoutQueue.asyncAfter(deadline: .now() + timeout, execute: item)
            } else {
                gateLock.lock()
                gateWaiters[key] = waiter
                gateLock.unlock()
            }
            // Hold the fd; approve/deny/timeout writes the reply (or closes for fail-open).
            return .holdForGate
        }

        store.apply(message)
        scheduleWriteStatus()
        return .keepReading
    }

    @discardableResult
    private func fulfillGate(key: String, decision: GateDecision) -> Bool {
        gateLock.lock()
        guard let waiter = gateWaiters.removeValue(forKey: key) else {
            gateLock.unlock()
            return false
        }
        gateLock.unlock()
        return finishWaiter(waiter, decision: decision)
    }

    /// Reply on the held client fd. Returns false if the waiter was already claimed.
    @discardableResult
    private func finishWaiter(_ waiter: GateWaiter, decision: GateDecision) -> Bool {
        guard waiter.claim() else { return false }
        waiter.timeoutItem?.cancel()
        waiter.timeoutItem = nil

        switch decision.behavior {
        case .passthrough:
            store.releaseGateWaiter(source: waiter.source, sessionID: waiter.sessionID)
            scheduleWriteStatus()
            close(waiter.clientFD)
        case .allow, .deny:
            store.resolveGate(source: waiter.source, sessionID: waiter.sessionID)
            scheduleWriteStatus()
            if let data = try? (decision.socketJSONLine() + "\n").data(using: .utf8) {
                _ = SocketIO.sendAll(fd: waiter.clientFD, data: data)
            }
            close(waiter.clientFD)
        }
        return true
    }
}

private final class GateWaiter: @unchecked Sendable {
    let source: AgentSource
    let sessionID: String
    let clientFD: Int32
    var timeoutItem: DispatchWorkItem?
    private let lock = NSLock()
    private var finished = false

    init(source: AgentSource, sessionID: String, clientFD: Int32) {
        self.source = source
        self.sessionID = sessionID
        self.clientFD = clientFD
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
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
