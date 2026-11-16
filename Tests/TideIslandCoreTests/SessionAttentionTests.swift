import Foundation
import Testing
@testable import TideIslandCore

private let attentionEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func onlyActionableObservationsStartUnreadAndReadCompletionStopsOutrankingWork() throws {
    for phase in [AgentPhase.completed, .failed, .interrupted] {
        var store = SessionStore()
        try store.receive([attentionEvent(phase, id: "notice"), attentionEvent(.working, id: "work")])
        let before = store.snapshot(at: attentionEpoch)
        #expect(before.sessions.map(\.id) == ["notice", "work"])
        #expect(before.unreadCount == 1)
        let notice = try attentionRow(store, id: "notice")
        #expect(notice.attentionReason == .unread)
        #expect(store.perform(.markRead, for: notice.reference, at: attentionEpoch))
        let after = store.snapshot(at: attentionEpoch)
        #expect(after.sessions.map(\.id) == ["work", "notice"])
        #expect(after.unreadCount == 0)
        #expect(after.sessions.last?.attentionReason == .history)
        #expect(after.sessions.last?.session == notice.session)
        #expect(store.perform(.markUnread, for: notice.reference, at: attentionEpoch))
        #expect(store.snapshot(at: attentionEpoch) == before)
        #expect(store.perform(.select, for: notice.reference, at: attentionEpoch))
        #expect(store.snapshot(at: attentionEpoch).sessions.map(\.id) == ["work", "notice"])
        #expect(store.snapshot(at: attentionEpoch).selectedSession?.id == "notice")
    }
    var store = SessionStore()
    try store.receive([attentionEvent(.working, id: "work"), attentionEvent(.ended, id: "exit")])
    #expect(store.snapshot(at: attentionEpoch).unreadCount == 0)
    let working = try attentionRow(store, id: "work")
    #expect(!store.perform(.markRead, for: working.reference, at: attentionEpoch))
    #expect(!store.perform(.markUnread, for: working.reference, at: attentionEpoch))
}

@Test func readingOrSelectingWaitingDoesNotResolveItAndPinsCannotHideIt() throws {
    var store = SessionStore()
    try store.receive([attentionEvent(.working, id: "work"), attentionEvent(.needsInput, id: "wait")])
    let working = try attentionRow(store, id: "work")
    let waiting = try attentionRow(store, id: "wait")
    #expect(store.perform(.pin, for: working.reference, at: attentionEpoch))
    #expect(store.perform(.select, for: working.reference, at: attentionEpoch))
    #expect(store.perform(.markRead, for: waiting.reference, at: attentionEpoch))
    let snapshot = store.snapshot(at: attentionEpoch)
    #expect(snapshot.sessions.map(\.id) == ["wait", "work"])
    #expect(snapshot.selectedSession?.id == "work")
    #expect(snapshot.activitySession?.id == "wait")
    #expect(snapshot.activitySelectionReason == .needsInput)
    #expect(snapshot.waitingCount == 1 && snapshot.unreadCount == 0)
    #expect(snapshot.sessions.first?.attentionReason == .needsInput)
}

@Test func explicitSelectionWithinTheWaitingGroupWinsBeforeAnotherWaitingPin() throws {
    var store = SessionStore()
    try store.receive([attentionEvent(.needsInput, id: "a"), attentionEvent(.needsInput, id: "b")])
    let first = try attentionRow(store, id: "a"), second = try attentionRow(store, id: "b")
    #expect(store.perform(.pin, for: first.reference, at: attentionEpoch))
    #expect(store.perform(.select, for: second.reference, at: attentionEpoch))
    let snapshot = store.snapshot(at: attentionEpoch)
    #expect(snapshot.sessions.map(\.id) == ["b", "a"])
    #expect(snapshot.activitySession?.id == "b")
    #expect(snapshot.unreadCount == 1 && snapshot.waitingCount == 2)
    store.clearSelection()
    #expect(store.snapshot(at: attentionEpoch).activitySession?.id == "a")
}

