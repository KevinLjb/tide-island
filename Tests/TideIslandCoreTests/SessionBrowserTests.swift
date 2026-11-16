import Foundation
import Testing
@testable import TideIslandCore

private let browserEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func browserEmptySnapshotHasNoSessionsWithoutAnUnavailableProject() {
    let browser = SessionBrowserProjection(snapshot: .empty, preferences: .init(), at: browserEpoch)
    #expect(browser.emptyReason == .noSessions && browser.projectIsAvailable && browser.projects.isEmpty)
    #expect(browser.sessions.isEmpty && browser.unreadCount == 0 && browser.waitingCount == 0)
}

@Test func browserGroupsProjectNamesAndCountsEachVisibleAndIgnoredSession() {
    let a = browserStatus("a", "project-a", .working), b = browserStatus("b", "project-a", .needsInput)
    let ignored = browserStatus("c", "project-b", .needsInput, ignored: true)
    let snapshot = browserSnapshot([a, b], ignored: [ignored])
    let browser = SessionBrowserProjection(snapshot: snapshot, preferences: .init(), at: browserEpoch)
    #expect(browser.projects.count == 2 && browser.projects.map(\.title) == ["project-a", "project-b"])
    #expect(browser.projects[0].sessionCount == 2 && browser.projects[1].ignoredCount == 1)
    #expect(browser.unreadCount == 1 && browser.waitingCount == 1)
}

@Test func browserFilteringKeepsSourceOrderReferencesAndAttentionUnchanged() {
    let waiting = browserStatus("waiting", "a", .needsInput), working = browserStatus("working", "a", .working)
    let other = browserStatus("other", "b", .completed)
    let snapshot = browserSnapshot([waiting, other, working])
    let browser = SessionBrowserProjection(snapshot: snapshot, preferences: .init(), projectID: SessionBrowserProjection.projectID(for: "a"), at: browserEpoch)
    #expect(browser.sessions.map(\.reference) == [waiting.reference, working.reference])
    #expect(snapshot.sessions == [waiting, other, working] && browser.unreadCount == 1 && browser.waitingCount == 1)
    #expect(!waiting.attention.isSelected && waiting.attention.isUnread)
}

@Test func browserHiddenProjectChoicesNeverExposeTheSourceNameAndKeepStableFilterIdentity() {
    let snapshot = browserSnapshot([browserStatus("a", "fixture-private-a", .working), browserStatus("b", "fixture-private-b", .needsInput)])
    let normal = SessionBrowserProjection(snapshot: snapshot, preferences: .init(), at: browserEpoch)
    let preferences = AppPreferences(reminders: .init(showsProjectName: false))
    let hidden = SessionBrowserProjection(snapshot: snapshot, preferences: preferences, at: browserEpoch)
    #expect(Set(hidden.projects.map(\.id)) == Set(normal.projects.map(\.id)))
    #expect(hidden.projects.map(\.title) == ["项目 1", "项目 2"])
    #expect(hidden.projects.allSatisfy { !$0.title.contains("fixture-private") && !$0.id.contains("fixture-private") })
}

@Test func browserCanonicallyEquivalentUnicodeProjectNamesShareOneFilter() {
    let composed = "caf\u{00e9}", decomposed = "cafe\u{0301}"
    let snapshot = browserSnapshot([browserStatus("a", composed, .working), browserStatus("b", decomposed, .working)])
    let key = SessionBrowserProjection.projectID(for: composed)
    let browser = SessionBrowserProjection(snapshot: snapshot, preferences: .init(), projectID: key, at: browserEpoch)
    #expect(key == SessionBrowserProjection.projectID(for: decomposed) && browser.projects.count == 1 && browser.sessions.count == 2)
    #expect(Array(snapshot.sessions[1].session.projectName.utf8) == Array(decomposed.utf8))
}

@Test func browserDistinctCaseSensitiveNamesRemainDistinctDisplayGroups() {
    let snapshot = browserSnapshot([browserStatus("a", "Core", .working), browserStatus("b", "core", .working)])
    let browser = SessionBrowserProjection(snapshot: snapshot, preferences: .init(), at: browserEpoch)
    #expect(browser.projects.count == 2 && browser.projects[0].id != browser.projects[1].id)
}

@Test func browserUnavailableProjectDoesNotSilentlyExposeAllProjects() {
    let snapshot = browserSnapshot([browserStatus("a", "a", .needsInput)])
    let browser = SessionBrowserProjection(snapshot: snapshot, preferences: .init(), projectID: "obsolete-filter", at: browserEpoch)
    #expect(browser.emptyReason == .unavailableProject && !browser.projectIsAvailable && browser.sessions.isEmpty)
    #expect(browser.projects.count == 1 && browser.unreadCount == 0 && browser.waitingCount == 0)
}

