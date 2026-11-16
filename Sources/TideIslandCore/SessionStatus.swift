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

/// A time-dependent projection. The original event and turn state stay intact.
public struct SessionStatus: Identifiable, Equatable, Sendable {
    public let session: AgentSession
    public let activity: SessionActivityState
    public let freshness: SessionFreshness
    public let freshUntil: Date
    public let expiresAt: Date?
    public let nextTransitionAt: Date?

    public var id: String { session.id }

    public var title: String {
        activity == .unknown ? "状态待确认" : session.phase.title
    }

    public var symbolName: String {
        activity == .unknown ? "clock" : session.phase.symbolName
    }

    public var detail: String? {
        if freshness == .clockSkew { return "事件时间晚于当前时钟，暂无法确认状态。" }
        if activity == .unknown { return "最近记录：\(session.phase.title)；等待新的状态确认。" }
        if freshness == .stale { return "历史状态记录；会话是否仍在运行尚未确认。" }
        return nil
    }

    public var isLiveActivity: Bool {
        freshness == .fresh && (activity == .working || activity == .needsInput)
    }
}

public struct SessionSnapshot: Equatable, Sendable {
    public let sessions: [SessionStatus]
    public let nextTransitionAt: Date?

    public var workingCount: Int { sessions.filter { $0.isLiveActivity && $0.activity == .working }.count }
    public var waitingCount: Int { sessions.filter { $0.isLiveActivity && $0.activity == .needsInput }.count }
    public var unknownCount: Int { sessions.filter { $0.activity == .unknown }.count }
    public var activitySession: SessionStatus? { sessions.first(where: \.isLiveActivity) }

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

    func snapshot(for sessions: [AgentSession], at now: Date) -> SessionSnapshot {
        let visible = sessions.map { status(for: $0, at: now) }
            .filter { $0.freshness != .expired }
            .sorted {
                let left = priority($0), right = priority($1)
                if left != right { return left < right }
                if $0.session.updatedAt != $1.session.updatedAt { return $0.session.updatedAt > $1.session.updatedAt }
                return $0.id < $1.id
            }
        return SessionSnapshot(sessions: visible, nextTransitionAt: visible.compactMap(\.nextTransitionAt).min())
    }

    private func priority(_ status: SessionStatus) -> Int {
        if status.freshness == .fresh { return status.session.phase.attentionPriority }
        return status.activity == .unknown ? 6 : 7
    }
}
