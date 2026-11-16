import Foundation

public enum EventSource: String, Codable, Equatable, Sendable {
    case manual
    case codexHook
    case codexNotify
}

public enum EventKind: String, Codable, Equatable, Sendable {
    case status
    case turnStarted
    case toolStarted
    case toolFinished
    case permissionRequested
    case turnCompleted
    case turnInterrupted
    case sessionEnded

    var expectedPhase: AgentPhase? {
        switch self {
        case .status: nil
        case .turnStarted, .toolStarted, .toolFinished: .working
        case .permissionRequested: .needsInput
        case .turnCompleted: .completed
        case .turnInterrupted: .interrupted
        case .sessionEnded: .ended
        }
    }
}

/// v2 metadata records what was observed, without copying provider messages.
/// Codex hook/notify inputs have no source timestamp in the pinned contract;
/// receivedAt is the bridge clock, and sourceOccurredAt stays nil.
public struct EventContext: Codable, Equatable, Sendable {
    public let source: EventSource
    public let kind: EventKind
    public let receivedAt: Date
    public let sourceOccurredAt: Date?
    public let turnID: String?
    public let toolName: String?
    public let toolUseID: String?

    public init(
        source: EventSource,
        kind: EventKind,
        receivedAt: Date,
        sourceOccurredAt: Date? = nil,
        turnID: String? = nil,
        toolName: String? = nil,
        toolUseID: String? = nil
    ) {
        self.source = source
        self.kind = kind
        self.receivedAt = receivedAt
        self.sourceOccurredAt = sourceOccurredAt
        self.turnID = turnID
        self.toolName = toolName
        self.toolUseID = toolUseID
    }

    func validate(phase: AgentPhase) throws {
        guard receivedAt.timeIntervalSince1970.isFinite,
              sourceOccurredAt?.timeIntervalSince1970.isFinite != false
        else { throw EventError.invalidField("context.timestamp") }
        for (field, value) in [("turnID", turnID), ("toolName", toolName), ("toolUseID", toolUseID)] {
            if let value {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.utf8.count <= 256,
                      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else { throw EventError.invalidField("context." + field) }
            }
        }
        if let expected = kind.expectedPhase, phase != expected {
            throw EventError.invalidField("context.kind/phase")
        }
        switch source {
        case .manual:
            guard kind == .status else { throw EventError.invalidField("context.kind") }
        case .codexNotify:
            guard kind == .turnCompleted else { throw EventError.invalidField("context.kind") }
        case .codexHook:
            guard kind != .status, kind != .turnCompleted else {
                throw EventError.invalidField("context.kind")
            }
            if kind != .sessionEnded, turnID == nil {
                throw EventError.invalidField("context.turnID")
            }
        }
        if [EventKind.toolStarted, .toolFinished, .permissionRequested].contains(kind), toolName == nil {
            throw EventError.invalidField("context.toolName")
        }
        if [EventKind.toolStarted, .toolFinished].contains(kind), toolUseID == nil {
            throw EventError.invalidField("context.toolUseID")
        }
    }
}
