import Foundation
import Testing
@testable import TideIslandCore

private let schedulerEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func activitySchedulerRejectsOlderAndDuplicateSourceSequences() async throws {
    let fixture = SchedulerFixture()
    let latest = try schedulerSnapshot("latest")
    let old = try schedulerSnapshot("old")
    let accepted = await fixture.scheduler.submit(snapshot: latest, sequence: 2)
    let older = await fixture.scheduler.submit(snapshot: old, sequence: 1)
    let duplicate = await fixture.scheduler.submit(snapshot: old, sequence: 2)
    await fixture.scheduler.flush()
    let state = await fixture.scheduler.current(), content = await fixture.client.presentations
    #expect(accepted && !older && !duplicate)
    #expect(state.synchronizedSequence == 2 && content.map(\.state.projectName) == ["latest"])
}

@Test func activitySchedulerDeduplicatesPayloadsDespiteNewEventOrLocationMetadata() async throws {
    let fixture = SchedulerFixture()
    let first = try schedulerSnapshot("same")
    let location = WaveLocation(blockID: UUID(), tabID: UUID(), waveVersion: "0.14.5", observedAt: schedulerEpoch, source: .environment)
    let changed = try schedulerSnapshot("same", location: location)
    await fixture.scheduler.submit(snapshot: first, sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: changed, sequence: 2); await fixture.scheduler.flush()
    let calls = await fixture.client.calls, state = await fixture.scheduler.current()
    #expect(calls == ["authorize", "request"] && state.synchronizedSequence == 2)
    #expect(state.phase == .synchronized && state.problem == nil)
}

@Test func activitySchedulerOrdersQuotaChangesAndClearsQuotaWithoutRenewingTheSession() async throws {
    let fixture = SchedulerFixture(), snapshot = try schedulerSnapshot("same")
    let quota = try CodexQuotaSnapshot.decodeResponse(
        Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":30,"windowDurationMins":10080}}}}"#.utf8),
        requestID: 2, checkedAt: schedulerEpoch)
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 1, codexQuota: quota)
    await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 3)
    let acceptedOld = await fixture.scheduler.submit(snapshot: snapshot, sequence: 2, codexQuota: quota)
    await fixture.scheduler.flush()
    let payloads = await fixture.client.presentations
    #expect(!acceptedOld && payloads.count == 2 && payloads.first?.state.codexQuota == quota && payloads.last?.state.codexQuota == nil)
    #expect(payloads.first?.state.updatedAt == payloads.last?.state.updatedAt)
    #expect(payloads.first?.staleAt == payloads.last?.staleAt && payloads.first?.sessionURL == payloads.last?.sessionURL)
}

@Test func activitySchedulerUpdatesWhenOnlyAnOverviewRowChanges() async throws {
    let fixture = SchedulerFixture()
    func snapshot(_ otherID: String) throws -> SessionSnapshot {
        var store = SessionStore()
        try store.receive([
            AgentEvent(sessionID: "waiting", projectName: "main", phase: .needsInput, occurredAt: schedulerEpoch),
            AgentEvent(sessionID: otherID, projectName: "secondary", phase: .working, occurredAt: schedulerEpoch),
        ])
        return store.snapshot(at: schedulerEpoch)
    }
    await fixture.scheduler.submit(snapshot: try snapshot("first"), sequence: 1)
    await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: try snapshot("replacement"), sequence: 2)
    await fixture.scheduler.flush()
    let payloads = await fixture.client.presentations
    #expect(payloads.map { $0.state.otherSessions?.first?.id } == ["first", "replacement"])
    #expect(payloads.first?.state.workingCount == payloads.last?.state.workingCount &&
            payloads.first?.sessionURL == payloads.last?.sessionURL && payloads.first?.staleAt == payloads.last?.staleAt)
}

