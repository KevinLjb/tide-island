import Foundation

/// The app's shared receive/project path. Re-reading a batch never assigns a
/// new event time, and silence never deletes an unresolved turn.
public struct SessionStore: Sendable {
    private var registry = SessionRegistry()
    public let policy: SessionStatusPolicy

    public init(policy: SessionStatusPolicy = .standard) {
        self.policy = policy
    }

    public mutating func receive(_ events: [AgentEvent]) throws {
        for event in events { try registry.apply(event) }
    }

    public func snapshot(at now: Date) -> SessionSnapshot {
        policy.snapshot(for: registry.sessions, at: now)
    }
}
