import Foundation

public struct IslandActivitySession: Codable, Hashable, Sendable, Identifiable {
    public let sessionID: String
    public let projectName: String
    public let phase: AgentPhase

    public var id: String { sessionID }

    fileprivate func validate(at time: Date) throws {
        guard phase == .working || phase == .needsInput else { throw IslandActivityError.invalidContent }
        do {
            try AgentEvent(sessionID: sessionID, projectName: projectName, phase: phase, occurredAt: time).validate()
        } catch { throw IslandActivityError.invalidContent }
    }
}

/// Metadata used by the native ActivityAttributes wire state.
/// Kept in the shared module so projections and encoding need no ActivityKit.
public struct IslandActivityContent: Codable, Hashable, Sendable {
    public let sessionID: String
    public let projectName: String
    public let phase: AgentPhase
    public let workingCount: Int
    public let waitingCount: Int
    public let updatedAt: Date
    public let codexQuota: CodexQuotaSnapshot?
    public let otherSessions: [IslandActivitySession]?

    public init(sessionID: String, projectName: String, phase: AgentPhase,
                workingCount: Int, waitingCount: Int, updatedAt: Date, codexQuota: CodexQuotaSnapshot? = nil,
                otherSessions: [IslandActivitySession]? = nil) {
        self.sessionID = sessionID
        self.projectName = projectName
        self.phase = phase
        self.workingCount = workingCount
        self.waitingCount = waitingCount
        self.updatedAt = updatedAt
        self.codexQuota = codexQuota
        self.otherSessions = otherSessions.flatMap { $0.isEmpty ? nil : $0 }
    }

    var primarySession: IslandActivitySession {
        IslandActivitySession(sessionID: sessionID, projectName: projectName, phase: phase)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, projectName, phase, workingCount, waitingCount, updatedAt, codexQuota, otherSessions
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessionID: try fields.decode(String.self, forKey: .sessionID),
                  projectName: try fields.decode(String.self, forKey: .projectName),
                  phase: try fields.decode(AgentPhase.self, forKey: .phase),
                  workingCount: try fields.decode(Int.self, forKey: .workingCount),
                  waitingCount: try fields.decode(Int.self, forKey: .waitingCount),
                  updatedAt: try fields.decode(Date.self, forKey: .updatedAt),
                  codexQuota: try? fields.decodeIfPresent(CodexQuotaSnapshot.self, forKey: .codexQuota),
                  otherSessions: try? fields.decodeIfPresent([IslandActivitySession].self, forKey: .otherSessions))
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
    case requestFailed, foregroundRequired, updateFailed, endFailed
    case schedulingFailed, cancelled, inventoryFailed, invalidInventory, stopped
}

public struct IslandActivityPresentationPolicy: Sendable {
    public static let standard = IslandActivityPresentationPolicy()
    /// A conservative development budget for this shared JSON encoding, not a
    /// claim about the unreleased macOS SDK's actual transport limit.
    public let maximumContentBytes = 3 * 1024
    private static let maximumOtherSessions = 2

    public init() {}

    public func presentation(for snapshot: SessionSnapshot, at now: Date) throws -> IslandActivityPresentation? {
        try presentation(for: snapshot, at: now, showsProjectName: true)
    }

    public func presentation(for snapshot: SessionSnapshot, at now: Date, showsProjectName: Bool,
                             codexQuota: CodexQuotaSnapshot? = nil) throws -> IslandActivityPresentation? {
        guard now.timeIntervalSince1970.isFinite else { throw IslandActivityError.invalidClock }
        guard let highlighted = snapshot.activitySession, let staleAt = snapshot.activityStaleAt else { return nil }
        let participating = snapshot.sessions.filter(\.isLiveActivity)
        // A cached aggregate cannot outlive even its earliest participant.
        // Request a new snapshot rather than display partially stale counts.
        guard staleAt > now, participating.allSatisfy({ $0.session.updatedAt <= now && $0.freshUntil > now }) else { return nil }
        // The snapshot is already ordered for attention. Keep the highlighted
        // target first so the compact and expanded views start at the same place.
        let additional = participating.lazy.filter { $0.id != highlighted.id }.prefix(Self.maximumOtherSessions)
        let entries = try ([highlighted] + additional).map { status in
            let original = IslandActivitySession(sessionID: status.id, projectName: status.session.projectName,
                                                phase: status.session.phase)
            try original.validate(at: status.session.updatedAt)
            return showsProjectName ? original : IslandActivitySession(sessionID: original.sessionID,
                                                                        projectName: "开发会话", phase: original.phase)
        }
        let workingCount = participating.filter { $0.activity == .working }.count
        let waitingCount = participating.count - workingCount
        let primary = entries[0]
        let quota = codexQuota.flatMap { $0.windows(at: now).isEmpty ? nil : $0 }
        func state(others: [IslandActivitySession], quota: CodexQuotaSnapshot?) -> IslandActivityContent {
            IslandActivityContent(sessionID: primary.sessionID, projectName: primary.projectName, phase: primary.phase,
                                  workingCount: workingCount, waitingCount: waitingCount, updatedAt: highlighted.session.updatedAt,
                                  codexQuota: quota, otherSessions: others)
        }
        var others = Array(entries.dropFirst())
        while true {
            let candidate = state(others: others, quota: quota)
            do {
                try validate(candidate)
                return IslandActivityPresentation(state: candidate, staleAt: staleAt)
            } catch IslandActivityError.contentBudgetExceeded {
                // Preserve the primary target and prefer the most important
                // remaining sessions if escaped metadata needs extra bytes.
                if others.isEmpty {
                    let primaryOnly = state(others: [], quota: nil)
                    try validate(primaryOnly)
                    return IslandActivityPresentation(state: primaryOnly, staleAt: staleAt)
                }
                others.removeLast()
            }
        }
    }

    public func validate(_ state: IslandActivityContent) throws {
        guard state.phase == .working || state.phase == .needsInput,
              state.workingCount >= 0, state.waitingCount >= 0 else { throw IslandActivityError.invalidContent }
        let total = state.workingCount.addingReportingOverflow(state.waitingCount)
        guard !total.overflow, total.partialValue > 0,
              (state.phase == .working ? state.workingCount : state.waitingCount) > 0 else {
            throw IslandActivityError.invalidContent
        }
        let others = state.otherSessions ?? []
        guard others.count <= Self.maximumOtherSessions else { throw IslandActivityError.invalidContent }
        let sessions = [state.primarySession] + others
        guard Set(sessions.map(\.id)).count == sessions.count,
              sessions.filter({ $0.phase == .working }).count <= state.workingCount,
              sessions.filter({ $0.phase == .needsInput }).count <= state.waitingCount else {
            throw IslandActivityError.invalidContent
        }
        try sessions.forEach { try $0.validate(at: state.updatedAt) }
        let encoded = try EventCodec.jsonEncoder().encode(state)
        guard encoded.count <= maximumContentBytes else { throw IslandActivityError.contentBudgetExceeded }
    }
}