@Test func acknowledgementsReferToOneReminderAndNewRequestsRemainUnreadWhileSelected() throws {
    var store = SessionStore()
    let first = attentionHook(.permissionRequested, turn: "one", time: 0)
    try store.receive([first])
    let seen = try attentionRow(store, id: "session")
    #expect(store.perform(.select, for: seen.reference, at: attentionEpoch))
    #expect(store.snapshot(at: attentionEpoch).unreadCount == 0)
    let next = attentionHook(.permissionRequested, turn: "one", time: 1)
    try store.receive([next])
    let now = attentionEpoch.addingTimeInterval(1)
    let snapshot = store.snapshot(at: now)
    #expect(snapshot.unreadCount == 1 && snapshot.selectedSession?.id == "session")
    #expect(!store.perform(.markRead, for: seen.reference, at: now))
    #expect(!store.perform(.select, for: seen.reference, at: now))
    #expect(store.snapshot(at: now) == snapshot)
    let current = try attentionRow(store, id: "session", at: now)
    #expect(store.perform(.markRead, for: current.reference, at: now))
    try store.receive([first, next])
    #expect(store.snapshot(at: now).unreadCount == 0)
}

@Test func pinSurvivesNewTurnsButReadAndIgnoreNeverAcknowledgeTheirNewCompletion() throws {
    var store = SessionStore()
    let previous = attentionHook(.turnCompleted, turn: "one", time: 0)
    try store.receive([previous])
    let row = try attentionRow(store, id: "session")
    #expect(store.perform(.pin, for: row.reference, at: attentionEpoch))
    #expect(store.perform(.markRead, for: row.reference, at: attentionEpoch))
    #expect(store.perform(.ignore, for: row.reference, at: attentionEpoch))
    try store.receive([attentionHook(.turnStarted, turn: "two", time: 1),
                       attentionHook(.turnCompleted, turn: "two", time: 2)])
    let now = attentionEpoch.addingTimeInterval(2)
    let new = try attentionRow(store, id: "session", at: now)
    #expect(new.attention.isPinned && new.attention.isUnread && !new.attention.isIgnored)
    #expect(new.session.turnID == "two")
    try store.receive([previous, attentionHook(.turnCompleted, turn: "one", time: 100)])
    #expect(try attentionRow(store, id: "session", at: now) == new)
}

@Test func ignoreIsRecoverableSuppressesCountsAndDoesNotRefreshTimeOrDeleteState() throws {
    var store = SessionStore()
    let event = attentionEvent(.needsInput, id: "wait")
    try store.receive([event])
    let row = try attentionRow(store, id: "wait")
    #expect(store.perform(.select, for: row.reference, at: attentionEpoch))
    #expect(store.perform(.ignore, for: row.reference, at: attentionEpoch))
    let ignored = store.snapshot(at: attentionEpoch)
    #expect(ignored.sessions.isEmpty && ignored.ignoredSessions.count == 1)
    #expect(ignored.waitingCount == 0 && ignored.unreadCount == 0 && ignored.activitySession == nil)
    #expect(ignored.preferredSessionID == nil)
    #expect(ignored.ignoredSessions.first?.attentionReason == .ignored)
    #expect(!store.perform(.select, for: row.reference, at: attentionEpoch))
    try store.receive([event])
    #expect(store.snapshot(at: attentionEpoch) == ignored)
    let later = attentionEpoch.addingTimeInterval(600)
    #expect(store.perform(.restore, for: row.reference, at: later))
    let restored = try attentionRow(store, id: "wait", at: later)
    #expect(restored.activity == .unknown && restored.session == row.session)
    #expect(!restored.attention.isUnread) // Restore preserves the earlier acknowledgement.
    #expect(store.snapshot(at: later).waitingCount == 0)
}

@Test func newVisibleToolStateReappearsAfterIgnoringWorkWithoutAcceptingStaleRestore() throws {
    var store = SessionStore()
    try store.receive([attentionHook(.turnStarted, turn: "one", time: 0)])
    let before = try attentionRow(store, id: "session")
    #expect(store.perform(.ignore, for: before.reference, at: attentionEpoch))
    try store.receive([attentionHook(.toolStarted, turn: "one", time: 1)])
    let now = attentionEpoch.addingTimeInterval(1)
    let after = store.snapshot(at: now)
    #expect(after.ignoredSessions.isEmpty && after.workingCount == 1)
    #expect(!store.perform(.restore, for: before.reference, at: now))
    #expect(!store.perform(.ignore, for: before.reference, at: now))
    #expect(store.snapshot(at: now) == after)
}

