import Foundation
import Testing
@testable import TideIslandCore

private let statusEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func recentObservationsDistinguishWorkWaitingIdleAndExplicitExit() throws {
    let expected: [(AgentPhase, SessionActivityState)] = [
        (.working, .working), (.needsInput, .needsInput), (.completed, .idle),
        (.failed, .idle), (.interrupted, .idle), (.ended, .ended),
    ]
    for (phase, activity) in expected {
        var store = SessionStore()
        try store.receive([statusEvent(phase, at: statusEpoch)])
        let snapshot = store.snapshot(at: statusEpoch.addingTimeInterval(1))
        let status = try #require(snapshot.sessions.first)
        #expect(status.activity == activity)
        #expect(status.freshness == .fresh)
        #expect(status.session.phase == phase)
        #expect(status.isLiveActivity == (phase == .working || phase == .needsInput))
        #expect(status.title == phase.title)
        #expect(snapshot.workingCount == (phase == .working ? 1 : 0))
        #expect(snapshot.waitingCount == (phase == .needsInput ? 1 : 0))
    }
}

@Test func silenceKeepsUnresolvedLongTurnsAsUnknownInsteadOfRemovingOrEndingThem() throws {
    for phase in [AgentPhase.working, .needsInput] {
        var store = SessionStore()
        let event = statusEvent(phase, at: statusEpoch)
        try store.receive([event])
        for elapsed in [15.0 * 60, 2 * 60 * 60, 90 * 24 * 60 * 60] {
            let snapshot = store.snapshot(at: statusEpoch.addingTimeInterval(elapsed))
            let status = try #require(snapshot.sessions.first)
            #expect(status.activity == .unknown)
            #expect(status.freshness == .stale)
            #expect(status.session.lastEventID == event.id)
            #expect(status.session.phase == phase)
            #expect(status.expiresAt == nil)
            #expect(status.title == "状态待确认")
            #expect(status.detail?.contains(phase.title) == true)
            #expect(snapshot.workingCount == 0 && snapshot.waitingCount == 0)
            #expect(snapshot.unknownCount == 1)
            #expect(snapshot.activitySession == nil && snapshot.activityStaleAt == nil)
            #expect(snapshot.nextTransitionAt == nil)
        }
    }
}

@Test func freshnessAndTerminalVisibilityHaveExactDeterministicDeadlines() throws {
    let policy = SessionStatusPolicy.standard
    for phase in [AgentPhase.working, .needsInput, .completed, .failed, .interrupted, .ended] {
        var store = SessionStore()
        try store.receive([statusEvent(phase, at: statusEpoch)])
        let freshUntil = statusEpoch.addingTimeInterval(policy.freshFor)
        let before = store.snapshot(at: freshUntil.addingTimeInterval(-0.001))
        #expect(before.sessions.first?.freshness == .fresh)
        #expect(before.nextTransitionAt == freshUntil)
        let atBoundary = store.snapshot(at: freshUntil)
        #expect(atBoundary.sessions.first?.freshness == .stale)
        if phase == .working || phase == .needsInput {
            #expect(atBoundary.sessions.first?.activity == .unknown)
            #expect(atBoundary.nextTransitionAt == nil)
        } else {
            let retention = phase == .ended ? policy.endedRetention : policy.idleRetention
            let expiry = statusEpoch.addingTimeInterval(retention)
            #expect(atBoundary.nextTransitionAt == expiry)
            #expect(store.snapshot(at: expiry.addingTimeInterval(-0.001)).sessions.count == 1)
            #expect(store.snapshot(at: expiry).sessions.isEmpty)
            #expect(store.snapshot(at: expiry).nextTransitionAt == nil)
        }
    }
}

@Test func expiryHidesHistoryWithoutDiscardingTurnGuardsOrReplayingItAsFresh() throws {
    var store = SessionStore()
    let end = scopedStatusEvent(.turnCompleted, turn: "old", at: statusEpoch)
    try store.receive([end])
    let now = statusEpoch.addingTimeInterval(2 * 24 * 60 * 60)
    #expect(store.snapshot(at: now).sessions.isEmpty)
    try store.receive([end, scopedStatusEvent(.toolStarted, turn: "old", at: now)])
    #expect(store.snapshot(at: now).sessions.isEmpty)
    try store.receive([scopedStatusEvent(.turnStarted, turn: "new", at: now)])
    let resumed = try #require(store.snapshot(at: now).sessions.first)
    #expect(resumed.activity == .working && resumed.freshness == .fresh)
    #expect(resumed.session.turnID == "new")
}

@Test func replayAndFilePublicationDoNotRenewTheOriginalEventClock() throws {
    var store = SessionStore()
    let old = scopedStatusEvent(.turnStarted, turn: "old", at: statusEpoch)
    try store.receive([old])
    let now = statusEpoch.addingTimeInterval(2 * 60 * 60)
    let stale = store.snapshot(at: now)
    for _ in 0..<3 { try store.receive([old]) }
    #expect(store.snapshot(at: now) == stale)
    try store.receive([scopedStatusEvent(.toolStarted, turn: "old", at: now)])
    #expect(store.snapshot(at: now).workingCount == 1)

    // A retired turn with a newer receipt clock cannot freshen the current one.
    try store.receive([scopedStatusEvent(.turnStarted, turn: "new", at: now)])
    let later = now.addingTimeInterval(10 * 60)
    try store.receive([scopedStatusEvent(.turnCompleted, turn: "old", at: later)])
    let current = try #require(store.snapshot(at: later).sessions.first)
    #expect(current.session.turnID == "new")
    #expect(current.activity == .unknown && current.session.updatedAt == now)
}

