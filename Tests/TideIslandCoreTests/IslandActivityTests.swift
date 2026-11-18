import Foundation
import Testing
@testable import TideIslandCore

private let islandEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func islandProjectionUsesTheWaitingTargetAndEarliestParticipatingDeadline() throws {
    let work = islandEvent("work", .working), waiting = islandEvent("wait", .needsInput, time: 10)
    var store = SessionStore(); try store.receive([work, waiting])
    store.perform(.select, for: .init(sessionID: "work", eventID: work.id), at: islandEpoch.addingTimeInterval(20))
    let projected = try IslandActivityPresentationPolicy.standard.presentation(for: store.snapshot(at: islandEpoch.addingTimeInterval(20)),
                                                                              at: islandEpoch.addingTimeInterval(20))
    let presentation = try #require(projected)
    #expect(presentation.state.sessionID == "wait" && presentation.state.phase == .needsInput)
    #expect(presentation.state.workingCount == 1 && presentation.state.waitingCount == 1)
    #expect(presentation.state.updatedAt == waiting.occurredAt && presentation.staleAt == islandEpoch.addingTimeInterval(300))
    #expect(presentation.sessionURL.flatMap(SessionLink.sessionID) == "wait")
}

@Test func islandProjectionHidesTerminalIgnoredAndUnconfirmedSessions() throws {
    let policy = IslandActivityPresentationPolicy.standard
    for phase in [AgentPhase.completed, .failed, .interrupted, .ended] {
        let snapshot = try islandSnapshot([islandEvent("history", phase)])
        let result = try policy.presentation(for: snapshot, at: islandEpoch)
        #expect(result == nil)
    }
    let event = islandEvent("session", .working)
    var store = SessionStore(); try store.receive([event])
    let unavailable = try policy.presentation(for: store.snapshot(at: islandEpoch, sourceIssue: .channelUnavailable), at: islandEpoch)
    #expect(unavailable == nil)
    store.perform(.ignore, for: .init(sessionID: event.sessionID, eventID: event.id), at: islandEpoch)
    let ignored = try policy.presentation(for: store.snapshot(at: islandEpoch), at: islandEpoch)
    #expect(ignored == nil)
}

@Test func islandProjectionNeverPublishesPartiallyExpiredCachedCounts() throws {
    var store = SessionStore(); try store.receive([islandEvent("old", .working), islandEvent("new", .working, time: 20)])
    let cached = store.snapshot(at: islandEpoch.addingTimeInterval(20)), policy = IslandActivityPresentationPolicy.standard
    let expired = try policy.presentation(for: cached, at: islandEpoch.addingTimeInterval(300))
    #expect(expired == nil)
    let projected = try policy.presentation(for: store.snapshot(at: islandEpoch.addingTimeInterval(300)),
                                            at: islandEpoch.addingTimeInterval(300))
    let refreshed = try #require(projected)
    #expect(refreshed.state.workingCount == 1 && refreshed.state.sessionID == "new")
    #expect(refreshed.staleAt == islandEpoch.addingTimeInterval(320))
}

@Test func islandProjectionTreatsClockRollbackAndInvalidClocksConservatively() throws {
    let snapshot = try islandSnapshot([islandEvent("session", .working)])
    let policy = IslandActivityPresentationPolicy.standard
    let future = try policy.presentation(for: snapshot, at: islandEpoch.addingTimeInterval(-1))
    #expect(future == nil)
    #expect(throws: IslandActivityError.invalidClock) {
        try policy.presentation(for: snapshot, at: Date(timeIntervalSince1970: .nan))
    }
}

@Test func islandContentKeepsTheExistingSixFieldWireShapeAndExcludesContext() throws {
    let location = WaveLocation(blockID: UUID(), tabID: UUID(), waveVersion: "0.14.5", observedAt: islandEpoch, source: .environment)
    let event = AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: .working, occurredAt: islandEpoch,
                           waveLocation: location, context: EventContext(source: .manual, kind: .status, receivedAt: islandEpoch, toolName: "fixture-private-tool"))
    let snapshot = try islandSnapshot([event])
    let projected = try IslandActivityPresentationPolicy.standard.presentation(for: snapshot, at: islandEpoch)
    let presentation = try #require(projected)
    let data = try EventCodec.jsonEncoder().encode(presentation.state)
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(fields.keys) == ["sessionID", "projectName", "phase", "workingCount", "waitingCount", "updatedAt"])
    let restored = try EventCodec.jsonDecoder().decode(IslandActivityContent.self, from: data)
    #expect(restored == presentation.state)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("fixture-private") && !text.contains("waveLocation") && !text.contains(location.blockID.uuidString))
}

