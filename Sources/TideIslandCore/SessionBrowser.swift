import CryptoKit
import Foundation

public struct SessionProjectChoice: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let sessionCount: Int
    public let ignoredCount: Int
}

public enum SessionBrowserEmptyReason: Equatable, Sendable {
    case none, noSessions, hiddenHistory, unavailableProject, ignoredOnly, invalidClock
}

/// Browsing is a display-only projection. It neither selects a session nor
/// marks an observation read, changes source freshness or reads the inbox.
public struct SessionBrowserProjection: Sendable {
    public let projects: [SessionProjectChoice]
    public let sessions: [SessionStatus]
    public let ignoredSessions: [SessionStatus]
    public let unreadCount: Int
    public let waitingCount: Int
    public let emptyReason: SessionBrowserEmptyReason
    public let projectIsAvailable: Bool

    public init(snapshot: SessionSnapshot, preferences: AppPreferences, projectID: String? = nil,
                showsIgnored: Bool = false, at now: Date) {
        let visible = preferences.visibleStatuses(snapshot.sessions, at: now)
        let ignored = preferences.visibleStatuses(snapshot.ignoredSessions, at: now)
        let groups = Dictionary(grouping: visible + ignored, by: { Self.projectID(for: $0.session.projectName) })
        let sorted = groups.sorted {
            if !preferences.reminders.showsProjectName { return $0.key < $1.key }
            let left = $0.value.first!.session.projectName.precomposedStringWithCanonicalMapping
            let right = $1.value.first!.session.projectName.precomposedStringWithCanonicalMapping
            return left != right ? left < right : $0.key < $1.key
        }
        projects = sorted.enumerated().map { index, group in
            SessionProjectChoice(id: group.key,
                title: preferences.reminders.showsProjectName ? group.value.first!.session.projectName : "项目 \(index + 1)",
                sessionCount: group.value.filter { !$0.attention.isIgnored }.count,
                ignoredCount: group.value.filter { $0.attention.isIgnored }.count)
        }
        projectIsAvailable = projectID.map({ groups[$0] != nil }) ?? true
        sessions = visible.filter { status in projectID.map { $0 == Self.projectID(for: status.session.projectName) } ?? true }
        ignoredSessions = ignored.filter { status in projectID.map { $0 == Self.projectID(for: status.session.projectName) } ?? true }
        unreadCount = sessions.filter { $0.attention.isUnread }.count
        waitingCount = sessions.filter { $0.isLiveActivity && $0.activity == .needsInput }.count
        if !now.timeIntervalSince1970.isFinite { emptyReason = .invalidClock }
        else if !projectIsAvailable { emptyReason = .unavailableProject }
        else if !sessions.isEmpty || (showsIgnored && !ignoredSessions.isEmpty) { emptyReason = .none }
        else if !ignoredSessions.isEmpty { emptyReason = .ignoredOnly }
        else if visible.isEmpty && ignored.isEmpty && !(snapshot.sessions + snapshot.ignoredSessions).isEmpty { emptyReason = .hiddenHistory }
        else { emptyReason = .noSessions }
    }

    /// Project names are display groups, not proof of a shared cwd/workspace.
    public static func projectID(for name: String) -> String { digest(name, domain: "project") }
    public static func sessionLabel(for id: String) -> String { "会话 " + String(digest(id, domain: "session").prefix(12)) }

    private static func digest(_ value: String, domain: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let data = Data("\(domain):\(normalized.utf8.count):\(normalized)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension SessionSnapshot {
    static var empty: Self { .init(sessions: [], ignoredSessions: [], preferredSessionID: nil, nextTransitionAt: nil) }
}
