import Foundation

public enum ReplayInputSource: String, Codable, Sendable {
    case hook
    case notify
    case event
}

public enum ReplayDisposition: String, Codable, Sendable {
    case applied
    case filtered
    case discarded
    case rejected
}

public enum ReplayInputError: String, Codable, Sendable {
    case invalidHook = "invalid-hook-input"
    case invalidNotify = "invalid-notify-input"
    case invalidEvent = "invalid-agent-event"
    case identityMismatch = "event-id-mismatch"
}

public struct ReplaySessionSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let projectName: String
    public let phase: AgentPhase
    public let updatedAt: Date
    public let lastEventID: UUID
    public let waveBlockID: String?
    public let waveLocation: WaveLocation?
    public let context: EventContext?
    public let turnID: String?

    init(_ session: AgentSession) {
        id = session.id
        projectName = session.projectName
        phase = session.phase
        updatedAt = session.updatedAt
        lastEventID = session.lastEventID
        waveBlockID = session.waveBlockID
        waveLocation = session.waveLocation
        context = session.context
        turnID = session.turnID
    }

    enum CodingKeys: String, CodingKey {
        case id, projectName, phase, updatedAt, lastEventID, waveBlockID, waveLocation, context, turnID
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        projectName = try fields.decode(String.self, forKey: .projectName)
        phase = try fields.decode(AgentPhase.self, forKey: .phase)
        updatedAt = try fields.decode(Date.self, forKey: .updatedAt)
        lastEventID = try fields.decode(UUID.self, forKey: .lastEventID)
        waveBlockID = try fields.decodeIfPresent(String.self, forKey: .waveBlockID)
        waveLocation = try fields.decodeIfPresent(WaveLocation.self, forKey: .waveLocation)
        context = try fields.decodeIfPresent(EventContext.self, forKey: .context)
        turnID = try fields.decodeIfPresent(String.self, forKey: .turnID) ?? context?.turnID
    }

    func validate() throws {
        try AgentEvent(
            version: context == nil ? 1 : AgentEvent.currentVersion,
            id: lastEventID, sessionID: id, projectName: projectName, phase: phase,
            occurredAt: updatedAt, waveBlockID: waveBlockID, waveLocation: waveLocation, context: context
        ).validate()
        try EventContext(source: .manual, kind: .status, receivedAt: updatedAt, turnID: turnID).validate(phase: phase)
    }
}

public struct ReplayExpectation: Codable, Equatable, Sendable {
    public let disposition: ReplayDisposition
    public let errorCode: ReplayInputError?
    public let sessions: [ReplaySessionSnapshot]
    public let registryDecision: SessionEventDecision?
}

public struct ReplayStepResult: Encodable, Equatable, Sendable {
    public let index: Int
    public let eventID: UUID
    public let receivedAt: Date
    public let source: ReplayInputSource
    public let disposition: ReplayDisposition
    public let errorCode: ReplayInputError?
    public let registryDecision: SessionEventDecision?
    public let event: AgentEvent?
    public let sessions: [ReplaySessionSnapshot]
    public let expected: ReplayExpectation
    public let mismatches: [String]
}

public struct ReplayScenarioResult: Encodable, Equatable, Sendable {
    public let name: String
    public let passed: Bool
    public let steps: [ReplayStepResult]
    public let finalSessions: [ReplaySessionSnapshot]
}

public struct ReplayReport: Encodable, Equatable, Sendable {
    public let schemaVersion = 1
    public let scope = "in-memory-adapters-codec-registry"
    public let passed: Bool
    public let scenarioCount: Int
    public let stepCount: Int
    public let mismatchCount: Int
    public let scenarios: [ReplayScenarioResult]
}

public enum ReplayError: Error, LocalizedError {
    case invalidFixture
    case scenarioNotFound
    case limitExceeded
    case unreadableFile
    case expectationMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidFixture: "Invalid replay fixture; expected a versioned scenario with explicit IDs, clocks and assertions."
        case .scenarioNotFound: "Replay scenario was not found."
        case .limitExceeded: "Replay fixture or report exceeds its resource limit."
        case .unreadableFile: "Replay input must be a readable regular file."
        case .expectationMismatch: "Replay expectations did not match; inspect the JSON report."
        }
    }
}