@Test func browserIgnoredOnlyStateOffersDisplayWithoutRestoringTheObservation() {
    let ignored = browserStatus("a", "a", .needsInput, ignored: true)
    let snapshot = browserSnapshot([], ignored: [ignored])
    let hidden = SessionBrowserProjection(snapshot: snapshot, preferences: .init(), at: browserEpoch)
    let shown = SessionBrowserProjection(snapshot: snapshot, preferences: .init(), showsIgnored: true, at: browserEpoch)
    #expect(hidden.emptyReason == .ignoredOnly && shown.emptyReason == .none)
    #expect(shown.ignoredSessions == [ignored] && shown.sessions.isEmpty && shown.unreadCount == 0 && shown.waitingCount == 0)
    #expect(snapshot.ignoredSessions[0].attention.isIgnored)
}

@Test func browserHiddenHistoryHasADistinctEmptyStateAndDoesNotEraseSourceData() {
    let at = browserEpoch.addingTimeInterval(7200)
    let status = browserStatus("a", "a", .completed, projectedAt: at)
    let snapshot = browserSnapshot([status])
    let browser = SessionBrowserProjection(snapshot: snapshot, preferences: .init(historyVisibility: .oneHour), at: at)
    #expect(browser.emptyReason == .hiddenHistory && browser.projects.isEmpty && browser.sessions.isEmpty)
    #expect(snapshot.sessions.count == 1 && snapshot.sessions[0].session.updatedAt == browserEpoch)
}

@Test func browserUnconfirmedWorkRemainsVisibleAfterTheHistoryDisplayWindow() {
    let at = browserEpoch.addingTimeInterval(7200)
    let status = browserStatus("a", "a", .working, projectedAt: at)
    let browser = SessionBrowserProjection(snapshot: browserSnapshot([status]), preferences: .init(historyVisibility: .oneHour), at: at)
    #expect(browser.emptyReason == .none && browser.sessions.count == 1 && browser.sessions[0].activity == .unknown)
    #expect(browser.waitingCount == 0)
}

@Test func browserFilteringCannotChangeTheGloballyPreferredSession() {
    let a = browserStatus("a", "a", .working, selected: true), b = browserStatus("b", "b", .working)
    let snapshot = browserSnapshot([a, b], preferred: "a")
    let browser = SessionBrowserProjection(snapshot: snapshot, preferences: .init(), projectID: SessionBrowserProjection.projectID(for: "b"), at: browserEpoch)
    #expect(browser.sessions.map(\.id) == ["b"] && !browser.sessions[0].attention.isSelected)
    #expect(snapshot.preferredSessionID == "a" && snapshot.selectedSession?.reference == a.reference)
}

@Test func browserInvalidClockUsesAnExplicitEmptyState() {
    let snapshot = browserSnapshot([browserStatus("a", "a", .working)])
    let browser = SessionBrowserProjection(snapshot: snapshot, preferences: .init(), at: Date(timeIntervalSince1970: .nan))
    #expect(browser.emptyReason == .invalidClock && browser.sessions.isEmpty && browser.projects.isEmpty)
    #expect(snapshot.sessions.count == 1)
}

@Test func browserUnconfirmedWaitingObservationsDoNotEnterLiveWaitingCounts() {
    let status = browserStatus("a", "a", .needsInput, issue: .channelUnavailable)
    let browser = SessionBrowserProjection(snapshot: browserSnapshot([status]), preferences: .init(), at: browserEpoch)
    #expect(browser.sessions.count == 1 && browser.unreadCount == 1 && browser.waitingCount == 0)
    #expect(browser.sessions[0].sourceIssue == .channelUnavailable && browser.sessions[0].activity == .unknown)
}

@Test func browserSessionLabelsAreStableOpaqueAndNeverUsedAsTheReferenceIdentity() {
    let first = "private/path/session?token=fixture", second = "different-session"
    let label = SessionBrowserProjection.sessionLabel(for: first)
    #expect(label == SessionBrowserProjection.sessionLabel(for: first) && label != SessionBrowserProjection.sessionLabel(for: second))
    #expect(!label.contains("private") && !label.contains("fixture") && label.count <= 20)
    let status = browserStatus(first, "project", .working)
    let projection = SessionBrowserProjection(snapshot: browserSnapshot([status]), preferences: .init(), at: browserEpoch)
    #expect(projection.sessions.first?.reference == status.reference && status.id == first)
}

private func browserStatus(_ id: String, _ project: String, _ phase: AgentPhase, ignored: Bool = false, selected: Bool = false,
                           issue: SessionSourceIssue? = nil, projectedAt: Date = browserEpoch) -> SessionStatus {
    let event = AgentEvent(version: 2, sessionID: id, projectName: project, phase: phase, occurredAt: browserEpoch,
                           context: .init(source: .manual, kind: .status, receivedAt: browserEpoch))
    var status = SessionStatusPolicy.standard.status(for: AgentSession(event: event), at: projectedAt).confirming(issue)
    status.attention = SessionAttention(isUnread: status.hasAttentionItem, isIgnored: ignored, isSelected: selected)
    return status
}
private func browserSnapshot(_ statuses: [SessionStatus], ignored: [SessionStatus] = [], preferred: String? = nil) -> SessionSnapshot {
    .init(sessions: statuses, ignoredSessions: ignored, preferredSessionID: preferred, nextTransitionAt: nil)
}
