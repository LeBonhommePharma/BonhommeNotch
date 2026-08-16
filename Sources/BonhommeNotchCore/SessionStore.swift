import Foundation

/// Attention rank: lower number = higher priority (needs-you first).
public enum SessionAttention: Int, Comparable, Sendable, Codable, CaseIterable {
    case needsYou = 0
    case working = 1
    case finished = 2
    case idle = 3

    public static func < (lhs: SessionAttention, rhs: SessionAttention) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var badge: String {
        switch self {
        case .needsYou: return "needs you"
        case .working: return "working"
        case .finished: return "done"
        case .idle: return "idle"
        }
    }
}

public enum NeedsYouKind: String, Sendable, Codable, Equatable {
    case gate
    case question
    case plan
    case pending
}

public struct AgentSession: Equatable, Identifiable {
    /// Composite `source:sessionID` — session ids are not unique across agents.
    public var id: String { Self.storeKey(source: source, sessionID: sessionID) }
    public var sessionID: String
    public var source: AgentSource
    public var attention: SessionAttention
    public var needsYouKind: NeedsYouKind?
    public var cwd: String?
    public var model: String?
    public var toolName: String?
    public var detail: String?
    public var reason: String?
    public var activityTitle: String?
    public var lastUpdated: Date
    public var gateWaiting: Bool
    /// Tool input captured at gate time for Claude allow echo.
    public var gateToolInput: [String: Any]?
    public var options: [String]?

    public init(
        sessionID: String,
        source: AgentSource,
        attention: SessionAttention = .idle,
        needsYouKind: NeedsYouKind? = nil,
        cwd: String? = nil,
        model: String? = nil,
        toolName: String? = nil,
        detail: String? = nil,
        reason: String? = nil,
        activityTitle: String? = nil,
        lastUpdated: Date = Date(),
        gateWaiting: Bool = false,
        gateToolInput: [String: Any]? = nil,
        options: [String]? = nil
    ) {
        self.sessionID = sessionID
        self.source = source
        self.attention = attention
        self.needsYouKind = needsYouKind
        self.cwd = cwd
        self.model = model
        self.toolName = toolName
        self.detail = detail
        self.reason = reason
        self.activityTitle = activityTitle
        self.lastUpdated = lastUpdated
        self.gateWaiting = gateWaiting
        self.gateToolInput = gateToolInput
        self.options = options
    }

    public static func storeKey(source: AgentSource, sessionID: String) -> String {
        "\(source.rawValue):\(sessionID)"
    }

    public var focusLine: String {
        let name = projectName
        let badge = attention.badge
        if let detail, !detail.isEmpty {
            let clipped = detail.count > 80 ? String(detail.prefix(79)) + "…" : detail
            return "\(source.rawValue) · \(name) · \(badge) · \(clipped)"
        }
        if let activityTitle, !activityTitle.isEmpty {
            return "\(source.rawValue) · \(name) · \(badge) · \(activityTitle)"
        }
        return "\(source.rawValue) · \(name) · \(badge)"
    }

    public var projectName: String {
        if let cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return String(sessionID.prefix(8))
    }
}

/// Equality ignoring gateToolInput (Any is awkward).
extension AgentSession {
    public static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.source == rhs.source
            && lhs.attention == rhs.attention
            && lhs.needsYouKind == rhs.needsYouKind
            && lhs.cwd == rhs.cwd
            && lhs.model == rhs.model
            && lhs.toolName == rhs.toolName
            && lhs.detail == rhs.detail
            && lhs.reason == rhs.reason
            && lhs.activityTitle == rhs.activityTitle
            && lhs.gateWaiting == rhs.gateWaiting
            && lhs.options == rhs.options
    }
}

/// Multi-session store. Pure logic: apply HookMessage → mutate sessions.
public final class SessionStore: @unchecked Sendable {
    private var sessions: [String: AgentSession] = [:]
    private let lock = NSLock()
    public var onChange: (() -> Void)?

