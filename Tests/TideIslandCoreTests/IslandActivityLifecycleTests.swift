import Foundation
import Testing
@testable import TideIslandCore

private let lifecycleEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func activityLifecycleAdoptsMatchingOrphanAndEndsDuplicatesBeforeUpdating() async throws {
    let snapshot = try lifecycleSnapshot("target")
    let client = LifecycleClient(records: [try lifecycleRecord("a", session: "other"), try lifecycleRecord("z", session: "target")])
    let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
    try await controller.update(snapshot: snapshot, scope: .application)
    let operations = await client.operations, contents = await client.contents
    #expect(operations == ["end:a", "update:z"])
    #expect(contents.last?.state.sessionID == "target" && contents.last?.state.updatedAt == lifecycleEpoch)
}

@Test func activityLifecycleChoosesDeterministicallyAndRetainsALivePrimary() async throws {
    let client = LifecycleClient(records: [try lifecycleRecord("z"), try lifecycleRecord("a")])
    let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
    try await controller.update(snapshot: lifecycleSnapshot("first"), scope: .application)
    await client.insert(try lifecycleRecord("0", session: "next"))
    try await controller.update(snapshot: lifecycleSnapshot("next"), scope: .application)
    let operations = await client.operations
    #expect(operations == ["end:z", "update:a", "end:0", "update:a"])
}

@Test func activityLifecycleOwnedScopeCannotAdoptOrEndAnotherInstancesOrphan() async throws {
    let client = LifecycleClient(records: [try lifecycleRecord("orphan")])
    let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
    try await controller.update(snapshot: lifecycleSnapshot(nil))
    let before = await client.operations
    #expect(before.isEmpty)
    try await controller.update(snapshot: lifecycleSnapshot(nil), scope: .application)
    let after = await client.operations, scopes = await client.scopes
    #expect(after == ["end:orphan"] && scopes == [.ownedOnly, .application])
}

@Test func activityLifecycleRevocationEndsEveryManagedLiveActivityWithoutCreating() async throws {
    let client = LifecycleClient(records: [try lifecycleRecord("a"), try lifecycleRecord("b", state: .stale)], enabled: false)
    let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
    let snapshot = try lifecycleSnapshot("session")
    let error = await lifecycleFailure { try await controller.update(snapshot: snapshot, scope: .application) }
    let operations = await client.operations
    #expect(error == .disabled && operations == ["end:a", "end:b"])
}

@Test func activityLifecycleEndedOrMissingSystemActivityCanBeReplacedOnExplicitInput() async throws {
    for state in [IslandActivityState.ended, .active] {
        let client = LifecycleClient(records: [try lifecycleRecord("old", state: state)])
        let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
        let snapshot = try lifecycleSnapshot("session")
        try await controller.update(snapshot: snapshot, scope: .application)
        await client.removeAll()
        try await controller.update(snapshot: snapshot, scope: .application)
        let operations = await client.operations
        #expect(operations.last == "request")
        #expect(operations.filter { $0 == "request" }.count == (state == .ended ? 2 : 1))
    }
}

@Test func activityLifecycleRejectsTheWholeMalformedOrFutureInventoryWithoutMutation() async throws {
    let valid = try lifecycleRecord("valid")
    let invalidContent = IslandActivityContent(sessionID: "bad", projectName: "bad", phase: .working,
                                               workingCount: -1, waitingCount: 0, updatedAt: lifecycleEpoch)
    let inventories: [[IslandActivityRecord]] = [
        [valid, valid], [valid, try lifecycleRecord("bad\nID")], [valid, try lifecycleRecord("future", state: .unknown)],
        [valid, IslandActivityRecord(identifier: "bad", state: .active, content: invalidContent, staleAt: nil)],
        [valid, IslandActivityRecord(identifier: "bad", state: .active, content: valid.content, staleAt: Date(timeIntervalSince1970: .nan))],
        try (0..<65).map { try lifecycleRecord(String($0)) },
    ]
    let snapshot = try lifecycleSnapshot("session")
    for records in inventories {
        let client = LifecycleClient()
        await client.overrideInventory(records)
        let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
        let error = await lifecycleFailure { try await controller.update(snapshot: snapshot, scope: .application) }
        let operations = await client.operations
        #expect(error == .invalidInventory && operations.isEmpty)
    }
}

