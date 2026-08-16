import Foundation

/// Serializable status for launch/self-test observation (status.json).
public struct StatusSnapshot: Equatable, Sendable {
    public var sessionCount: Int
    public var needsYouCount: Int
    public var workingCount: Int
    public var primaryFocusLine: String
    public var rankedSessionIDs: [String]
    public var rankedBadges: [String]
    public var updatedAt: TimeInterval

    public init(
        sessionCount: Int,
        needsYouCount: Int,
        workingCount: Int,
        primaryFocusLine: String,
        rankedSessionIDs: [String],
        rankedBadges: [String],
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.sessionCount = sessionCount
        self.needsYouCount = needsYouCount
        self.workingCount = workingCount
        self.primaryFocusLine = primaryFocusLine
        self.rankedSessionIDs = rankedSessionIDs
        self.rankedBadges = rankedBadges
        self.updatedAt = updatedAt
    }

    public static func from(store: SessionStore, now: Date = Date()) -> StatusSnapshot {
        let ranked = store.ranked()
        return StatusSnapshot(
            sessionCount: ranked.count,
            needsYouCount: ranked.filter { $0.attention == .needsYou }.count,
            workingCount: ranked.filter { $0.attention == .working }.count,
            primaryFocusLine: store.focusLine(ranked: ranked),
            rankedSessionIDs: ranked.map(\.id),
            rankedBadges: ranked.map { $0.attention.badge },
            updatedAt: now.timeIntervalSince1970
        )
    }

    public func jsonObject() -> [String: Any] {
        [
            "sessionCount": sessionCount,
            "needsYouCount": needsYouCount,
            "workingCount": workingCount,
            "primaryFocusLine": primaryFocusLine,
            "rankedSessionIDs": rankedSessionIDs,
            "rankedBadges": rankedBadges,
            "updatedAt": updatedAt
        ]
    }

    public func write(to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject(), options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func load(from path: String) throws -> StatusSnapshot {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProtocolError.invalidJSON
        }
        return StatusSnapshot(
            sessionCount: obj["sessionCount"] as? Int ?? 0,
            needsYouCount: obj["needsYouCount"] as? Int ?? 0,
            workingCount: obj["workingCount"] as? Int ?? 0,
            primaryFocusLine: obj["primaryFocusLine"] as? String ?? "",
            rankedSessionIDs: obj["rankedSessionIDs"] as? [String] ?? [],
            rankedBadges: obj["rankedBadges"] as? [String] ?? [],
            updatedAt: obj["updatedAt"] as? Double ?? 0
        )
    }
}
