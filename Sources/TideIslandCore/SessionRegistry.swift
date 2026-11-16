import Foundation

public struct AgentSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let projectName: String
    public let phase: AgentPhase
    public let updatedAt: Date
    public let waveBlockID: String?
    public let lastEventID: UUID
    public let context: EventContext?

    public var turnID: String? { context?.turnID }

    init(event: AgentEvent) {
        id = event.sessionID
        projectName = event.projectName
        phase = event.phase
        updatedAt = event.occurredAt
        waveBlockID = event.waveBlockID
        lastEventID = event.id
        context = event.context
    }
}

public struct SessionRegistry: Sendable {
    private var storage: [String: AgentSession] = [:]

    public init() {}

    public var sessions: [AgentSession] {
        storage.values.sorted {
            if $0.phase.attentionPriority != $1.phase.attentionPriority {
                return $0.phase.attentionPriority < $1.phase.attentionPriority
            }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent) throws -> Bool {
        try event.validate()
        if let current = storage[event.sessionID] {
            guard current.lastEventID != event.id, event.occurredAt >= current.updatedAt else {
                return false
            }
        }
        storage[event.sessionID] = AgentSession(event: event)
        return true
    }
}
