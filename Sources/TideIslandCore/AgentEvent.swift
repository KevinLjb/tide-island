import Foundation

public enum AgentPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case working
    case needsInput
    case completed
    case failed
    case interrupted
    case ended

    public var title: String {
        switch self {
        case .working: "正在工作"
        case .needsInput: "等待你处理"
        case .completed: "本轮已结束"
        case .failed: "本轮发生异常"
        case .interrupted: "本轮已中断"
        case .ended: "会话已结束"
        }
    }

    public var symbolName: String {
        switch self {
        case .working: "waveform"
        case .needsInput: "hand.raised"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .interrupted: "pause.circle"
        case .ended: "stop.circle"
        }
    }

    public var attentionPriority: Int {
        switch self {
        case .needsInput: 0
        case .failed: 1
        case .interrupted: 2
        case .completed: 3
        case .working: 4
        case .ended: 5
        }
    }
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public let version: Int
    public let id: UUID
    public let sessionID: String
    public let projectName: String
    public let phase: AgentPhase
    public let occurredAt: Date
    public let waveBlockID: String?
    public let context: EventContext?

    public init(
        version: Int = 1,
        id: UUID = UUID(),
        sessionID: String,
        projectName: String,
        phase: AgentPhase,
        occurredAt: Date = Date(),
        waveBlockID: String? = nil,
        context: EventContext? = nil
    ) {
        self.version = version
        self.id = id
        self.sessionID = sessionID
        self.projectName = projectName
        self.phase = phase
        self.occurredAt = occurredAt
        self.waveBlockID = waveBlockID
        self.context = context
    }

    public func validate() throws {
        guard version == 1 || version == Self.currentVersion else {
            throw EventError.unsupportedVersion(version)
        }
        if version == 1 {
            guard context == nil, phase != .interrupted, phase != .ended else {
                throw EventError.invalidField("v1.context/phase")
            }
        } else {
            guard let context else { throw EventError.invalidField("context") }
            try context.validate(phase: phase)
        }
        guard occurredAt.timeIntervalSince1970.isFinite else {
            throw EventError.invalidField("occurredAt")
        }
        for (field, value, limit) in [
            ("sessionID", sessionID, 256),
            ("projectName", projectName, 160),
        ] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= limit,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw EventError.invalidField(field) }
        }
        if let waveBlockID {
            guard !waveBlockID.isEmpty, waveBlockID.utf8.count <= 256,
                  !waveBlockID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw EventError.invalidField("waveBlockID") }
        }
    }
}

public enum EventError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case invalidField(String)
    case unsupportedNotification
    case oversizedEvent
    case oversizedHookInput

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported event version: \(version)."
        case .invalidField(let field): "Invalid event field: \(field)."
        case .unsupportedNotification: "Only Codex agent-turn-complete notifications are supported."
        case .oversizedEvent: "Event exceeds the 16 KiB limit."
        case .oversizedHookInput: "Hook input exceeds the 1 MiB limit."
        }
    }
}

public enum EventCodec {
    public static let maximumBytes = 16 * 1024

    public static func encode(_ event: AgentEvent) throws -> Data {
        try event.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        guard data.count <= maximumBytes else { throw EventError.oversizedEvent }
        return data
    }

    public static func decode(_ data: Data) throws -> AgentEvent {
        guard data.count <= maximumBytes else { throw EventError.oversizedEvent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid event timestamp.")
        }
        let event = try decoder.decode(AgentEvent.self, from: data)
        try event.validate()
        return event
    }
}
