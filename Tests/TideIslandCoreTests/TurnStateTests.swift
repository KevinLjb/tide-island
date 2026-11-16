import Foundation
import Testing
@testable import TideIslandCore

@Test func retiredAndUnknownTurnsCannotOverwriteTheCurrentTurn() throws {
    var registry = SessionRegistry()
    try registry.apply(turnEvent(.turnStarted, turn: "old", time: 1))
    try registry.apply(turnEvent(.turnStarted, turn: "new", time: 2))
    let current = registry.sessions
    #expect(try registry.applyResult(turnEvent(.turnCompleted, turn: "old", time: 100)) == .retiredTurn)
    #expect(try registry.applyResult(turnEvent(.toolFinished, turn: "unknown", time: 101)) == .unknownTurn)
    #expect(try registry.applyResult(turnEvent(.turnStarted, turn: "old", time: 102)) == .retiredTurn)
    #expect(registry.sessions == current)
    #expect(try registry.apply(turnEvent(.toolStarted, turn: "new", time: 3)))
    #expect(registry.sessions.first?.turnID == "new")
}

@Test func delayedNewTurnStartsCompareAgainstTurnBoundariesInsteadOfOldActivity() throws {
    var registry = SessionRegistry()
    try registry.apply(turnEvent(.turnStarted, turn: "old", time: 1))
    try registry.apply(turnEvent(.toolFinished, turn: "old", time: 20))
    #expect(try registry.apply(turnEvent(.turnStarted, turn: "new", time: 10)))
    #expect(registry.sessions.first?.turnID == "new")
    #expect(try registry.applyResult(turnEvent(.turnStarted, turn: "unseen-older", time: 0)) == .olderEvent)
    #expect(registry.sessions.first?.turnID == "new")
}

@Test func scopedCompletionDominatesLateToolsAndLateStartDoesNotReopenIt() throws {
    var registry = SessionRegistry()
    try registry.apply(turnEvent(.toolStarted, turn: "one", time: 5))
    #expect(try registry.apply(turnEvent(.turnCompleted, turn: "one", time: 3)))
    let completed = registry.sessions
    #expect(try registry.applyResult(turnEvent(.turnStarted, turn: "one", time: 1)) == .turnAlreadyStarted)
    #expect(try registry.applyResult(turnEvent(.toolFinished, turn: "one", time: 6)) == .terminalTurn)
    #expect(try registry.applyResult(turnEvent(.turnCompleted, turn: "one", time: 7)) == .terminalTurn)
    #expect(registry.sessions == completed)
    #expect(try registry.apply(turnEvent(.turnStarted, turn: "two", time: 8)))
    #expect(registry.sessions.first?.phase == .working)
}

@Test func sameTimestampTerminalEvidenceConvergesForAnIdentifiedTurn() throws {
    let start = turnEvent(.turnStarted, turn: "one", time: 5)
    let tool = turnEvent(.toolStarted, turn: "one", time: 5)
    let completed = turnEvent(.turnCompleted, turn: "one", time: 5)
    let interrupted = turnEvent(.turnInterrupted, turn: "one", time: 5)
    for events in [[tool, completed, interrupted], [interrupted, tool, completed], [completed, interrupted, tool]] {
        var registry = SessionRegistry()
        try registry.apply(start)
        for event in events { try registry.apply(event) }
        #expect(registry.sessions.first?.phase == .interrupted)
        #expect(registry.sessions.first?.lastEventID == interrupted.id)
    }
}

@Test func sameTimeStartsUseObservedOrderAndNeverUseLexicalTurnIDsAsTime() throws {
    var registry = SessionRegistry()
    try registry.apply(turnEvent(.turnStarted, turn: "z-old", time: 1))
    try registry.apply(turnEvent(.turnStarted, turn: "a-new", time: 1))
    #expect(registry.sessions.first?.turnID == "a-new")
    #expect(try registry.applyResult(turnEvent(.turnCompleted, turn: "z-old", time: 2)) == .retiredTurn)
}