@Test func activitySchedulerKeepsOnlyTheNewestSnapshotDuringAnInflightRequest() async throws {
    let gate = SchedulerGate(), client = SchedulerClient(requestGate: gate)
    let fixture = SchedulerFixture(client: client)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("first"), sequence: 1)
    try await schedulerWaitForEntry(gate.entries)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("middle"), sequence: 2)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("latest", phase: .needsInput), sequence: 3)
    await gate.open(); await fixture.scheduler.flush()
    let content = await client.presentations, maximum = await client.maximumOperations
    let state = await fixture.scheduler.current()
    #expect(content.map(\.state.projectName) == ["first", "latest"] && maximum == 1)
    #expect(state.sourceSequence == 3 && state.synchronizedSequence == 3)
}

@Test func activitySchedulerThrottlesOrdinaryChangesUsingMonotonicTime() async throws {
    let fixture = SchedulerFixture()
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("one"), sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("two"), sequence: 2); await fixture.scheduler.flush()
    fixture.clock.advance(5)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("three"), sequence: 3); await fixture.scheduler.flush()
    let waits = await fixture.sleeper.delays, content = await fixture.client.presentations
    #expect(waits == [1] && content.map(\.state.projectName) == ["one", "two", "three"])
}

@Test func activitySchedulerReplacesOrdinarySnapshotsWhileAThrottleTimerIsPending() async throws {
    let gate = SchedulerGate(), fixture = SchedulerFixture(timerGate: gate)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("one"), sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("two"), sequence: 2)
    try await schedulerWaitForEntry(gate.entries)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("three"), sequence: 3)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("four"), sequence: 4)
    await gate.open(); await fixture.scheduler.flush()
    let content = await fixture.client.presentations, waits = await fixture.sleeper.delays
    let state = await fixture.scheduler.current()
    #expect(content.map(\.state.projectName) == ["one", "four"] && waits == [1])
    #expect(state.synchronizedSequence == 4)
}

@Test func activitySchedulerInterruptsAThrottleWaitForNewInputAttention() async throws {
    let gate = SchedulerGate(), fixture = SchedulerFixture(timerGate: gate)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("one"), sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("ordinary"), sequence: 2)
    try await schedulerWaitForEntry(gate.entries)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("waiting", phase: .needsInput), sequence: 3)
    await fixture.scheduler.flush()
    let content = await fixture.client.presentations
    #expect(content.map(\.state.projectName) == ["one", "waiting"] && fixture.clock.uptime() == 0)
}

@Test func activitySchedulerInterruptsThrottleForAnImmediateLossOfSourceConfirmation() async throws {
    let gate = SchedulerGate(), fixture = SchedulerFixture(timerGate: gate)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("one"), sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("ordinary"), sequence: 2)
    try await schedulerWaitForEntry(gate.entries)
    let unavailable = try schedulerSnapshot("one", sourceIssue: .channelUnavailable)
    await fixture.scheduler.submit(snapshot: unavailable, sequence: 3); await fixture.scheduler.flush()
    let calls = await fixture.client.calls, content = await fixture.client.presentations
    #expect(calls == ["authorize", "request", "end:owned"] && content.count == 1)
    #expect(fixture.clock.uptime() == 0)
}

@Test func activitySchedulerRecomputesCachedAggregateExpiryAfterSleeping() async throws {
    let fixture = SchedulerFixture()
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("one", time: -299), sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("two", time: -299), sequence: 2); await fixture.scheduler.flush()
    let calls = await fixture.client.calls, content = await fixture.client.presentations
    let state = await fixture.scheduler.current()
    #expect(content.map(\.state.projectName) == ["one"] && calls.last == "end:owned")
    #expect(state.synchronizedSequence == 2 && state.phase == .synchronized)
}

@Test func activitySchedulerCachesTheActualPostAuthorizationResultRatherThanAnExpiredCandidate() async throws {
    let clock = SchedulerClock()
    let client = SchedulerClient(afterAuthorization: { clock.setWall(schedulerEpoch.addingTimeInterval(300)) })
    let fixture = SchedulerFixture(clock: clock, client: client)
    let snapshot = try schedulerSnapshot("one")
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 2); await fixture.scheduler.flush()
    let calls = await client.calls, state = await fixture.scheduler.current()
    #expect(calls == ["authorize"] && state.synchronizedSequence == 2 && state.problem == nil)
}

