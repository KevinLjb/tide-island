import Foundation

/// Codex `notify` currently reports a finished turn, not proof of task/test success.
public struct CodexNotification: Decodable, Sendable {
    public let type: String
    public let threadID: String
    public let cwd: String

    enum CodingKeys: String, CodingKey {
        case type, cwd
        case threadID = "thread-id"
    }

    public func event(at date: Date = Date(), waveBlockID: String? = nil) throws -> AgentEvent {
        guard type == "agent-turn-complete" else { throw EventError.unsupportedNotification }
        let name = URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
        let event = AgentEvent(
            sessionID: threadID,
            projectName: name.isEmpty ? "Codex" : name,
            phase: .completed,
            occurredAt: date,
            waveBlockID: waveBlockID
        )
        try event.validate()
        return event
    }
}
