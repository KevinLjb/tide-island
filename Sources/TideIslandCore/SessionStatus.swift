import Foundation

/// Recent observed activity, not proof that a provider process is alive.
public enum SessionActivityState: String, Codable, Hashable, Sendable {
    case working
    case needsInput
    case idle
    case ended
    case unknown
}

public enum SessionFreshness: String, Codable, Hashable, Sendable {
    case fresh
    case stale
    case expired
    case clockSkew
}

public enum SessionSourceIssue: String, Equatable, Sendable {
    case channelUnavailable
    case eventMissing
}

/// A time-dependent projection. The original event and turn state stay intact.
public struct SessionStatus: Identifiable, Equatable, Sendable {
    public let session: AgentSession
    public let activity: SessionActivityState
    public let freshness: SessionFreshness
    public let freshUntil: Date
    public let expiresAt: Date?
    public let nextTransitionAt: Date?
    public internal(set) var sourceIssue: SessionSourceIssue?
    public internal(set) var attention = SessionAttention()

    public var id: String { session.id }

    public var title: String {
        activity == .unknown ? "状态待确认" : session.phase.title
    }

    public var symbolName: String {
        activity == .unknown ? "clock" : session.phase.symbolName
    }

    public var detail: String? {
        if sourceIssue == .channelUnavailable { return "事件通道暂不可确认；保留原记录，暂停实时计数。" }
        if sourceIssue == .eventMissing { return "当前目录中缺少这条记录；等待新的状态确认。" }
        if freshness == .clockSkew { return "事件时间晚于当前时钟，暂无法确认状态。" }
        if activity == .unknown { return "最近记录：\(session.phase.title)；等待新的状态确认。" }
        if freshness == .stale { return "历史状态记录；会话是否仍在运行尚未确认。" }
        return nil
    }

    public var isLiveActivity: Bool {
        sourceIssue == nil && freshness == .fresh && (activity == .working || activity == .needsInput)
    }

    func confirming(_ issue: SessionSourceIssue?) -> SessionStatus {
        let uncertain = issue != nil && (session.phase == .working || session.phase == .needsInput)
        var result = SessionStatus(session: session, activity: uncertain ? .unknown : activity,
                                   freshness: freshness, freshUntil: freshUntil,
                                   expiresAt: expiresAt, nextTransitionAt: nextTransitionAt)
        result.sourceIssue = issue
        return result
    }
}

public struct SessionSnapshot: Equatable, Sendable {
    public let sessions: [SessionStatus]
    public let ignoredSessions: [SessionStatus]
    public let preferredSessionID: String?
    public let nextTransitionAt: Date?

    public var workingCount: Int { sessions.filter { $0.isLiveActivity && $0.activity == .working }.count }
    public var waitingCount: Int { sessions.filter { $0.isLiveActivity && $0.activity == .needsInput }.count }
    public var unknownCount: Int { sessions.filter { $0.activity == .unknown }.count }
    public var unreadCount: Int { sessions.filter { $0.attention.isUnread }.count }
    public var selectedSession: SessionStatus? { sessions.first { $0.attention.isSelected } }

    public var activitySession: SessionStatus? {
        if let waiting = sessions.first(where: { $0.isLiveActivity && $0.activity == .needsInput }) { return waiting }
        if let selectedSession, selectedSession.isLiveActivity { return selectedSession }
        return sessions.first(where: \.isLiveActivity)
    }

    public var activitySelectionReason: SessionAttentionReason? {
        guard let activitySession else { return nil }
        if activitySession.activity == .needsInput { return .needsInput }
        if activitySession.attention.isSelected { return .selected }
        return activitySession.attention.isPinned ? .pinned : .working
    }

    /// A suspended app must not leave aggregate counts fresh beyond the first
    /// participating session's deadline, even when the highlighted one is newer.
    public var activityStaleAt: Date? {
        sessions.filter(\.isLiveActivity).map(\.freshUntil).min()
    }
}

public struct SessionStatusPolicy: Sendable {
    public static let standard = SessionStatusPolicy()
    public let freshFor: TimeInterval = 5 * 60
    public let idleRetention: TimeInterval = 24 * 60 * 60
    public let endedRetention: TimeInterval = 60 * 60

    public init() {}

    public func status(for session: AgentSession, at now: Date) -> SessionStatus {
        let freshUntil = session.updatedAt.addingTimeInterval(freshFor)
        let expiresAt: Date?
        switch session.phase {
        case .working, .needsInput: expiresAt = nil
        case .completed, .failed, .interrupted: expiresAt = session.updatedAt.addingTimeInterval(idleRetention)
        case .ended: expiresAt = session.updatedAt.addingTimeInterval(endedRetention)
        }
        let activity: SessionActivityState
        let freshness: SessionFreshness
        let next: Date?
        let age = now.timeIntervalSince(session.updatedAt)
        if !age.isFinite || age < 0 {
            // Re-evaluate on new input, activation or wake. Do not schedule a
            // possibly unbounded sleep or assert activity from a future clock.
            activity = .unknown
            freshness = .clockSkew
            next = nil
        } else if let expiresAt, now >= expiresAt {
            activity = session.phase == .ended ? .ended : .idle
            freshness = .expired
            next = nil
        } else {
            freshness = now < freshUntil ? .fresh : .stale
            switch session.phase {
            case .working: activity = freshness == .fresh ? .working : .unknown
            case .needsInput: activity = freshness == .fresh ? .needsInput : .unknown
            case .completed, .failed, .interrupted: activity = .idle
            case .ended: activity = .ended
            }
            next = freshness == .fresh ? freshUntil : expiresAt
        }
        return SessionStatus(session: session, activity: activity, freshness: freshness,
                             freshUntil: freshUntil, expiresAt: expiresAt, nextTransitionAt: next)
    }
}