@Test func activityLifecycleInventoryFailurePreservesOwnershipAndSanitizesTheError() async throws {
    let client = LifecycleClient(), controller = IslandActivityController(client: client, now: { lifecycleEpoch })
    let snapshot = try lifecycleSnapshot("session")
    try await controller.update(snapshot: snapshot)
    await client.failInventory()
    let error = await lifecycleFailure { try await controller.update(snapshot: snapshot) }
    try await controller.update(snapshot: snapshot)
    let operations = await client.operations
    #expect(error == .inventoryFailed && operations == ["request", "update:created-1"])
}

@Test func activityLifecycleSystemDismissalSuppressesIdenticalStateAndNewObservationResumes() async throws {
    let client = LifecycleClient(), controller = IslandActivityController(client: client, now: { lifecycleEpoch.addingTimeInterval(2) })
    let snapshot = try lifecycleSnapshot("session")
    try await controller.update(snapshot: snapshot)
    await client.changeState("created-1", to: .dismissed)
    try await controller.update(snapshot: snapshot)
    await client.removeAll()
    try await controller.update(snapshot: lifecycleSnapshot(nil))
    try await controller.update(snapshot: snapshot)
    let suppressed = await client.operations
    #expect(suppressed == ["request"] && snapshot.ignoredSessions.isEmpty)
    try await controller.update(snapshot: lifecycleSnapshot("session", time: 1))
    let resumed = await client.operations
    #expect(resumed == ["request", "request"])
}

@Test func activityLifecycleDismissedOrphanSuppressesOnlyItsMatchingContent() async throws {
    for target in ["session", "different"] {
        let client = LifecycleClient(records: [try lifecycleRecord("dismissed", state: .dismissed)])
        let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
        try await controller.update(snapshot: lifecycleSnapshot(target), scope: .application)
        let operations = await client.operations
        #expect(operations == (target == "session" ? [] : ["request"]))
    }
}

@Test func activityLifecycleDuplicateEndFailureDoesNotHideBehindANewRequestOrUpdate() async throws {
    let client = LifecycleClient(records: [try lifecycleRecord("a"), try lifecycleRecord("b"), try lifecycleRecord("c")])
    await client.failEnd("b")
    let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
    let snapshot = try lifecycleSnapshot("session")
    let error = await lifecycleFailure { try await controller.update(snapshot: snapshot, scope: .application) }
    let failed = await client.operations
    #expect(error == .endFailed && failed == ["end:b", "end:c"])
    try await controller.update(snapshot: snapshot, scope: .application)
    let recovered = await client.operations
    #expect(recovered == ["end:b", "end:c", "end:b", "update:a"])
}

@Test func activityLifecycleInventoryWaitCannotRenewAnExpiredSnapshot() async throws {
    let gate = LifecycleGate(), clock = LifecycleClock(), client = LifecycleClient(inventoryGate: gate)
    let controller = IslandActivityController(client: client, now: { clock.date() })
    let snapshot = try lifecycleSnapshot("session")
    let task = Task { try await controller.update(snapshot: snapshot) }
    try await lifecycleEntered(gate.entries)
    clock.setDate(lifecycleEpoch.addingTimeInterval(300)); await gate.open()
    try await task.value
    let operations = await client.operations
    #expect(operations.isEmpty)
}

@Test func activityLifecycleRechecksDeadlineAfterDuplicateCleanupAwaits() async throws {
    let clock = LifecycleClock()
    let client = LifecycleClient(records: [try lifecycleRecord("a"), try lifecycleRecord("b")],
                                 afterEnd: { clock.setDate(lifecycleEpoch.addingTimeInterval(300)) })
    let controller = IslandActivityController(client: client, now: { clock.date() })
    try await controller.update(snapshot: lifecycleSnapshot("session"), scope: .application)
    let operations = await client.operations
    #expect(operations == ["end:b", "end:a"])
}

@Test func activityLifecycleRecoversAnAppliedRequestWhoseResponseWasLost() async throws {
    let client = LifecycleClient(); await client.loseRequestResponse()
    let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
    let snapshot = try lifecycleSnapshot("session")
    let error = await lifecycleFailure { try await controller.update(snapshot: snapshot, scope: .application) }
    try await controller.update(snapshot: snapshot, scope: .application)
    let operations = await client.operations
    #expect(error == .requestFailed && operations == ["request", "update:created-1"])
}

@Test func activityLifecycleShutdownCanCleanOrphansWithoutAuthorizationOrANewSnapshot() async throws {
    let client = LifecycleClient(records: [try lifecycleRecord("a"), try lifecycleRecord("b", state: .stale)], enabled: false)
    let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
    try await controller.shutdown(scope: .application)
    let operations = await client.operations, authorizations = await client.authorizations
    #expect(operations == ["end:a", "end:b"] && authorizations == 0)
}

