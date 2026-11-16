import CryptoKit
import Foundation

public enum SessionReminderKind: String, Equatable, Sendable {
    case needsInput, turnEnded
    init?(phase: AgentPhase) {
        switch phase {
        case .needsInput: self = .needsInput
        case .completed: self = .turnEnded
        default: return nil
        }
    }
}

public enum SessionReminderProblem: String, Error, Equatable, Sendable {
    case invalidClock, invalidSnapshot, capacityExceeded, authorizationNotRequested, permissionDenied, deliveryFailed
}

public struct SessionQuietHours: Codable, Equatable, Sendable {
    public let startMinute: Int
    public let endMinute: Int

    public init(startMinute: Int, endMinute: Int) throws {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute), startMinute != endMinute else {
            throw SessionReminderProblem.invalidSnapshot
        }
        self.startMinute = startMinute; self.endMinute = endMinute
    }
    private enum CodingKeys: String, CodingKey { case startMinute, endMinute }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(startMinute: fields.decode(Int.self, forKey: .startMinute), endMinute: fields.decode(Int.self, forKey: .endMinute))
    }
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard date.timeIntervalSince1970.isFinite else { return false }
        let fields = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = fields.hour, let minute = fields.minute else { return false }
        let value = hour * 60 + minute
        return startMinute < endMinute ? value >= startMinute && value < endMinute : value >= startMinute || value < endMinute
    }
}

/// Permission is requested only by an explicit native settings action.
public struct SessionReminderSettings: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let needsInput: Bool
    public let turnEnded: Bool
    public let sound: Bool
    public let quietHours: SessionQuietHours?

    public init(enabled: Bool = false, needsInput: Bool = true, turnEnded: Bool = true,
                sound: Bool = false, quietHours: SessionQuietHours? = nil) {
        self.enabled = enabled; self.needsInput = needsInput; self.turnEnded = turnEnded
        self.sound = sound; self.quietHours = quietHours
    }
}

/// Only an independently verified frontmost Wave block may supply this value.
/// App activation, selected/pinned rows, location metadata and focusblock's
/// acknowledgement do not establish this evidence. Native currently supplies nil.
public struct VerifiedSessionViewing: Sendable {
    public let reference: SessionReference
    public let blockID: UUID
    public let tabID: UUID
    public let observedAt: Date
    public let validUntil: Date

    public init(reference: SessionReference, blockID: UUID, tabID: UUID, observedAt: Date, validUntil: Date) {
        self.reference = reference; self.blockID = blockID; self.tabID = tabID
        self.observedAt = observedAt; self.validUntil = validUntil
    }

    func matches(_ status: SessionStatus, at now: Date) -> Bool {
        guard reference == status.reference, status.waveLocation.validity == .recent,
              let location = status.session.waveLocation,
              location.blockID == blockID, location.tabID == tabID,
              WaveLocationPolicy.standard.status(for: location, at: now).validity == .recent,
              observedAt.timeIntervalSince1970.isFinite, validUntil.timeIntervalSince1970.isFinite,
              observedAt <= now, now < validUntil, validUntil > observedAt,
              validUntil.timeIntervalSince(observedAt) <= 5 else { return false }
        return true
    }
}

public struct SessionReminder: Equatable, Sendable {
    public let reference: SessionReference
    public let episodeID: UUID
    public let kind: SessionReminderKind
    public let projectName: String
    public let occurredAt: Date
    public let sound: Bool
    public let sessionURL: URL

    public var title: String { kind == .needsInput ? "等待你处理" : "本轮已结束" }
    public var body: String { projectName }
    public var identifier: String {
        // Length-prefix the identity so delimiters in session IDs cannot alias.
        let id = reference.sessionID
        let value = "\(id.utf8.count):\(id):\(episodeID.uuidString):\(kind.rawValue)"
        return "tide-island.reminder." + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SessionReminderAuthorization: Equatable, Sendable { case notRequested, allowed, denied }

public protocol SessionReminderClient: Sendable {
    func authorization() async -> SessionReminderAuthorization
    func post(_ reminder: SessionReminder) async throws
}

/// A post acknowledgement is not proof that the OS displayed a banner/sound.
public struct SessionReminderDelivery: Equatable, Sendable {
    public let sourceSequence: UInt64?
    public let submittedCount: UInt64
    public let problem: SessionReminderProblem?
    public let stopped: Bool
}