@Test func activitySchedulerDoesNotReuseAnOldDedupCacheAfterAnUncertainUpdateFailure() async throws {
    let client = SchedulerClient(failure: .updateAfterApplying), fixture = SchedulerFixture(client: client)
    let one = try schedulerSnapshot("one"), two = try schedulerSnapshot("two")
    await fixture.scheduler.submit(snapshot: one, sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: two, sequence: 2); await fixture.scheduler.flush()
    let failed = await fixture.scheduler.current()
    #expect(failed.phase == .failed && failed.problem == .updateFailed)
    await fixture.scheduler.submit(snapshot: one, sequence: 3); await fixture.scheduler.flush()
    let content = await client.presentations, state = await fixture.scheduler.current()
    #expect(content.map(\.state.projectName) == ["one", "two", "one"])
    #expect(state.phase == .synchronized && state.problem == nil && state.synchronizedSequence == 3)
}

@Test func activitySchedulerDoesNotBlindlyRetryFailedRequestsWithoutNewSourceInput() async throws {
    let client = SchedulerClient(failure: .request), fixture = SchedulerFixture(client: client)
    let snapshot = try schedulerSnapshot("one")
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 1); await fixture.scheduler.flush()
    let failed = await fixture.scheduler.current(), firstCalls = await client.calls
    #expect(failed.problem == .requestFailed && firstCalls == ["authorize", "request"])
    #expect(!String(describing: failed).contains("fixture-private"))
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 2); await fixture.scheduler.flush()
    let finalCalls = await client.calls
    #expect(finalCalls == ["authorize", "request", "authorize", "request"])
}

@Test func activitySchedulerReportsTimerFailuresWithoutSpinningOrDroppingFutureInput() async throws {
    let fixture = SchedulerFixture(timerFailsOnce: true)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("one"), sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("two"), sequence: 2); await fixture.scheduler.flush()
    let failed = await fixture.scheduler.current()
    #expect(failed.problem == .schedulingFailed && failed.phase == .failed)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("three"), sequence: 3); await fixture.scheduler.flush()
    let content = await fixture.client.presentations, state = await fixture.scheduler.current()
    #expect(content.map(\.state.projectName) == ["one", "three"] && state.problem == nil)
}

@Test func activitySchedulerPrioritizesChangedWaitingTargetsAndThrottlesRepeatedWaitingUpdates() async throws {
    let fixture = SchedulerFixture()
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("one", phase: .needsInput, session: "one"), sequence: 1)
    await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("two", phase: .needsInput, session: "two"), sequence: 2)
    await fixture.scheduler.flush()
    let urgentWaits = await fixture.sleeper.delays
    #expect(urgentWaits.isEmpty)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("same-target-new-observation", phase: .needsInput, session: "two"), sequence: 3)
    await fixture.scheduler.flush()
    let repeatedWaits = await fixture.sleeper.delays
    #expect(repeatedWaits == [1])
}

@Test func activitySchedulerRejectsInvalidMonotonicTimeAndRecoversOnNewInput() async throws {
    let fixture = SchedulerFixture()
    fixture.clock.setUptime(2)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("one"), sequence: 1); await fixture.scheduler.flush()
    fixture.clock.setUptime(1)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("two"), sequence: 2); await fixture.scheduler.flush()
    let failed = await fixture.scheduler.current()
    #expect(failed.problem == .invalidClock)
    fixture.clock.setUptime(3)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("three"), sequence: 3); await fixture.scheduler.flush()
    let content = await fixture.client.presentations
    #expect(content.map(\.state.projectName) == ["one", "three"])
}

