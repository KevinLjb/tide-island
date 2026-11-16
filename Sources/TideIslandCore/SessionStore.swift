import Foundation

/// The app's shared receive/project path. Re-reading a batch never assigns a
/// new event time, and silence never deletes an unresolved turn.
public struct SessionStore: Sendable {
    private var registry = SessionRegistry()
    private var preferences: [String: SessionPreference] = [:]
    private var preferredSessionID: String?
    public let policy: SessionStatusPolicy

    public init(policy: SessionStatusPolicy = .standard) {
        self.policy = policy
    }

    public mutating func receive(_ events: [AgentEvent]) throws {
        for event in events { try registry.apply(event) }
    }

    public func snapshot(at now: Date) -> SessionSnapshot {
        SessionAttentionPolicy.snapshot(statuses: registry.sessions.map { policy.status(for: $0, at: now) },
                                        preferences: preferences, preferredSessionID: preferredSessionID)
    }

    /// False means the row is missing, expired, superseded, or the action does
    /// not apply. No newer observation is acknowledged by a stale UI action.
    @discardableResult
    public mutating func perform(_ action: SessionAction, for reference: SessionReference, at now: Date) -> Bool {
        guard let session = registry.sessions.first(where: { $0.id == reference.sessionID }),
              session.lastEventID == reference.eventID else { return false }
        let status = policy.status(for: session, at: now)
        guard status.freshness != .expired else { return false }
        var preference = preferences[session.id] ?? SessionPreference()
        let ignored = preference.ignoredEventID == session.lastEventID
        switch action {
        case .markRead, .markUnread:
            guard status.hasAttentionItem, !ignored else { return false }
            preference.readEventID = action == .markRead ? session.lastEventID : nil
        case .pin: preference.isPinned = true
        case .unpin: preference.isPinned = false
        case .ignore:
            preference.ignoredEventID = session.lastEventID
            if preferredSessionID == session.id { preferredSessionID = nil }
        case .restore: preference.ignoredEventID = nil
        case .select:
            guard !ignored else { return false }
            preferredSessionID = session.id
            if status.hasAttentionItem { preference.readEventID = session.lastEventID }
        }
        preferences[session.id] = preference
        return true
    }

    public mutating func clearSelection() {
        preferredSessionID = nil
    }
}
