import Foundation

/// The six metadata fields used by the native ActivityAttributes wire state.
/// Kept in the shared module so projections and encoding need no ActivityKit.
public struct IslandActivityContent: Codable, Hashable, Sendable {
    public let sessionID: String
    public let projectName: String
    public let phase: AgentPhase
    public let workingCount: Int
    public let waitingCount: Int
    public let updatedAt: Date

    public init(sessionID: String, projectName: String, phase: AgentPhase,
                workingCount: Int, waitingCount: Int, updatedAt: Date) {
        self.sessionID = sessionID
        self.projectName = projectName
        self.phase = phase
        self.workingCount = workingCount
        self.waitingCount = waitingCount
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, projectName, phase, workingCount, waitingCount, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessionID: try fields.decode(String.self, forKey: .sessionID),
                  projectName: try fields.decode(String.self, forKey: .projectName),
                  phase: try fields.decode(AgentPhase.self, forKey: .phase),
                  workingCount: try fields.decode(Int.self, forKey: .workingCount),
                  waitingCount: try fields.decode(Int.self, forKey: .waitingCount),
                  updatedAt: try fields.decode(Date.self, forKey: .updatedAt))
        try IslandActivityPresentationPolicy.standard.validate(self)
    }
}

public struct IslandActivityPresentation: Equatable, Sendable {
    public let state: IslandActivityContent
    public let staleAt: Date
    public var sessionURL: URL? { SessionLink.url(for: state.sessionID) }
}

public enum IslandActivityError: String, Error, Sendable {
    case invalidClock, invalidContent, contentBudgetExceeded, disabled, busy, invalidActivityID
    case requestFailed, updateFailed, endFailed
    case schedulingFailed, cancelled, inventoryFailed, invalidInventory, stopped
}

public struct IslandActivityPresentationPolicy: Sendable {
    public static let standard = IslandActivityPresentationPolicy()
    /// A conservative development budget for this shared JSON encoding, not a
    /// claim about the unreleased macOS SDK's actual transport limit.
    public let maximumContentBytes = 3 * 1024

    public init() {}

    public func presentation(for snapshot: SessionSnapshot, at now: Date) throws -> IslandActivityPresentation? {
        guard now.timeIntervalSince1970.isFinite else { throw IslandActivityError.invalidClock }
        guard let highlighted = snapshot.activitySession, let staleAt = snapshot.activityStaleAt else { return nil }
        let participating = snapshot.sessions.filter(\.isLiveActivity)
        // A cached aggregate cannot outlive even its earliest participant.
        // Request a new snapshot rather than display partially stale counts.
        guard staleAt > now, participating.allSatisfy({ $0.session.updatedAt <= now && $0.freshUntil > now }) else { return nil }
        let state = IslandActivityContent(sessionID: highlighted.id, projectName: highlighted.session.projectName,
                                          phase: highlighted.session.phase, workingCount: snapshot.workingCount,
                                          waitingCount: snapshot.waitingCount, updatedAt: highlighted.session.updatedAt)
        try validate(state)
        return IslandActivityPresentation(state: state, staleAt: staleAt)
    }

    public func validate(_ state: IslandActivityContent) throws {
        guard state.phase == .working || state.phase == .needsInput,
              state.workingCount >= 0, state.waitingCount >= 0 else { throw IslandActivityError.invalidContent }
        let total = state.workingCount.addingReportingOverflow(state.waitingCount)
        guard !total.overflow, total.partialValue > 0,
              (state.phase == .working ? state.workingCount : state.waitingCount) > 0 else {
            throw IslandActivityError.invalidContent
        }
        do {
            try AgentEvent(sessionID: state.sessionID, projectName: state.projectName, phase: state.phase, occurredAt: state.updatedAt).validate()
        } catch { throw IslandActivityError.invalidContent }
        let encoded = try EventCodec.jsonEncoder().encode(state)
        guard encoded.count <= maximumContentBytes else { throw IslandActivityError.contentBudgetExceeded }
    }
}