@Test func islandContentRejectsInvalidCountsAndIdentityOnDecode() throws {
    let valid = IslandActivityContent(sessionID: "session", projectName: "project", phase: .working,
                                      workingCount: 1, waitingCount: 0, updatedAt: islandEpoch)
    let data = try EventCodec.jsonEncoder().encode(valid)
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let invalid: [[String: Any]] = [["workingCount": -1], ["workingCount": 0], ["phase": "failed"],
                                   ["waitingCount": -1], ["workingCount": Int.max, "waitingCount": 1],
                                   ["sessionID": "bad\nidentity"], ["projectName": String(repeating: "x", count: 161)]]
    for changes in invalid {
        let fields = original.merging(changes) { _, new in new }
        let bytes = try JSONSerialization.data(withJSONObject: fields)
        #expect(throws: (any Error).self) { try EventCodec.jsonDecoder().decode(IslandActivityContent.self, from: bytes) }
    }
}

@Test func islandContentSupportsValidUnicodeBoundsWithoutTruncatingMetadata() throws {
    let state = IslandActivityContent(sessionID: String(repeating: "🐚", count: 64), projectName: String(repeating: "潮", count: 53),
                                      phase: .needsInput, workingCount: 1, waitingCount: 1, updatedAt: islandEpoch)
    try IslandActivityPresentationPolicy.standard.validate(state)
    let decoded = try EventCodec.jsonDecoder().decode(IslandActivityContent.self, from: EventCodec.jsonEncoder().encode(state))
    #expect(decoded == state && SessionLink.url(for: decoded.sessionID) != nil)
}

@Test func islandOverviewPrioritizesWaitingAndKeepsTheFullAggregateDeadline() throws {
    var store = SessionStore()
    try store.receive([
        islandEvent("wait-new", .needsInput, time: -5), islandEvent("wait-old", .needsInput, time: -15),
        islandEvent("pinned", .working, time: -30), islandEvent("selected", .working, time: -100),
        islandEvent("ignored", .needsInput), islandEvent("stale", .working, time: -310),
        islandEvent("done", .completed, time: -20),
    ])
    for (id, action) in [("ignored", SessionAction.ignore), ("selected", .select), ("pinned", .pin)] {
        let session = try #require(store.snapshot(at: islandEpoch).sessions.first(where: { $0.id == id }))
        let applied = store.perform(action, for: session.reference, at: islandEpoch)
        #expect(applied)
    }
    let snapshot = store.snapshot(at: islandEpoch)
    let projected = try IslandActivityPresentationPolicy.standard.presentation(for: snapshot, at: islandEpoch)
    let result = try #require(projected)
    let display = IslandActivityViewState(content: result.state, isStale: false)
    #expect(display.overviewSessions.map(\.id) == ["wait-new", "wait-old", "pinned"])
    #expect(result.state.workingCount == 2 && result.state.waitingCount == 2 && display.liveCount == 4)
    #expect(result.staleAt == islandEpoch.addingTimeInterval(200))
}

@Test func islandOverviewHidesNamesAndKeepsDistinctLinksForDuplicateProjects() throws {
    let ids = ["wait / ? & 🐚", "work / ? & 🐚"]
    let snapshot = try islandSnapshot([
        AgentEvent(sessionID: ids[0], projectName: "fixture-private-project", phase: .needsInput, occurredAt: islandEpoch),
        AgentEvent(sessionID: ids[1], projectName: "fixture-private-project", phase: .working, occurredAt: islandEpoch),
    ])
    let policy = IslandActivityPresentationPolicy.standard
    let projected = try policy.presentation(for: snapshot, at: islandEpoch, showsProjectName: false)
    let hidden = try #require(projected)
    let data = try EventCodec.jsonEncoder().encode(hidden.state)
    #expect(!String(decoding: data, as: UTF8.self).contains("fixture-private-project"))
    let decoded = try EventCodec.jsonDecoder().decode(IslandActivityContent.self, from: data)
    let overview = IslandActivityViewState(content: decoded, isStale: false).overviewSessions
    #expect(decoded == hidden.state && overview.map(\.projectName) == ["开发会话", "开发会话"])
    #expect(overview.map(\.id) == ids)
    for session in overview {
        let link = try #require(SessionLink.url(for: session.id))
        let reference = try SessionLink.resolve(link, in: snapshot, at: islandEpoch).get()
        #expect(reference.sessionID == session.id)
    }
    let stale = IslandActivityViewState(content: decoded, isStale: true)
    #expect(stale.overviewSessions.isEmpty && stale.liveCount == 0)
}