@Test func activityLifecycleFailedShutdownRetainsRetryStateAndNeverCreatesAgain() async throws {
    let client = LifecycleClient(), controller = IslandActivityController(client: client, now: { lifecycleEpoch })
    let snapshot = try lifecycleSnapshot("session")
    try await controller.update(snapshot: snapshot)
    await client.failEnd("created-1")
    let first = await lifecycleFailure { try await controller.shutdown() }
    let stopped = await lifecycleFailure { try await controller.update(snapshot: snapshot) }
    try await controller.shutdown()
    let operations = await client.operations
    #expect(first == .endFailed && stopped == .stopped && operations == ["request", "end:created-1", "end:created-1"])
}

@Test func activityLifecycleRejectsConcurrentShutdownWithoutLosingTheActiveRequest() async throws {
    let gate = LifecycleGate(), client = LifecycleClient(requestGate: gate)
    let controller = IslandActivityController(client: client, now: { lifecycleEpoch })
    let snapshot = try lifecycleSnapshot("session")
    let task = Task { try await controller.update(snapshot: snapshot) }
    try await lifecycleEntered(gate.entries)
    let error = await lifecycleFailure { try await controller.shutdown() }
    await gate.open(); try await task.value
    try await controller.shutdown()
    let operations = await client.operations
    #expect(error == .busy && operations == ["request", "end:created-1"])
}

@Test func activitySchedulerForcedReconciliationBypassesEquivalentContentDeduplication() async throws {
    let fixture = LifecycleFixture(), snapshot = try lifecycleSnapshot("session")
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 2, forceReconciliation: true); await fixture.scheduler.flush()
    let operations = await fixture.client.operations, waits = fixture.clock.waits()
    #expect(operations == ["request", "update:created-1"] && waits.isEmpty)
}

@Test func activitySchedulerForcedReconciliationSurvivesPendingReplacementDuringARequest() async throws {
    let gate = LifecycleGate(), client = LifecycleClient(requestGate: gate), snapshot = try lifecycleSnapshot("session")
    let fixture = LifecycleFixture(client: client)
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 1)
    try await lifecycleEntered(gate.entries)
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 2, forceReconciliation: true)
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 3)
    await gate.open(); await fixture.scheduler.flush()
    let operations = await client.operations, delivery = await fixture.scheduler.current()
    #expect(operations == ["request", "update:created-1"] && delivery.synchronizedSequence == 3)
}

@Test func activitySchedulerSystemRefreshInterruptsAnOrdinaryThrottleWait() async throws {
    let gate = LifecycleGate(), fixture = LifecycleFixture(timerGate: gate)
    await fixture.scheduler.submit(snapshot: try lifecycleSnapshot("one"), sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: try lifecycleSnapshot("two"), sequence: 2)
    try await lifecycleEntered(gate.entries)
    await fixture.scheduler.submit(snapshot: try lifecycleSnapshot("latest"), sequence: 3, forceReconciliation: true)
    await fixture.scheduler.flush()
    let contents = await fixture.client.contents
    #expect(contents.map(\.state.sessionID) == ["one", "latest"])
}

@Test func activitySchedulerRejectsStaleScopeAndDoesNotLoseANewerAuthorityChange() async throws {
    let client = LifecycleClient(records: [try lifecycleRecord("orphan")]), fixture = LifecycleFixture(client: client)
    let snapshot = try lifecycleSnapshot(nil)
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 2)
    await fixture.scheduler.flush()
    let rejected = await fixture.scheduler.submit(snapshot: snapshot, sequence: 1, scope: .application, forceReconciliation: true)
    let before = await client.operations
    #expect(!rejected && before.isEmpty)
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 3, scope: .application)
    await fixture.scheduler.flush()
    let after = await client.operations
    #expect(after == ["end:orphan"])
}

@Test func activitySchedulerAuthorizationRefreshCleansUpAndCanRecoverAfterReenablement() async throws {
    let fixture = LifecycleFixture(), snapshot = try lifecycleSnapshot("session")
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 1); await fixture.scheduler.flush()
    await fixture.client.setEnabled(false)
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 2, forceReconciliation: true); await fixture.scheduler.flush()
    let disabled = await fixture.scheduler.current()
    #expect(disabled.problem == .disabled)
    await fixture.client.setEnabled(true)
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 3, forceReconciliation: true); await fixture.scheduler.flush()
    let operations = await fixture.client.operations, recovered = await fixture.scheduler.current()
    #expect(operations == ["request", "end:created-1", "request"] && recovered.problem == nil)
}

