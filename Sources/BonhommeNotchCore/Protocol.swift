import Foundation

/// NDJSON v1 envelope compatible with AgentNotch-class hook bridges.
public struct HookMessage: Equatable {
    public var v: Int
    public var source: AgentSource
    public var sessionID: String
    public var action: HookAction
    public var cwd: String?
    public var toolName: String?
    public var detail: String?
    public var reason: String?
    public var model: String?
    public var kind: MarkerKind?
    public var status: String?
    public var title: String?
    public var command: String?
    public var options: [String]?
    public var moreQuestions: Int?
    public var escalated: Bool?
    public var ts: Double?
    public var transcriptPath: String?

    /// Raw tool input dictionary for Claude gate allow echo (optional).
    public var toolInput: [String: AnyCodable]?

    public init(
        v: Int = 1,
        source: AgentSource,
        sessionID: String,
        action: HookAction,
        cwd: String? = nil,
        toolName: String? = nil,
        detail: String? = nil,
        reason: String? = nil,
        model: String? = nil,
        kind: MarkerKind? = nil,
        status: String? = nil,
        title: String? = nil,
        command: String? = nil,
        options: [String]? = nil,
        moreQuestions: Int? = nil,
        escalated: Bool? = nil,
        ts: Double? = nil,
        transcriptPath: String? = nil,
        toolInput: [String: AnyCodable]? = nil
    ) {
        self.v = v
        self.source = source
        self.sessionID = sessionID
        self.action = action
        self.cwd = cwd
        self.toolName = toolName
        self.detail = detail
        self.reason = reason
        self.model = model
        self.kind = kind
        self.status = status
        self.title = title
        self.command = command
        self.options = options
        self.moreQuestions = moreQuestions
        self.escalated = escalated
        self.ts = ts
        self.transcriptPath = transcriptPath
        self.toolInput = toolInput
    }
}

public enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case cursor
    case kimi
    case unknown

    public init(raw: String) {
        self = AgentSource(rawValue: raw.lowercased()) ?? .unknown
    }
}

public enum HookAction: String, Codable, Sendable, CaseIterable {
    case start
    case busy
    case busydone
    case done
    case clear
    case marker
    case gate
    case pending
    case pendingClear = "pending-clear"
    case activity
    case activityClear = "activity-clear"
    case observe
}

public enum MarkerKind: String, Codable, Sendable, CaseIterable {
    case plan
    case question
    case idle
    case permission
    case shell
    case mcp
    case tool
    case unknown

    public init(raw: String?) {
        guard let raw else {
            self = .unknown
            return
        }
        self = MarkerKind(rawValue: raw.lowercased()) ?? .unknown
    }
}

public enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case empty
    case invalidJSON
    case missingSessionID
    case missingAction
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .empty: return "empty message"
        case .invalidJSON: return "invalid JSON"
        case .missingSessionID: return "missing session_id"
        case .missingAction: return "missing or unknown action"
        case .unsupportedVersion(let v): return "unsupported version \(v)"
        }
    }
}

public enum HookProtocol {
    /// Parse one NDJSON line into a HookMessage.
    public static func parse(_ line: String) throws -> HookMessage {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProtocolError.empty }
        guard let data = trimmed.data(using: .utf8) else { throw ProtocolError.invalidJSON }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> HookMessage {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProtocolError.invalidJSON
        }
        return try parse(object: obj)
    }

    public static func parse(object: [String: Any]) throws -> HookMessage {
        let v = (object["v"] as? Int) ?? 1
        if v != 1 { throw ProtocolError.unsupportedVersion(v) }

        guard let sidRaw = object["session_id"] as? String, !sidRaw.isEmpty else {
            throw ProtocolError.missingSessionID
        }

        guard let actionRaw = object["action"] as? String,
              let action = HookAction(rawValue: actionRaw) else {
            throw ProtocolError.missingAction
        }

        let sourceRaw = (object["source"] as? String) ?? "unknown"
        let kind = MarkerKind(raw: object["kind"] as? String)

        var toolInput: [String: AnyCodable]?
        if let ti = object["tool_input"] as? [String: Any] {
            toolInput = ti.mapValues { AnyCodable($0) }
        }

        let options: [String]? = {
            if let arr = object["options"] as? [String] { return arr }
            if let arr = object["options"] as? [Any] {
                return arr.compactMap { $0 as? String }
            }
            return nil
        }()

        return HookMessage(
            v: v,
            source: AgentSource(raw: sourceRaw),
            sessionID: sidRaw,
            action: action,
            cwd: object["cwd"] as? String,
            toolName: object["tool_name"] as? String,
            detail: object["detail"] as? String,
            reason: object["reason"] as? String,
            model: object["model"] as? String,
            kind: kind == .unknown && object["kind"] == nil ? nil : kind,
            status: object["status"] as? String,
            title: object["title"] as? String,
            command: object["command"] as? String,
            options: options,
            moreQuestions: object["more_questions"] as? Int,
            escalated: object["escalated"] as? Bool,
            ts: (object["ts"] as? Double) ?? (object["ts"] as? Int).map(Double.init),
            transcriptPath: object["transcript_path"] as? String,
            toolInput: toolInput
        )
    }

    /// Encode a message to a single NDJSON line (no trailing newline).
    public static func encodeLine(_ message: HookMessage) throws -> String {
        var dict: [String: Any] = [
            "v": message.v,
            "source": message.source.rawValue,
            "session_id": message.sessionID,
            "action": message.action.rawValue
        ]
        if let cwd = message.cwd { dict["cwd"] = cwd }
        if let toolName = message.toolName { dict["tool_name"] = toolName }
        if let detail = message.detail { dict["detail"] = detail }
        if let reason = message.reason { dict["reason"] = reason }
        if let model = message.model { dict["model"] = model }
        if let kind = message.kind { dict["kind"] = kind.rawValue }
        if let status = message.status { dict["status"] = status }
        if let title = message.title { dict["title"] = title }
        if let command = message.command { dict["command"] = command }
        if let options = message.options { dict["options"] = options }
        if let more = message.moreQuestions { dict["more_questions"] = more }
        if let escalated = message.escalated { dict["escalated"] = escalated }
        if let ts = message.ts { dict["ts"] = ts }
        if let tp = message.transcriptPath { dict["transcript_path"] = tp }
        if let ti = message.toolInput {
            dict["tool_input"] = ti.mapValues { $0.value }
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else { throw ProtocolError.invalidJSON }
        return s
    }
}

/// Type-erased JSON value for optional tool_input echo.
public struct AnyCodable: Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (l as String, r as String): return l == r
        case let (l as Int, r as Int): return l == r
        case let (l as Double, r as Double): return l == r
        case let (l as Bool, r as Bool): return l == r
        case let (l as [String], r as [String]): return l == r
        case let (l as [String: Any], r as [String: Any]):
            return NSDictionary(dictionary: l).isEqual(to: r)
        default:
            return "\(lhs.value)" == "\(rhs.value)"
        }
    }
}
