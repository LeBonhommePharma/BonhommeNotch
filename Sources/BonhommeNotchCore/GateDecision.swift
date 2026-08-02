import Foundation

public enum GateBehavior: String, Sendable, Codable {
    case allow
    case deny
    case passthrough
}

/// Decision returned on the socket for a blocking `gate` action.
public struct GateDecision: Equatable {
    public var behavior: GateBehavior
    /// Claude Code requires updatedInput on allow (echo tool input).
    public var updatedInput: [String: Any]?
    /// Deny must carry a message for Claude/Codex hooks.
    public var message: String?

    public init(behavior: GateBehavior, updatedInput: [String: Any]? = nil, message: String? = nil) {
        self.behavior = behavior
        self.updatedInput = updatedInput
        self.message = message
    }

    public static func == (lhs: GateDecision, rhs: GateDecision) -> Bool {
        guard lhs.behavior == rhs.behavior, lhs.message == rhs.message else { return false }
        switch (lhs.updatedInput, rhs.updatedInput) {
        case (nil, nil): return true
        case let (l?, r?): return NSDictionary(dictionary: l).isEqual(to: r)
        default: return false
        }
    }

    /// Wire JSON for the socket reply line (not the agent-specific wrapper).
    public func socketJSONObject() -> [String: Any] {
        var obj: [String: Any] = ["behavior": behavior.rawValue]
        if let updatedInput {
            obj["updatedInput"] = updatedInput
        }
        if let message {
            obj["message"] = message
        }
        return obj
    }

    public func socketJSONLine() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: socketJSONObject(), options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw ProtocolError.invalidJSON
        }
        return s
    }
}

public enum GateDecisionBuilder {
    /// Build an allow decision. Claude must echo tool input; Codex may omit it.
    public static func allow(source: AgentSource, toolInput: [String: Any]?) -> GateDecision {
        switch source {
        case .claude:
            return GateDecision(behavior: .allow, updatedInput: toolInput ?? [:], message: nil)
        case .codex:
            return GateDecision(behavior: .allow, updatedInput: nil, message: nil)
        case .cursor, .kimi, .unknown:
            // Observe-only sources should never block; passthrough if asked.
            return GateDecision(behavior: .passthrough)
        }
    }

    public static func deny(source: AgentSource, message: String = "Denied from BonhommeNotch") -> GateDecision {
        switch source {
        case .cursor:
            return GateDecision(behavior: .passthrough)
        default:
            return GateDecision(behavior: .deny, updatedInput: nil, message: message)
        }
    }

    /// Whether this source may open a blocking gate waiter.
    public static func supportsBlockingGate(_ source: AgentSource) -> Bool {
        switch source {
        case .claude, .codex: return true
        case .cursor, .kimi, .unknown: return false
        }
    }

    /// Claude Code PermissionRequest wrapper for hooks that print to stdout.
    public static func claudeHookStdout(decision: GateDecision) throws -> String {
        var dec: [String: Any] = ["behavior": decision.behavior.rawValue]
        if decision.behavior == .allow {
            dec["updatedInput"] = decision.updatedInput ?? [:]
        }
        if decision.behavior == .deny {
            dec["message"] = decision.message ?? "Denied from BonhommeNotch"
        }
        let wrapper: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": dec
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else { throw ProtocolError.invalidJSON }
        return s
    }

    /// Codex PermissionRequest wrapper.
    public static func codexHookStdout(decision: GateDecision) throws -> String {
        var dec: [String: Any] = ["behavior": decision.behavior.rawValue]
        if decision.behavior == .deny {
            dec["message"] = decision.message ?? "Denied from BonhommeNotch"
        }
        let wrapper: [String: Any] = [
            "continue": true,
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": dec
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else { throw ProtocolError.invalidJSON }
        return s
    }
}