@Test func pinAndSelectionCannotRejuvenateStaleOrFutureObservations() throws {
    for now in [attentionEpoch.addingTimeInterval(600), attentionEpoch.addingTimeInterval(-1)] {
        var store = SessionStore()
        try store.receive([attentionEvent(.working, id: "old")])
        let row = try attentionRow(store, id: "old", at: now)
        #expect(store.perform(.pin, for: row.reference, at: now))
        #expect(store.perform(.select, for: row.reference, at: now))
        let snapshot = store.snapshot(at: now)
        #expect(snapshot.selectedSession?.id == "old")
        #expect(snapshot.sessions.first?.attentionReason == .pinned)
        #expect(snapshot.sessions.first?.activity == .unknown)
        #expect(snapshot.sessions.first?.session == row.session)
        #expect(snapshot.activitySession == nil && snapshot.activityStaleAt == nil && snapshot.workingCount == 0)
    }
}

@Test func selectionFallsBackOnStalenessAndExpirationAndAutomaticChoiceCanClearThePreference() throws {
    var store = SessionStore()
    try store.receive([attentionEvent(.working, id: "chosen"),
                       attentionEvent(.working, id: "other", time: 200)])
    let chosen = try attentionRow(store, id: "chosen", at: attentionEpoch.addingTimeInterval(200))
    #expect(store.perform(.select, for: chosen.reference, at: attentionEpoch.addingTimeInterval(200)))
    #expect(store.snapshot(at: attentionEpoch.addingTimeInterval(200)).activitySession?.id == "chosen")
    #expect(store.snapshot(at: attentionEpoch.addingTimeInterval(200)).activitySelectionReason == .selected)
    let stale = store.snapshot(at: attentionEpoch.addingTimeInterval(300))
    #expect(stale.selectedSession?.id == "chosen" && stale.activitySession?.id == "other")
    #expect(stale.activitySelectionReason == .working)

    let done = attentionEvent(.completed, id: "chosen", time: 301)
    try store.receive([done])
    let expiry = done.occurredAt.addingTimeInterval(SessionStatusPolicy.standard.idleRetention)
    let expired = store.snapshot(at: expiry)
    #expect(expired.selectedSession == nil && expired.preferredSessionID == "chosen")
    #expect(!store.perform(.select, for: SessionReference(sessionID: "chosen", eventID: done.id), at: expiry))
    store.clearSelection()
    #expect(store.snapshot(at: expiry).preferredSessionID == nil)
}

@Test func pinsDoNotExtendExpiryAndIgnoredDeadlinesStillRefreshTheRecoveryList() throws {
    var store = SessionStore()
    try store.receive([attentionEvent(.completed, id: "history")])
    let row = try attentionRow(store, id: "history")
    #expect(store.perform(.pin, for: row.reference, at: attentionEpoch))
    #expect(store.perform(.ignore, for: row.reference, at: attentionEpoch))
    let freshUntil = attentionEpoch.addingTimeInterval(SessionStatusPolicy.standard.freshFor)
    #expect(store.snapshot(at: attentionEpoch).nextTransitionAt == freshUntil)
    let expiry = attentionEpoch.addingTimeInterval(SessionStatusPolicy.standard.idleRetention)
    #expect(store.snapshot(at: freshUntil).nextTransitionAt == expiry)
    let expired = store.snapshot(at: expiry)
    #expect(expired.sessions.isEmpty && expired.ignoredSessions.isEmpty && expired.nextTransitionAt == nil)
    #expect(!store.perform(.restore, for: row.reference, at: expiry))
    #expect(!store.perform(.pin, for: row.reference, at: expiry))
}

@Test func attentionOrderHasStableTiesAndExplanationsAcrossArrivalOrders() throws {
    let events = [attentionEvent(.working, id: "work"), attentionEvent(.completed, id: "b"),
                  attentionEvent(.completed, id: "a"), attentionEvent(.failed, id: "failed"),
                  attentionEvent(.needsInput, id: "wait")]
    var first = SessionStore(), second = SessionStore()
    try first.receive(events)
    try second.receive(Array(events.reversed()))
    let left = first.snapshot(at: attentionEpoch), right = second.snapshot(at: attentionEpoch)
    #expect(left == right)
    #expect(left.sessions.map(\.id) == ["wait", "failed", "a", "b", "work"])
    #expect(left.sessions.map(\.attentionReason) == [.needsInput, .unread, .unread, .unread, .working])
    #expect(left.sessions.allSatisfy { !$0.attentionReason.title.isEmpty })
}