    public init() {}

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    public func snapshot() -> [AgentSession] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessions.values)
    }

    public func session(source: AgentSource, sessionID: String) -> AgentSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[AgentSession.storeKey(source: source, sessionID: sessionID)]
    }

    /// Lookup by composite `id`, or by raw `sessionID` when that id is unique.
    public func session(id: String) -> AgentSession? {
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[id] { return s }
        let matches = sessions.values.filter { $0.sessionID == id }
        return matches.count == 1 ? matches.first : nil
    }

    /// Ranked: needs-you first, then working, finished, idle; within tier by lastUpdated desc.
    public func ranked() -> [AgentSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.sorted { a, b in
            if a.attention != b.attention {
                return a.attention < b.attention
            }
            return a.lastUpdated > b.lastUpdated
        }
    }

    public var primaryFocus: AgentSession? {
        ranked().first
    }

    public var primaryFocusLine: String {
        focusLine(ranked: ranked())
    }

    public func focusLine(ranked sessions: [AgentSession]) -> String {
        sessions.first?.focusLine ?? "BonhommeNotch · idle"
    }

    public var statusSummary: String {
        statusSummary(ranked: ranked())
    }

    public func statusSummary(ranked sessions: [AgentSession]) -> String {
        if sessions.isEmpty { return "0 sessions" }
        let needs = sessions.filter { $0.attention == .needsYou }.count
        let working = sessions.filter { $0.attention == .working }.count
        return "\(sessions.count) sessions · \(needs) needs you · \(working) working · focus: \(focusLine(ranked: sessions))"
    }

    @discardableResult
    public func apply(_ message: HookMessage, now: Date = Date()) -> AgentSession {
        lock.lock()
        defer {
            lock.unlock()
            onChange?()
        }

        let key = AgentSession.storeKey(source: message.source, sessionID: message.sessionID)
        var s = sessions[key] ?? AgentSession(
            sessionID: message.sessionID,
            source: message.source,
            lastUpdated: now
        )
        s.source = message.source == .unknown ? s.source : message.source
        s.lastUpdated = now
        if let cwd = message.cwd, !cwd.isEmpty { s.cwd = cwd }
        if let model = message.model, !model.isEmpty { s.model = model }
        if let tool = message.toolName, !tool.isEmpty { s.toolName = tool }
        if let detail = message.detail, !detail.isEmpty { s.detail = detail }
        if let reason = message.reason, !reason.isEmpty { s.reason = reason }
        if let opts = message.options { s.options = opts }

        switch message.action {
        case .start:
            s.attention = .working
            s.needsYouKind = nil
            s.gateWaiting = false
            s.activityTitle = "Working…"
        case .busy:
            if s.attention != .needsYou {
                s.attention = .working
            }
            if let d = message.detail, !d.isEmpty {
                s.activityTitle = d
            } else if let t = message.toolName {
                s.activityTitle = t
            }
        case .busydone:
            if !s.gateWaiting {
                s.attention = .working
            }
            // After timeout fail-open, gateWaiting is false but needs-you remains
            // until the agent continues. A real approve/deny already cleared kind.
            if s.needsYouKind == .gate && !s.gateWaiting {
                s.needsYouKind = nil
            }
        case .done:
            s.attention = .finished
            s.needsYouKind = nil
            s.gateWaiting = false
            s.activityTitle = "Done"
        case .clear:
            s.needsYouKind = nil
            s.gateWaiting = false
            if s.attention == .needsYou {
                s.attention = .working
            }
            s.detail = nil
            s.options = nil
            s.activityTitle = nil
            s.reason = nil
            s.toolName = nil
        case .marker:
            applyMarker(kind: message.kind ?? .unknown, to: &s, message: message)
        case .gate:
            s.attention = .needsYou
            s.needsYouKind = .gate
            s.gateWaiting = true
            if let ti = message.toolInput {
                s.gateToolInput = ti.mapValues { $0.value }
            }
            if let d = message.detail, !d.isEmpty { s.detail = d }
            if let t = message.toolName { s.toolName = t }
        case .pending:
            s.attention = .needsYou
            s.needsYouKind = .pending
            s.gateWaiting = false
            if let cmd = message.command, !cmd.isEmpty { s.detail = cmd }
            if let d = message.detail, !d.isEmpty { s.detail = d }
            if let t = message.toolName, !t.isEmpty { s.toolName = t }
        case .pendingClear:
            if s.needsYouKind == .pending {
                s.needsYouKind = nil
                s.attention = .working
            }
        case .activity:
            if s.attention != .needsYou {
                s.attention = .working
            }
            if let title = message.title, !title.isEmpty {
                s.activityTitle = title
            } else if let status = message.status, !status.isEmpty {
                s.activityTitle = status
            }
        case .activityClear:
            s.activityTitle = nil
            if s.attention == .working {
                s.attention = .finished
            }
        case .observe:
            // Soft activity without forcing attention.
            if let title = message.title {
                s.activityTitle = title
            }
        }

        sessions[key] = s
        return s
    }

    private func applyMarker(kind: MarkerKind, to s: inout AgentSession, message: HookMessage) {
        switch kind {
        case .plan:
            s.attention = .needsYou
            s.needsYouKind = .plan
            s.gateWaiting = false
        case .question:
            s.attention = .needsYou
            s.needsYouKind = .question
            s.gateWaiting = false
        case .permission:
            s.attention = .needsYou
            s.needsYouKind = .gate
            s.gateWaiting = false
        case .idle:
            s.attention = .idle
            s.needsYouKind = nil
            s.gateWaiting = false
        case .shell, .mcp, .tool:
            s.attention = .needsYou
            s.needsYouKind = .pending
            s.gateWaiting = false
        case .unknown:
            if let d = message.detail, !d.isEmpty {
                s.detail = d
            }
        }
    }

    /// Mark gate resolved after Approve/Deny (session stays working).
    public func resolveGate(source: AgentSource? = nil, sessionID: String, now: Date = Date()) {
        mutateSession(source: source, sessionID: sessionID, now: now) { s in
            s.gateWaiting = false
            s.needsYouKind = nil
            s.attention = .working
        }
    }

    /// Timeout fail-open: drop the blocking waiter, keep needs-you visible.
    public func releaseGateWaiter(source: AgentSource? = nil, sessionID: String, now: Date = Date()) {
        mutateSession(source: source, sessionID: sessionID, now: now) { s in
            s.gateWaiting = false
        }
    }

    public func remove(source: AgentSource? = nil, sessionID: String) {
        lock.lock()
        defer {
            lock.unlock()
            onChange?()
        }
        if let key = storageKey(source: source, sessionID: sessionID) {
            sessions.removeValue(forKey: key)
        }
    }

    public func reset() {
        lock.lock()
        sessions.removeAll()
        lock.unlock()
        onChange?()
    }

    private func mutateSession(
        source: AgentSource?,
        sessionID: String,
        now: Date,
        _ body: (inout AgentSession) -> Void
    ) {
        lock.lock()
        defer {
            lock.unlock()
            onChange?()
        }
        guard let key = storageKey(source: source, sessionID: sessionID), var s = sessions[key] else { return }
        body(&s)
        s.lastUpdated = now
        sessions[key] = s
    }

    private func storageKey(source: AgentSource?, sessionID: String) -> String? {
        if let source {
            let key = AgentSession.storeKey(source: source, sessionID: sessionID)
            return sessions[key] != nil ? key : nil
        }
        if sessions[sessionID] != nil { return sessionID }
        let matches = sessions.filter { $0.value.sessionID == sessionID }
        return matches.count == 1 ? matches.first?.key : nil
    }
}