@Test func activitySchedulerDeduplicatesEmptySnapshotsWithoutQueryingTheSDK() async throws {
    let fixture = SchedulerFixture()
    let empty = SessionStore().snapshot(at: schedulerEpoch)
    await fixture.scheduler.submit(snapshot: empty, sequence: 0); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: empty, sequence: 1); await fixture.scheduler.flush()
    let calls = await fixture.client.calls, state = await fixture.scheduler.current()
    #expect(calls.isEmpty && state.synchronizedSequence == 1)
}

@Test func activitySchedulerPushesFailuresThroughItsActualDeliveryStream() async throws {
    let fixture = SchedulerFixture(client: SchedulerClient(failure: .request))
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("one"), sequence: 1)
    let failed = try await schedulerWaitForDelivery(fixture.scheduler.frames) { $0.phase == .failed }
    #expect(failed.problem == .requestFailed)
}

@Test func activitySchedulerPushesRecoveryAndRetainsTheErrorWhileARetryIsPending() async throws {
    let gate = SchedulerGate(), client = SchedulerClient(failure: .request, requestGate: gate)
    let fixture = SchedulerFixture(client: client)
    let snapshot = try schedulerSnapshot("one")
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 1)
    await fixture.scheduler.flush()
    let failed = await fixture.scheduler.current()
    #expect(failed.problem == .requestFailed)
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 2)
    try await schedulerWaitForEntry(gate.entries)
    let pending = await fixture.scheduler.current()
    #expect(pending.problem == .requestFailed)
    await gate.open()
    let recovered = try await schedulerWaitForDelivery(fixture.scheduler.frames) { $0.phase == .synchronized && $0.synchronizedSequence == 2 }
    #expect(recovered.problem == nil)
}

@Test func activitySchedulerCoalescesALargeBurstIntoOneFinalPendingSnapshot() async throws {
    let gate = SchedulerGate(), client = SchedulerClient(requestGate: gate), fixture = SchedulerFixture(client: client)
    await fixture.scheduler.submit(snapshot: try schedulerSnapshot("first"), sequence: 1)
    try await schedulerWaitForEntry(gate.entries)
    for number in 2...1000 {
        await fixture.scheduler.submit(snapshot: try schedulerSnapshot("project-\(number)", phase: number == 1000 ? .needsInput : .working),
                                       sequence: UInt64(number))
    }
    await gate.open(); await fixture.scheduler.flush()
    let content = await client.presentations, maximum = await client.maximumOperations
    #expect(content.map(\.state.projectName) == ["first", "project-1000"] && maximum == 1)
}

private func schedulerSnapshot(_ project: String, phase: AgentPhase = .working, session: String = "session", time: TimeInterval = 0,
                               sourceIssue: SessionSourceIssue? = nil, location: WaveLocation? = nil) throws -> SessionSnapshot {
    let at = schedulerEpoch.addingTimeInterval(time)
    let event = AgentEvent(version: 2, sessionID: session, projectName: project, phase: phase, occurredAt: at, waveLocation: location,
                           context: EventContext(source: .manual, kind: .status, receivedAt: at))
    var store = SessionStore(); try store.receive([event])
    return store.snapshot(at: schedulerEpoch, sourceIssue: sourceIssue)
}

private struct SchedulerFixture: Sendable {
    let clock: SchedulerClock
    let client: SchedulerClient
    let sleeper: SchedulerSleeper
    let scheduler: IslandActivityScheduler
    init(clock: SchedulerClock = SchedulerClock(), client: SchedulerClient = SchedulerClient(), timerGate: SchedulerGate? = nil,
         timerFailsOnce: Bool = false) {
        self.clock = clock; self.client = client
        let sleeper = SchedulerSleeper(clock: clock, gate: timerGate, failsOnce: timerFailsOnce)
        self.sleeper = sleeper
        scheduler = IslandActivityScheduler(client: client, now: { clock.now() }, uptime: { clock.uptime() },
                                             sleep: { try await sleeper.sleep($0) })
    }
}