@Test func activitySchedulerShutdownSettlesInflightWorkAndRejectsResurrection() async throws {
    let gate = LifecycleGate(), client = LifecycleClient(requestGate: gate), fixture = LifecycleFixture(client: client)
    let snapshot = try lifecycleSnapshot("session")
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 1)
    try await lifecycleEntered(gate.entries)
    await fixture.scheduler.submit(snapshot: try lifecycleSnapshot("pending"), sequence: 2)
    let shutdown = Task { await fixture.scheduler.shutdown() }
    try await lifecycleStopping(fixture.scheduler.frames)
    let accepted = await fixture.scheduler.submit(snapshot: snapshot, sequence: 3)
    await gate.open()
    let success = await shutdown.value, operations = await client.operations, delivery = await fixture.scheduler.current()
    #expect(!accepted && success && delivery.phase == .stopped)
    #expect(operations == ["request", "end:created-1"])
}

@Test func activitySchedulerCancelsThrottleAndPerformsCleanupEvenIfTheQuitCallerCancels() async throws {
    let gate = LifecycleGate(), fixture = LifecycleFixture(timerGate: gate)
    await fixture.scheduler.submit(snapshot: try lifecycleSnapshot("one"), sequence: 1); await fixture.scheduler.flush()
    await fixture.scheduler.submit(snapshot: try lifecycleSnapshot("two"), sequence: 2)
    try await lifecycleEntered(gate.entries)
    let shutdown = Task { await fixture.scheduler.shutdown() }
    shutdown.cancel()
    let success = await shutdown.value, operations = await fixture.client.operations
    #expect(success && operations == ["request", "end:created-1"])
}

@Test func activitySchedulerFailedShutdownIsExplicitlyRetryableAndStillRejectsInput() async throws {
    let fixture = LifecycleFixture(), snapshot = try lifecycleSnapshot("session")
    await fixture.scheduler.submit(snapshot: snapshot, sequence: 1); await fixture.scheduler.flush()
    await fixture.client.failEnd("created-1")
    let first = await fixture.scheduler.shutdown(), failed = await fixture.scheduler.current()
    let accepted = await fixture.scheduler.submit(snapshot: snapshot, sequence: 2, forceReconciliation: true)
    let second = await fixture.scheduler.shutdown(), stopped = await fixture.scheduler.current()
    let repeated = await fixture.scheduler.shutdown(), final = await fixture.scheduler.current()
    let operations = await fixture.client.operations
    #expect(!first && failed.problem == .endFailed && !accepted && second && stopped.phase == .stopped)
    #expect(repeated && final.phase == .stopped && operations == ["request", "end:created-1", "end:created-1"])
}

private func lifecycleSnapshot(_ session: String?, time: TimeInterval = 0) throws -> SessionSnapshot {
    var store = SessionStore()
    if let session {
        let at = lifecycleEpoch.addingTimeInterval(time)
        try store.receive([AgentEvent(version: 2, sessionID: session, projectName: "project", phase: .working, occurredAt: at,
                                      context: EventContext(source: .manual, kind: .status, receivedAt: at))])
    }
    return store.snapshot(at: lifecycleEpoch.addingTimeInterval(time))
}

private func lifecycleRecord(_ identifier: String, session: String = "session", state: IslandActivityState = .active) throws -> IslandActivityRecord {
    let snapshot = try lifecycleSnapshot(session)
    let projected = try IslandActivityPresentationPolicy.standard.presentation(for: snapshot, at: lifecycleEpoch)
    let presentation = try #require(projected)
    return IslandActivityRecord(identifier: identifier, state: state, content: presentation.state, staleAt: presentation.staleAt)
}

private func lifecycleFailure(_ operation: @Sendable () async throws -> Void) async -> IslandActivityError? {
    do { try await operation(); return nil } catch { return error as? IslandActivityError }
}

private enum LifecycleTestError: Error { case privateFailure }