@Test func aNewReceiptTimestampDoesNotMakeAnOldSourceEventCurrent() throws {
    let now = statusEpoch.addingTimeInterval(2 * 60 * 60)
    let event = AgentEvent(
        version: 2, sessionID: "clock", projectName: "project", phase: .working, occurredAt: statusEpoch,
        context: EventContext(source: .codexHook, kind: .turnStarted, receivedAt: now,
                              sourceOccurredAt: statusEpoch, turnID: "one")
    )
    var store = SessionStore()
    try store.receive([event])
    #expect(store.snapshot(at: now).sessions.first?.activity == .unknown)
    #expect(store.snapshot(at: now).workingCount == 0)
}

@Test func futureClocksAndClockRollbackCannotAssertCurrentWorkOrScheduleAnUnboundedWait() throws {
    var store = SessionStore()
    try store.receive([statusEvent(.working, at: statusEpoch)])
    let snapshot = store.snapshot(at: statusEpoch.addingTimeInterval(-1))
    let status = try #require(snapshot.sessions.first)
    #expect(status.freshness == .clockSkew && status.activity == .unknown)
    #expect(snapshot.workingCount == 0 && snapshot.activityStaleAt == nil)
    #expect(snapshot.nextTransitionAt == nil)
    #expect(status.detail?.contains("时钟") == true)
}

@Test func liveCountsHighlightAndStaleDeadlineUseOnlyFreshUnresolvedObservations() throws {
    var store = SessionStore()
    try store.receive([
        statusEvent(.needsInput, session: "stale-wait", at: statusEpoch.addingTimeInterval(-600)),
        statusEvent(.working, session: "fresh-work", at: statusEpoch),
        statusEvent(.needsInput, session: "fresh-wait", at: statusEpoch.addingTimeInterval(20)),
        statusEvent(.failed, session: "failed", at: statusEpoch.addingTimeInterval(20)),
    ])
    let snapshot = store.snapshot(at: statusEpoch.addingTimeInterval(30))
    #expect(snapshot.workingCount == 1 && snapshot.waitingCount == 1 && snapshot.unknownCount == 1)
    #expect(snapshot.activitySession?.id == "fresh-wait")
    #expect(snapshot.sessions.last?.id == "stale-wait")
    let firstExpiry = statusEpoch.addingTimeInterval(SessionStatusPolicy.standard.freshFor)
    #expect(snapshot.activityStaleAt == firstExpiry)
    #expect(snapshot.nextTransitionAt == firstExpiry)
    let partial = store.snapshot(at: firstExpiry)
    #expect(partial.workingCount == 0 && partial.waitingCount == 1)
    #expect(partial.activitySession?.id == "fresh-wait")
    #expect(partial.activityStaleAt == firstExpiry.addingTimeInterval(20))
    let allStale = store.snapshot(at: firstExpiry.addingTimeInterval(20))
    #expect(allStale.activitySession == nil && allStale.activityStaleAt == nil)
}

@Test func stableTiesAndPassageOfTimeDoNotAlterTheStoredObservation() throws {
    let events = [statusEvent(.working, session: "b", at: statusEpoch), statusEvent(.working, session: "a", at: statusEpoch)]
    var first = SessionStore(), second = SessionStore()
    try first.receive(events)
    try second.receive(Array(events.reversed()))
    let now = statusEpoch.addingTimeInterval(60)
    #expect(first.snapshot(at: now) == first.snapshot(at: now.addingTimeInterval(1)))
    #expect(first.snapshot(at: now) == second.snapshot(at: now))
    #expect(first.snapshot(at: now).sessions.map(\.id) == ["a", "b"])
    let later = first.snapshot(at: now.addingTimeInterval(600))
    #expect(later.sessions.first?.session.lastEventID == events[1].id)
    #expect(later.sessions.first?.session.updatedAt == statusEpoch)
}

@Test func boundedInboxRestorationKeepsOldWorkVisibleAsUnknownAndOldHistoryHidden() throws {
    let root = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.temporaryDirectory
    let directory = root.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = EventInbox(directory: directory)
    let events = [statusEvent(.working, session: "long-work", at: statusEpoch),
                  statusEvent(.needsInput, session: "long-wait", at: statusEpoch),
                  statusEvent(.ended, session: "exited", at: statusEpoch)]
    for event in events { try inbox.write(event) }
    let now = statusEpoch.addingTimeInterval(2 * 60 * 60)
    var restored = SessionStore()
    try restored.receive(inbox.readRecent().events)
    let snapshot = restored.snapshot(at: now)
    #expect(snapshot.sessions.map(\.id) == ["long-wait", "long-work"])
    #expect(snapshot.unknownCount == 2 && snapshot.workingCount == 0 && snapshot.waitingCount == 0)
    var restarted = SessionStore()
    try restarted.receive(inbox.readRecent().events)
    #expect(restarted.snapshot(at: now) == snapshot)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == events.count)
}

private func statusEvent(_ phase: AgentPhase, session: String = "session", at: Date) -> AgentEvent {
    AgentEvent(version: 2, sessionID: session, projectName: "project", phase: phase, occurredAt: at,
               context: EventContext(source: .manual, kind: .status, receivedAt: at))
}

private func scopedStatusEvent(_ kind: EventKind, turn: String, at: Date) -> AgentEvent {
    AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: kind.expectedPhase!, occurredAt: at,
               context: EventContext(source: kind == .turnCompleted ? .codexNotify : .codexHook, kind: kind,
                                     receivedAt: at, turnID: turn,
                                     toolName: kind == .toolStarted ? "Bash" : nil,
                                     toolUseID: kind == .toolStarted ? UUID().uuidString : nil))
}