private final class SchedulerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = schedulerEpoch
    private var tick: TimeInterval = 0
    func now() -> Date { lock.withLock { date } }
    func uptime() -> TimeInterval { lock.withLock { tick } }
    func advance(_ duration: TimeInterval) { lock.withLock { date = date.addingTimeInterval(duration); tick += duration } }
    func setWall(_ date: Date) { lock.withLock { self.date = date } }
    func setUptime(_ value: TimeInterval) { lock.withLock { tick = value } }
}

private actor SchedulerSleeper {
    var delays: [TimeInterval] = []
    let clock: SchedulerClock
    let gate: SchedulerGate?
    var failsOnce: Bool
    init(clock: SchedulerClock, gate: SchedulerGate?, failsOnce: Bool) { self.clock = clock; self.gate = gate; self.failsOnce = failsOnce }
    func sleep(_ duration: TimeInterval) async throws {
        delays.append(duration)
        if failsOnce { failsOnce = false; throw SchedulerTestError.privateFailure }
        await gate?.hold()
        try Task.checkCancellation()
        clock.advance(duration)
    }
}

private enum SchedulerFailure: Sendable { case none, request, updateAfterApplying }
private enum SchedulerTestError: Error, CustomStringConvertible {
    case privateFailure
    var description: String { "fixture-private-scheduler-error" }
}

private actor SchedulerClient: IslandActivityClient {
    var calls: [String] = []
    var presentations: [IslandActivityPresentation] = []
    var operations = 0
    var maximumOperations = 0
    var failure: SchedulerFailure
    let requestGate: SchedulerGate?
    let afterAuthorization: @Sendable () async -> Void
    init(failure: SchedulerFailure = .none, requestGate: SchedulerGate? = nil, afterAuthorization: @escaping @Sendable () async -> Void = {}) {
        self.failure = failure; self.requestGate = requestGate; self.afterAuthorization = afterAuthorization
    }
    func isEnabled() async -> Bool { calls.append("authorize"); await afterAuthorization(); return true }
    func request(_ presentation: IslandActivityPresentation) async throws -> String {
        calls.append("request"); begin(); defer { operations -= 1 }
        if failure == .request { failure = .none; throw SchedulerTestError.privateFailure }
        await requestGate?.hold()
        presentations.append(presentation)
        return "owned"
    }
    func update(_ identifier: String, presentation: IslandActivityPresentation) async throws {
        calls.append("update:" + identifier); begin(); defer { operations -= 1 }
        presentations.append(presentation)
        if failure == .updateAfterApplying { failure = .none; throw SchedulerTestError.privateFailure }
    }
    func end(_ identifier: String) async throws { calls.append("end:" + identifier); begin(); operations -= 1 }
    private func begin() { operations += 1; maximumOperations = max(maximumOperations, operations) }
}

private actor SchedulerGate {
    nonisolated let entries: AsyncStream<Void>
    private let entry: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation
    init() {
        let first = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)); entries = first.stream; entry = first.continuation
        let second = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)); releases = second.stream; release = second.continuation
    }
    func hold() async { entry.yield(()); for await _ in releases { break } }
    func open() { release.yield(()); release.finish() }
}

private func schedulerWaitForEntry(_ entries: AsyncStream<Void>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in entries { return }; throw CancellationError() }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw SchedulerTestError.privateFailure }
        defer { group.cancelAll() }
        _ = try await group.next()
    }
}

private func schedulerWaitForDelivery(_ frames: AsyncStream<IslandActivityDelivery>,
                                     matching condition: @escaping @Sendable (IslandActivityDelivery) -> Bool) async throws -> IslandActivityDelivery {
    try await withThrowingTaskGroup(of: IslandActivityDelivery.self) { group in
        group.addTask {
            for await frame in frames { if condition(frame) { return frame } }
            throw CancellationError()
        }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw SchedulerTestError.privateFailure }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw SchedulerTestError.privateFailure }
        return result
    }
}