@Test func permissionWaitSurvivesOtherCallsAndEqualTimeResolutionIsConservative() throws {
    var registry = SessionRegistry()
    try registry.apply(turnEvent(.turnStarted, turn: "one", time: 1))
    try registry.apply(turnEvent(.toolStarted, turn: "one", time: 2, toolID: "requested"))
    try registry.apply(turnEvent(.permissionRequested, turn: "one", time: 3))
    let waiting = registry.sessions
    #expect(try registry.applyResult(turnEvent(.toolStarted, turn: "one", time: 4, toolID: "parallel")) == .waitingForInput)
    #expect(try registry.applyResult(turnEvent(.toolFinished, turn: "one", time: 5, toolID: "parallel")) == .waitingForInput)
    #expect(registry.sessions == waiting)
    #expect(try registry.apply(turnEvent(.toolFinished, turn: "one", time: 6, toolID: "requested")))
    #expect(registry.sessions.first?.phase == .working)

    var tied = SessionRegistry()
    try tied.apply(turnEvent(.turnStarted, turn: "one", time: 1))
    try tied.apply(turnEvent(.permissionRequested, turn: "one", time: 2))
    #expect(try tied.applyResult(turnEvent(.toolFinished, turn: "one", time: 2)) == .timestampTie)
    #expect(tied.sessions.first?.phase == .needsInput)
}

@Test func stableToolIDsPreventDelayedStartsAndRepeatedCompletionsFromChangingState() throws {
    var registry = SessionRegistry()
    try registry.apply(turnEvent(.turnStarted, turn: "one", time: 1))
    try registry.apply(turnEvent(.toolFinished, turn: "one", time: 2))
    let finished = registry.sessions
    #expect(try registry.applyResult(turnEvent(.toolStarted, turn: "one", time: 3)) == .outdatedTool)
    #expect(try registry.applyResult(turnEvent(.toolFinished, turn: "one", time: 4)) == .outdatedTool)
    #expect(registry.sessions == finished)
    try registry.apply(turnEvent(.turnStarted, turn: "two", time: 5))
    #expect(try registry.apply(turnEvent(.toolStarted, turn: "two", time: 6)))
}

@Test func toolCompletionCanArriveWithAnEarlierClockThanItsVisibleStart() throws {
    var registry = SessionRegistry()
    try registry.apply(turnEvent(.toolStarted, turn: "one", time: 10))
    #expect(try registry.apply(turnEvent(.toolFinished, turn: "one", time: 5)))
    #expect(registry.sessions.first?.context?.kind == .toolFinished)
    #expect(try registry.applyResult(turnEvent(.toolStarted, turn: "one", time: 20)) == .outdatedTool)
}

@Test func anAmbiguousPermissionWaitKeepsAllKnownSameNameCandidates() throws {
    var registry = SessionRegistry()
    try registry.apply(turnEvent(.toolStarted, turn: "one", time: 1, toolID: "first"))
    try registry.apply(turnEvent(.toolStarted, turn: "one", time: 2, toolID: "second"))
    try registry.apply(turnEvent(.permissionRequested, turn: "one", time: 3))
    #expect(try registry.applyResult(turnEvent(.toolFinished, turn: "one", time: 4, toolID: "first")) == .waitingForInput)
    #expect(registry.sessions.first?.phase == .needsInput)
    #expect(try registry.apply(turnEvent(.toolFinished, turn: "one", time: 5, toolID: "second")))
}

@Test func sessionExitKeepsTurnIdentityWithoutInventingItInTheEventContext() throws {
    var registry = SessionRegistry()
    try registry.apply(turnEvent(.turnStarted, turn: "one", time: 1))
    try registry.apply(turnEvent(.sessionEnded, turn: nil, time: 2))
    #expect(registry.sessions.first?.turnID == "one")
    #expect(registry.sessions.first?.context?.turnID == nil)
    #expect(try registry.applyResult(turnEvent(.toolStarted, turn: "two", time: 3)) == .sessionEnded)
    #expect(try registry.apply(turnEvent(.turnStarted, turn: "two", time: 4)))
    #expect(try registry.applyResult(turnEvent(.sessionEnded, turn: nil, time: 3)) == .olderEvent)
    #expect(registry.sessions.first?.turnID == "two")
}