private actor LifecycleClient: IslandActivityClient {
    var operations: [String] = []
    var contents: [IslandActivityPresentation] = []
    var scopes: [IslandActivityScope] = []
    var authorizations = 0
    private var records: [String: IslandActivityRecord]
    private var local: Set<String> = []
    private var enabled: Bool
    private var override: [IslandActivityRecord]?
    private var inventoryFails = false
    private var endFailures: Set<String> = []
    private var requestResponseLost = false
    private var created = 0
    private let requestGate: LifecycleGate?
    private let inventoryGate: LifecycleGate?
    private let afterEnd: @Sendable () -> Void

    init(records: [IslandActivityRecord] = [], enabled: Bool = true, requestGate: LifecycleGate? = nil,
         inventoryGate: LifecycleGate? = nil, afterEnd: @escaping @Sendable () -> Void = {}) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.identifier, $0) })
        self.enabled = enabled; self.requestGate = requestGate; self.inventoryGate = inventoryGate; self.afterEnd = afterEnd
    }
    func insert(_ record: IslandActivityRecord) { records[record.identifier] = record }
    func removeAll() { records.removeAll() }
    func overrideInventory(_ records: [IslandActivityRecord]) { override = records }
    func failInventory() { inventoryFails = true }
    func failEnd(_ id: String) { endFailures.insert(id) }
    func loseRequestResponse() { requestResponseLost = true }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
    func changeState(_ id: String, to state: IslandActivityState) {
        if let record = records[id] { records[id] = .init(identifier: id, state: state, content: record.content, staleAt: record.staleAt) }
    }
    func activities(scope: IslandActivityScope) async throws -> [IslandActivityRecord]? {
        scopes.append(scope); await inventoryGate?.hold()
        if inventoryFails { inventoryFails = false; throw LifecycleTestError.privateFailure }
        if let override { return override }
        let result = records.values.filter { scope == .application || local.contains($0.identifier) }
        local.formUnion(result.map(\.identifier))
        return result
    }
    func isEnabled() async -> Bool { authorizations += 1; return enabled }
    func request(_ presentation: IslandActivityPresentation) async throws -> String {
        operations.append("request"); created += 1
        let id = "created-\(created)"
        await requestGate?.hold()
        contents.append(presentation)
        records[id] = .init(identifier: id, state: .active, content: presentation.state, staleAt: presentation.staleAt)
        local.insert(id)
        if requestResponseLost { requestResponseLost = false; throw LifecycleTestError.privateFailure }
        return id
    }
    func update(_ identifier: String, presentation: IslandActivityPresentation) async throws {
        operations.append("update:" + identifier); contents.append(presentation)
        records[identifier] = .init(identifier: identifier, state: .active, content: presentation.state, staleAt: presentation.staleAt)
    }
    func end(_ identifier: String) async throws {
        operations.append("end:" + identifier)
        if endFailures.remove(identifier) != nil { throw LifecycleTestError.privateFailure }
        records.removeValue(forKey: identifier); local.remove(identifier); afterEnd()
    }
}

private struct LifecycleFixture {
    let clock: LifecycleClock
    let client: LifecycleClient
    let scheduler: IslandActivityScheduler
    init(client: LifecycleClient = LifecycleClient(), timerGate: LifecycleGate? = nil) {
        let clock = LifecycleClock()
        self.clock = clock; self.client = client
        scheduler = IslandActivityScheduler(client: client, now: { clock.date() }, uptime: { clock.uptime() }, sleep: {
            clock.recordWait($0); await timerGate?.hold(); try Task.checkCancellation(); clock.advanceUptime($0)
        })
    }
}

private final class LifecycleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wall = lifecycleEpoch
    private var monotonic: TimeInterval = 100
    private var delays: [TimeInterval] = []
    func date() -> Date { lock.withLock { wall } }
    func setDate(_ value: Date) { lock.withLock { wall = value } }
    func uptime() -> TimeInterval { lock.withLock { monotonic } }
    func advanceUptime(_ value: TimeInterval) { lock.withLock { monotonic += value } }
    func recordWait(_ value: TimeInterval) { lock.withLock { delays.append(value) } }
    func waits() -> [TimeInterval] { lock.withLock { delays } }
}

private actor LifecycleGate {
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

private func lifecycleEntered(_ entries: AsyncStream<Void>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in entries { return }; throw CancellationError() }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw LifecycleTestError.privateFailure }
        defer { group.cancelAll() }; _ = try await group.next()
    }
}

private func lifecycleStopping(_ frames: AsyncStream<IslandActivityDelivery>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await frame in frames { if frame.phase == .stopping { return } }; throw CancellationError() }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw LifecycleTestError.privateFailure }
        defer { group.cancelAll() }; _ = try await group.next()
    }
}