@Test func islandOverviewRejectsInvalidOrRepeatedIdentitiesAndImpossibleCounts() throws {
    let policy = IslandActivityPresentationPolicy.standard
    let attempted = [
        IslandActivitySession(sessionID: "primary", projectName: "copy", phase: .working),
        IslandActivitySession(sessionID: "bad\nidentity", projectName: "bad", phase: .working),
        IslandActivitySession(sessionID: "bad", projectName: "bad", phase: .completed),
        IslandActivitySession(sessionID: "bad", projectName: "bad", phase: .needsInput),
    ]
    for row in attempted {
        let content = IslandActivityContent(sessionID: "primary", projectName: "one", phase: .working,
                                            workingCount: 2, waitingCount: 0, updatedAt: islandEpoch, otherSessions: [row])
        #expect(throws: IslandActivityError.invalidContent) { try policy.validate(content) }
        #expect(throws: IslandActivityError.invalidContent) {
            try EventCodec.jsonDecoder().decode(IslandActivityContent.self, from: EventCodec.jsonEncoder().encode(content))
        }
    }
}

@Test func islandOverviewFitsMaximumEscapedNamesTogetherWithQuota() throws {
    let ids = (1...3).map { String(repeating: "\\", count: 255) + String($0) }
    let project = String(repeating: "\"", count: 160)
    let snapshot = try islandSnapshot(ids.map {
        AgentEvent(sessionID: $0, projectName: project, phase: .working, occurredAt: islandEpoch)
    })
    let quota = try CodexQuotaSnapshot.decodeResponse(
        Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":11,"windowDurationMins":300,"resetsAt":1800002500},"secondary":{"usedPercent":63,"windowDurationMins":10080,"resetsAt":1800080000}}}}"#.utf8),
        requestID: 2, checkedAt: islandEpoch)
    let policy = IslandActivityPresentationPolicy.standard
    let projected = try policy.presentation(for: snapshot, at: islandEpoch, showsProjectName: true, codexQuota: quota)
    let result = try #require(projected)
    #expect(result.state.codexQuota == quota && result.state.otherSessions?.map(\.id) == Array(ids.dropFirst()))
    #expect(try EventCodec.jsonEncoder().encode(result.state).count <= policy.maximumContentBytes)
}

@Test func islandControllerRequestsUpdatesAndEndsTheSameOwnedActivity() async throws {
    let client = IslandTestClient(), controller = IslandActivityController(client: client, now: { islandEpoch.addingTimeInterval(20) })
    let first = try islandSnapshot([islandEvent("one", .working)], time: 20)
    let second = try islandSnapshot([islandEvent("two", .needsInput, time: 10)], time: 20)
    try await controller.update(snapshot: first); try await controller.update(snapshot: second)
    try await controller.update(snapshot: islandSnapshot([]))
    let calls = await client.calls, content = await client.presentations
    #expect(calls == ["authorize", "request", "authorize", "update:owned", "end:owned"])
    #expect(content.map(\.state.sessionID) == ["one", "two"])
    #expect(content.map(\.state.updatedAt) == [islandEpoch, islandEpoch.addingTimeInterval(10)])
}

@Test func islandControllerSkipsAuthorizationForAnEmptySnapshotAndCanEndAfterRevocation() async throws {
    let client = IslandTestClient(), controller = IslandActivityController(client: client, now: { islandEpoch })
    try await controller.update(snapshot: islandSnapshot([]))
    let initialCalls = await client.calls
    #expect(initialCalls.isEmpty)
    try await controller.update(snapshot: islandSnapshot([islandEvent("session", .working)]))
    await client.setEnabled(false)
    try await controller.update(snapshot: islandSnapshot([]))
    let calls = await client.calls
    #expect(calls == ["authorize", "request", "end:owned"])
}

@Test func islandControllerReportsDisabledWithoutRequestingAnActivity() async throws {
    let client = IslandTestClient(enabled: false), controller = IslandActivityController(client: client, now: { islandEpoch })
    let snapshot = try islandSnapshot([islandEvent("session", .working)])
    let error = await islandFailure { try await controller.update(snapshot: snapshot) }
    let calls = await client.calls
    #expect(error == .disabled && calls == ["authorize"])
}