@Test func legacyRecordsBootstrapIndependentlyAndUnscopedUpdatesCannotGuessAnActiveTurn() throws {
    var registry = SessionRegistry()
    try registry.apply(AgentEvent(sessionID: "session", projectName: "project", phase: .needsInput, occurredAt: Date(timeIntervalSince1970: 1)))
    try registry.apply(turnEvent(.toolStarted, turn: "one", time: 2))
    let current = registry.sessions
    let legacy = AgentEvent(sessionID: "session", projectName: "project", phase: .completed, occurredAt: Date(timeIntervalSince1970: 100))
    #expect(try registry.applyResult(legacy) == .missingTurn)
    #expect(try registry.applyResult(turnEvent(.turnCompleted, turn: nil, time: 101)) == .missingTurn)
    #expect(registry.sessions == current)
    #expect(try registry.apply(AgentEvent(sessionID: "legacy", projectName: "project", phase: .completed, occurredAt: Date(timeIntervalSince1970: 1))))
    #expect(try registry.apply(AgentEvent(sessionID: "legacy", projectName: "project", phase: .working, occurredAt: Date(timeIntervalSince1970: 2))))
}

@Test func duplicateIDsAreRememberedAcrossOtherEventsAndScopedToTheirSession() throws {
    var registry = SessionRegistry()
    let start = turnEvent(.turnStarted, turn: "one", time: 1)
    try registry.apply(start)
    try registry.apply(turnEvent(.toolStarted, turn: "one", time: 2))
    let current = registry.sessions
    #expect(try registry.applyResult(start) == .duplicateEvent)
    #expect(registry.sessions == current)
    let other = turnEvent(.turnStarted, turn: "one", time: 3, session: "other", id: start.id)
    #expect(try registry.apply(other))
    #expect(registry.sessions.count == 2)
}

@Test func eventHistoryEvictionIsBoundedAndDeterministic() throws {
    var registry = SessionRegistry()
    let first = AgentEvent(sessionID: "legacy", projectName: "project", phase: .working, occurredAt: Date(timeIntervalSince1970: 0))
    try registry.apply(first)
    for index in 1...SessionRegistry.eventHistoryLimit {
        try registry.apply(AgentEvent(sessionID: "legacy", projectName: "project", phase: .working, occurredAt: Date(timeIntervalSince1970: Double(index))))
    }
    let outsideWindow = AgentEvent(id: first.id, sessionID: "legacy", projectName: "project", phase: .completed,
                                  occurredAt: Date(timeIntervalSince1970: 10_000))
    #expect(try registry.apply(outsideWindow))
    #expect(try registry.applyResult(outsideWindow) == .duplicateEvent)
}

@Test func retiredTurnAndToolHistoriesEvictWithoutGrowingIndefinitely() throws {
    var registry = SessionRegistry()
    for index in 0...(SessionRegistry.retiredTurnLimit + 1) {
        try registry.apply(turnEvent(.turnStarted, turn: "turn-\(index)", time: Double(index)))
    }
    #expect(try registry.applyResult(turnEvent(.turnStarted, turn: "turn-1", time: 1000)) == .retiredTurn)
    #expect(try registry.apply(turnEvent(.turnStarted, turn: "turn-0", time: 1001)))

    var tools = SessionRegistry()
    try tools.apply(turnEvent(.turnStarted, turn: "one", time: 0))
    for index in 0...SessionRegistry.toolHistoryLimit {
        try tools.apply(turnEvent(.toolFinished, turn: "one", time: Double(index + 1), toolID: "tool-\(index)"))
    }
    #expect(try tools.applyResult(turnEvent(.toolStarted, turn: "one", time: 1000, toolID: "tool-1")) == .outdatedTool)
    #expect(try tools.apply(turnEvent(.toolStarted, turn: "one", time: 1001, toolID: "tool-0")))
}

private func turnEvent(_ kind: EventKind, turn: String?, time: Double, toolID: String = "tool", session: String = "session", id: UUID = UUID()) -> AgentEvent {
    let at = Date(timeIntervalSince1970: time)
    let hasTool = kind == .toolStarted || kind == .toolFinished || kind == .permissionRequested
    return AgentEvent(
        version: 2, id: id, sessionID: session, projectName: "project", phase: kind.expectedPhase!, occurredAt: at,
        context: EventContext(source: kind == .turnCompleted ? .codexNotify : .codexHook, kind: kind, receivedAt: at,
                              turnID: turn, toolName: hasTool ? "Bash" : nil,
                              toolUseID: kind == .toolStarted || kind == .toolFinished ? toolID : nil)
    )
}