@Test func validActionsAreIdempotentAndUnknownOrSupersededReferencesHaveNoSideEffects() throws {
    var store = SessionStore()
    try store.receive([attentionEvent(.completed, id: "one")])
    let row = try attentionRow(store, id: "one")
    for action in [SessionAction.markRead, .markUnread, .pin, .unpin, .select, .ignore, .restore] {
        #expect(store.perform(action, for: row.reference, at: attentionEpoch))
        let once = store.snapshot(at: attentionEpoch)
        #expect(store.perform(action, for: row.reference, at: attentionEpoch))
        #expect(store.snapshot(at: attentionEpoch) == once)
    }
    let before = store.snapshot(at: attentionEpoch)
    for reference in [SessionReference(sessionID: "missing", eventID: row.session.lastEventID),
                      SessionReference(sessionID: row.id, eventID: UUID())] {
        for action in [SessionAction.markRead, .markUnread, .pin, .unpin, .select, .ignore, .restore] {
            #expect(!store.perform(action, for: reference, at: attentionEpoch))
        }
    }
    #expect(store.snapshot(at: attentionEpoch) == before)
}

@Test func ignoredSessionsDoNotContributeToTheAggregateStaleDeadline() throws {
    var store = SessionStore()
    try store.receive([attentionEvent(.working, id: "ignored"), attentionEvent(.working, id: "live", time: 100)])
    let now = attentionEpoch.addingTimeInterval(100)
    let old = try attentionRow(store, id: "ignored", at: now)
    #expect(store.perform(.ignore, for: old.reference, at: now))
    let snapshot = store.snapshot(at: now)
    #expect(snapshot.workingCount == 1 && snapshot.activitySession?.id == "live")
    #expect(snapshot.activityStaleAt == attentionEpoch.addingTimeInterval(400))
    #expect(snapshot.nextTransitionAt == attentionEpoch.addingTimeInterval(300))
}

@Test func preferencesAreInMemoryOnlyAndNeverChangeInboxEventBytes() throws {
    let root = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.temporaryDirectory
    let directory = root.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = EventInbox(directory: directory)
    let path = try inbox.write(attentionEvent(.completed, id: "one"))
    let bytes = try Data(contentsOf: path)
    var store = SessionStore()
    try store.receive(inbox.readRecent().events)
    let row = try attentionRow(store, id: "one")
    #expect(store.perform(.select, for: row.reference, at: attentionEpoch))
    #expect(store.perform(.pin, for: row.reference, at: attentionEpoch))
    #expect(store.perform(.ignore, for: row.reference, at: attentionEpoch))
    #expect(try Data(contentsOf: path) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    var restarted = SessionStore()
    try restarted.receive(inbox.readRecent().events)
    let restored = try attentionRow(restarted, id: "one")
    #expect(restored.attention.isUnread && !restored.attention.isPinned && !restored.attention.isIgnored)
    #expect(restarted.snapshot(at: attentionEpoch).preferredSessionID == nil)
}

private func attentionRow(_ store: SessionStore, id: String, at now: Date = attentionEpoch) throws -> SessionStatus {
    try #require(store.snapshot(at: now).sessions.first(where: { $0.id == id }))
}

private func attentionEvent(_ phase: AgentPhase, id: String, time: Double = 0) -> AgentEvent {
    let at = attentionEpoch.addingTimeInterval(time)
    return AgentEvent(version: 2, sessionID: id, projectName: "project", phase: phase, occurredAt: at,
                      context: EventContext(source: .manual, kind: .status, receivedAt: at))
}

private func attentionHook(_ kind: EventKind, turn: String, time: Double) -> AgentEvent {
    let at = attentionEpoch.addingTimeInterval(time)
    return AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: kind.expectedPhase!, occurredAt: at,
                      context: EventContext(source: kind == .turnCompleted ? .codexNotify : .codexHook, kind: kind,
                                            receivedAt: at, turnID: turn,
                                            toolName: kind == .permissionRequested || kind == .toolStarted ? "Bash" : nil,
                                            toolUseID: kind == .toolStarted ? UUID().uuidString : nil))
}