@Test func islandControllerRechecksExpiryAfterTheAuthorizationAwait() async throws {
    let clock = IslandTestClock()
    let client = IslandTestClient(afterAuthorization: { clock.set(islandEpoch.addingTimeInterval(300)) })
    let controller = IslandActivityController(client: client, now: { clock.read() })
    try await controller.update(snapshot: islandSnapshot([islandEvent("session", .working)]))
    let calls = await client.calls
    #expect(calls == ["authorize"])
}

@Test func islandControllerRequestFailuresAreSanitizedAndDoNotInventAnOwnedID() async throws {
    let client = IslandTestClient(failure: .request), controller = IslandActivityController(client: client, now: { islandEpoch })
    let snapshot = try islandSnapshot([islandEvent("session", .working)])
    let error = await islandFailure { try await controller.update(snapshot: snapshot) }
    #expect(error == .requestFailed)
    try await controller.update(snapshot: snapshot)
    let calls = await client.calls
    #expect(calls == ["authorize", "request", "authorize", "request"])
}

@Test func islandControllerUpdateFailureKeepsTheOwnedIDForTheNextExplicitUpdate() async throws {
    let client = IslandTestClient(failure: .update), controller = IslandActivityController(client: client, now: { islandEpoch })
    let snapshot = try islandSnapshot([islandEvent("session", .working)])
    try await controller.update(snapshot: snapshot)
    let error = await islandFailure { try await controller.update(snapshot: snapshot) }
    #expect(error == .updateFailed)
    try await controller.update(snapshot: snapshot)
    let calls = await client.calls
    #expect(calls == ["authorize", "request", "authorize", "update:owned", "authorize", "update:owned"])
}

@Test func islandControllerPreservesForegroundRequirementAndRetriesWithoutInventingOwnership() async throws {
    let client = IslandTestClient(failure: .foreground), controller = IslandActivityController(client: client, now: { islandEpoch })
    let snapshot = try islandSnapshot([islandEvent("session", .working)])
    let problem = await islandFailure { try await controller.update(snapshot: snapshot) }
    #expect(problem == .foregroundRequired)
    let failedCalls = await client.calls
    #expect(failedCalls == ["authorize", "request"])
    try await controller.update(snapshot: snapshot)
    try await controller.update(snapshot: islandSnapshot([]))
    let calls = await client.calls
    #expect(calls == ["authorize", "request", "authorize", "request", "end:owned"])
}

@Test func islandControllerDoesNotForwardUnrelatedTypedRequestErrors() async throws {
    let client = IslandTestClient(failure: .unexpectedTypedRequest), controller = IslandActivityController(client: client, now: { islandEpoch })
    let snapshot = try islandSnapshot([islandEvent("session", .working)])
    let problem = await islandFailure { try await controller.update(snapshot: snapshot) }
    #expect(problem == .requestFailed)
}

@Test func islandControllerEndFailureRetainsOwnershipUntilTheEndSucceeds() async throws {
    let client = IslandTestClient(failure: .end), controller = IslandActivityController(client: client, now: { islandEpoch })
    try await controller.update(snapshot: islandSnapshot([islandEvent("session", .working)]))
    let empty = try islandSnapshot([])
    let error = await islandFailure { try await controller.update(snapshot: empty) }
    #expect(error == .endFailed)
    try await controller.update(snapshot: empty); try await controller.update(snapshot: empty)
    let calls = await client.calls
    #expect(calls == ["authorize", "request", "end:owned", "end:owned"])
}

