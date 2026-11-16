import Foundation

/// Codex `notify` currently reports a finished turn, not proof of task/test success.
public struct CodexNotification: Decodable, Sendable {
    public let type: String
    public let threadID: String
    public let turnID: String?
    public let cwd: String

    enum CodingKeys: String, CodingKey {
        case type, cwd
        case threadID = "thread-id"
        case turnID = "turn-id"
    }

    public func event(at date: Date = Date(), waveBlockID: String? = nil) throws -> AgentEvent {
        guard type == "agent-turn-complete" else { throw EventError.unsupportedNotification }
        let name = try CodexHookAdapter.projectName(from: cwd)
        let event = AgentEvent(
            version: AgentEvent.currentVersion,
            sessionID: threadID,
            projectName: name,
            phase: .completed,
            occurredAt: date,
            waveBlockID: waveBlockID,
            context: EventContext(
                source: .codexNotify, kind: .turnCompleted, receivedAt: date, turnID: turnID
            )
        )
        try event.validate()
        return event
    }
}
