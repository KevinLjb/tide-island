import Foundation

/// Actions refer to the exact observation the user saw, not a newer reminder
/// that might arrive between rendering a row and clicking its controls.
public struct SessionReference: Equatable, Sendable {
    public let sessionID: String
    public let eventID: UUID

    public init(sessionID: String, eventID: UUID) {
        self.sessionID = sessionID
        self.eventID = eventID
    }
}

public enum SessionAction: Equatable, Sendable {
    case markRead
    case markUnread
    case pin
    case unpin
    case ignore
    case restore
    case select
}

public struct SessionAttention: Equatable, Sendable {
    public let isUnread: Bool
    public let isPinned: Bool
    public let isIgnored: Bool
    public let isSelected: Bool

    public init(isUnread: Bool = false, isPinned: Bool = false, isIgnored: Bool = false, isSelected: Bool = false) {
        self.isUnread = isUnread
        self.isPinned = isPinned
        self.isIgnored = isIgnored
        self.isSelected = isSelected
    }
}

public enum SessionAttentionReason: Int, Equatable, Sendable {
    case needsInput
    case pinned
    case unread
    case selected
    case working
    case unconfirmed
    case unreadHistory
    case history
    case ignored

    public var title: String {
        switch self {
        case .needsInput: "待处理优先"
        case .pinned: "已置顶"
        case .unread: "未读提醒"
        case .selected: "已选择"
        case .working: "当前工作"
        case .unconfirmed: "状态待确认"
        case .unreadHistory: "未读历史记录"
        case .history: "已读或历史记录"
        case .ignored: "已忽略当前状态"
        }
    }
}

struct SessionPreference: Codable, Sendable {
    var readEventID: UUID?
    var ignoredEventID: UUID?
    var isPinned = false
}

extension SessionStatus {
    public var reference: SessionReference { SessionReference(sessionID: id, eventID: session.lastEventID) }

    public var hasAttentionItem: Bool {
        switch session.phase {
        case .needsInput, .completed, .failed, .interrupted: true
        case .working, .ended: false
        }
    }

    public var attentionReason: SessionAttentionReason {
        if attention.isIgnored { return .ignored }
        if isLiveActivity && activity == .needsInput { return .needsInput }
        if attention.isPinned { return .pinned }
        if freshness == .fresh && attention.isUnread { return .unread }
        if attention.isSelected && (isLiveActivity || activity == .unknown) { return .selected }
        if isLiveActivity { return .working }
        if activity == .unknown { return .unconfirmed }
        if attention.isUnread { return .unreadHistory }
        return .history
    }
}

enum SessionAttentionPolicy {
    static func snapshot(statuses: [SessionStatus], preferences: [String: SessionPreference],
                         preferredSessionID: String?) -> SessionSnapshot {
        let statuses = statuses.filter { $0.freshness != .expired }.map { original in
            var status = original
            let preference = preferences[status.id] ?? SessionPreference()
            let ignored = preference.ignoredEventID == status.session.lastEventID
            status.attention = SessionAttention(
                isUnread: status.hasAttentionItem && preference.readEventID != status.session.lastEventID,
                isPinned: preference.isPinned,
                isIgnored: ignored,
                isSelected: !ignored && status.id == preferredSessionID
            )
            return status
        }.sorted(by: precedes)
        return SessionSnapshot(
            sessions: statuses.filter { !$0.attention.isIgnored },
            ignoredSessions: statuses.filter { $0.attention.isIgnored },
            preferredSessionID: preferredSessionID,
            nextTransitionAt: statuses.compactMap(\.nextTransitionAt).min()
        )
    }

    private static func precedes(_ left: SessionStatus, _ right: SessionStatus) -> Bool {
        if left.attentionReason != right.attentionReason { return left.attentionReason.rawValue < right.attentionReason.rawValue }
        // Within the urgent waiting group, an explicit selection wins before
        // pins. Outside that group the reason already encodes the main tier.
        if left.attention.isSelected != right.attention.isSelected { return left.attention.isSelected }
        if left.attention.isPinned != right.attention.isPinned { return left.attention.isPinned }
        if left.session.phase.attentionPriority != right.session.phase.attentionPriority {
            return left.session.phase.attentionPriority < right.session.phase.attentionPriority
        }
        if left.session.updatedAt != right.session.updatedAt { return left.session.updatedAt > right.session.updatedAt }
        return left.id < right.id
    }
}