@Test func islandControllerCancellationDuringAuthorizationWinsOverDisabled() async throws {
    let gate = IslandGate(), client = IslandTestClient(enabled: false, authorizationGate: gate)
    let controller = IslandActivityController(client: client, now: { islandEpoch })
    let snapshot = try islandSnapshot([islandEvent("session", .working)])
    let pending = Task { try await controller.update(snapshot: snapshot) }
    try await islandWaitForEntry(gate.entries)
    pending.cancel(); await gate.open()
    do { try await pending.value; Issue.record("Cancelled authorization was accepted") }
    catch { #expect(error is CancellationError) }
    let calls = await client.calls
    #expect(calls == ["authorize"])
}

@Test func islandControllerRemembersACreatedActivityEvenWhenTheCallerCancels() async throws {
    let gate = IslandGate(), client = IslandTestClient(requestGate: gate)
    let controller = IslandActivityController(client: client, now: { islandEpoch })
    let snapshot = try islandSnapshot([islandEvent("session", .working)])
    let pending = Task { try await controller.update(snapshot: snapshot) }
    try await islandWaitForEntry(gate.entries)
    pending.cancel(); await gate.open()
    do { try await pending.value; Issue.record("Cancelled request was accepted") }
    catch { #expect(error is CancellationError) }
    try await controller.update(snapshot: islandSnapshot([]))
    let calls = await client.calls
    #expect(calls == ["authorize", "request", "end:owned"])
}

@Test func islandControllerPreventsOverlappingLifecycleCallsAndReleasesItsGate() async throws {
    let gate = IslandGate(), client = IslandTestClient(requestGate: gate)
    let controller = IslandActivityController(client: client, now: { islandEpoch })
    let snapshot = try islandSnapshot([islandEvent("session", .working)])
    let pending = Task { try await controller.update(snapshot: snapshot) }
    try await islandWaitForEntry(gate.entries)
    let error = await islandFailure { try await controller.update(snapshot: snapshot) }
    #expect(error == .busy)
    await gate.open(); try await pending.value
    try await controller.update(snapshot: snapshot)
    let calls = await client.calls
    #expect(calls == ["authorize", "request", "authorize", "update:owned"])
}

private func islandEvent(_ session: String, _ phase: AgentPhase, time: TimeInterval = 0) -> AgentEvent {
    let at = islandEpoch.addingTimeInterval(time)
    return AgentEvent(version: 2, sessionID: session, projectName: "project", phase: phase, occurredAt: at,
                      context: EventContext(source: .manual, kind: .status, receivedAt: at))
}

private func islandSnapshot(_ events: [AgentEvent], time: TimeInterval = 0) throws -> SessionSnapshot {
    var store = SessionStore(); try store.receive(events)
    return store.snapshot(at: islandEpoch.addingTimeInterval(time))
}

private func islandFailure(_ operation: @Sendable () async throws -> Void) async -> IslandActivityError? {
    do { try await operation(); return nil }
    catch { return error as? IslandActivityError }
}

private enum IslandTestFailure: Sendable { case none, request, foreground, unexpectedTypedRequest, update, end }
private enum IslandTestError: Error { case privateClientFailure }

private actor IslandTestClient: IslandActivityClient {
    var calls: [String] = []
    var presentations: [IslandActivityPresentation] = []
    var enabled: Bool
    var failure: IslandTestFailure
    let afterAuthorization: @Sendable () async -> Void
    let authorizationGate: IslandGate?
    let requestGate: IslandGate?

    init(enabled: Bool = true, failure: IslandTestFailure = .none, afterAuthorization: @escaping @Sendable () async -> Void = {},
         authorizationGate: IslandGate? = nil, requestGate: IslandGate? = nil) {
        self.enabled = enabled; self.failure = failure; self.afterAuthorization = afterAuthorization
        self.authorizationGate = authorizationGate; self.requestGate = requestGate
    }
    func setEnabled(_ value: Bool) { enabled = value }
    func isEnabled() async -> Bool {
        calls.append("authorize"); await authorizationGate?.hold(); await afterAuthorization()
        return enabled
    }
    func request(_ presentation: IslandActivityPresentation) async throws -> String {
        calls.append("request")
        if failure == .request { failure = .none; throw IslandTestError.privateClientFailure }
        if failure == .foreground { failure = .none; throw IslandActivityError.foregroundRequired }
        if failure == .unexpectedTypedRequest { failure = .none; throw IslandActivityError.invalidInventory }
        await requestGate?.hold()
        presentations.append(presentation)
        return "owned"
    }
    func update(_ identifier: String, presentation: IslandActivityPresentation) async throws {
        calls.append("update:" + identifier)
        if failure == .update { failure = .none; throw IslandTestError.privateClientFailure }
        presentations.append(presentation)
    }
    func end(_ identifier: String) async throws {
        calls.append("end:" + identifier)
        if failure == .end { failure = .none; throw IslandTestError.privateClientFailure }
    }
}

private final class IslandTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = islandEpoch
    func read() -> Date { lock.withLock { time } }
    func set(_ value: Date) { lock.withLock { time = value } }
}

private actor IslandGate {
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

private func islandWaitForEntry(_ entries: AsyncStream<Void>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in entries { return }; throw CancellationError() }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw IslandTestError.privateClientFailure }
        defer { group.cancelAll() }
        _ = try await group.next()
    }
}
