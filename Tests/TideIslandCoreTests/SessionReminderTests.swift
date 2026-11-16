import Foundation
import Testing
@testable import TideIslandCore

private let reminderEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private let remindersEnabled = SessionReminderSettings(enabled: true)
private var reminderCalendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }

@Test func remindersBaselineExistingStatesWithoutReplayingStartupHistory() async {
    let fixture = ReminderFixture(), existing = reminderSnapshot(.needsInput)
    await fixture.submit(existing, 1); await fixture.coordinator.flush()
    await fixture.submit(reminderSnapshot(.needsInput), 2); await fixture.coordinator.flush()
    let calls = await fixture.client.authorizationCalls, posted = await fixture.client.posted
    #expect(calls == 0 && posted.isEmpty)
}

@Test func remindersPostNewWaitingMetadataWithOptionalSoundAndSessionURL() async {
    let fixture = ReminderFixture(); await fixture.baseline()
    let snapshot = reminderSnapshot(.needsInput, id: "会话 / & ?", project: "project")
    await fixture.submit(snapshot, 2, settings: .init(enabled: true, sound: true)); await fixture.coordinator.flush()
    let posted = await fixture.client.posted
    let linked = posted.first.flatMap { SessionLink.sessionID(from: $0.sessionURL) }
    #expect(posted.count == 1 && posted.first?.title == "等待你处理" && posted.first?.body == "project")
    #expect(posted.first?.sound == true && linked == "会话 / & ?")
    #expect(posted.first?.occurredAt == reminderEpoch && (posted.first?.identifier.utf8.count ?? 0) <= 128)
}

@Test func remindersTurnEndDoesNotClaimTaskCompletionOrTestingSuccess() async {
    let fixture = ReminderFixture(); await fixture.baseline()
    await fixture.submit(reminderSnapshot(.completed), 2); await fixture.coordinator.flush()
    let posted = await fixture.client.posted
    #expect(posted.first?.kind == .turnEnded && posted.first?.title == "本轮已结束")
    #expect(posted.first?.body == "project" && posted.first?.sound == false)
    for phase in [AgentPhase.failed, .interrupted, .ended] {
        await fixture.submit(reminderSnapshot(phase), UInt64(phase.attentionPriority + 10)); await fixture.coordinator.flush()
    }
    let final = await fixture.client.posted, result = await fixture.coordinator.current()
    #expect(final.count == 1 && result.problem == nil)
    let muted = ReminderFixture(); await muted.baseline()
    await muted.submit(reminderSnapshot(.completed), 2, settings: .init(enabled: true, turnEnded: false))
    await muted.coordinator.flush()
    let mutedPosts = await muted.client.posted
    #expect(mutedPosts.isEmpty)
}

@Test func remindersDeduplicateDifferentUUIDsWithinTheSameWaitingEpisode() async {
    let fixture = ReminderFixture(); await fixture.baseline()
    await fixture.submit(reminderSnapshot(.needsInput), 2); await fixture.coordinator.flush()
    for sequence in 3...20 { await fixture.submit(reminderSnapshot(.needsInput), UInt64(sequence)) }
    await fixture.coordinator.flush()
    let posted = await fixture.client.posted
    #expect(posted.count == 1)
}

@Test func remindersWorkResumptionStartsANewWaitingEpisode() async {
    let fixture = ReminderFixture(); await fixture.baseline()
    await fixture.submit(reminderSnapshot(.needsInput), 2); await fixture.coordinator.flush()
    await fixture.submit(reminderSnapshot(.working), 3); await fixture.coordinator.flush()
    await fixture.submit(reminderSnapshot(.needsInput), 4); await fixture.coordinator.flush()
    let posted = await fixture.client.posted
    #expect(posted.count == 2 && posted[0].identifier != posted[1].identifier)
}

@Test func remindersKnownTurnChangeCanStartANewEpisodeWithoutAnIntermediateFrame() async {
    let fixture = ReminderFixture(); await fixture.baseline()
    await fixture.submit(reminderSnapshot(.completed, turn: "turn-a"), 2); await fixture.coordinator.flush()
    await fixture.submit(reminderSnapshot(.completed, turn: "turn-b"), 3); await fixture.coordinator.flush()
    let posted = await fixture.client.posted
    #expect(posted.count == 2 && posted[0].identifier != posted[1].identifier)
}

@Test func remindersKeepSessionsIndependentAndPrioritizeWaitingBeforeTurnEnd() async {
    let fixture = ReminderFixture(); await fixture.baseline()
    let a = reminderSnapshot(.completed, id: "a"), b = reminderSnapshot(.needsInput, id: "b")
    let combined = SessionSnapshot(sessions: a.sessions + b.sessions, ignoredSessions: [], preferredSessionID: nil, nextTransitionAt: nil)
    await fixture.submit(combined, 2); await fixture.coordinator.flush()
    let posted = await fixture.client.posted, maximum = await fixture.client.maximumOperations
    #expect(posted.map(\.reference.sessionID) == ["b", "a"] && maximum == 1)
}

@Test func remindersReadIgnoredAndDisabledEpisodesDoNotCatchUpOnOrdinaryRefresh() async {
    for choice in 0..<4 {
        let fixture = ReminderFixture(); await fixture.baseline()
        let snapshot = reminderSnapshot(.needsInput, read: choice == 0, ignored: choice == 1)
        let settings = choice == 2 ? SessionReminderSettings() : choice == 3 ? .init(enabled: true, needsInput: false) : remindersEnabled
        await fixture.submit(snapshot, 2, settings: settings); await fixture.coordinator.flush()
        await fixture.submit(reminderSnapshot(.needsInput), 3); await fixture.coordinator.flush()
        let posted = await fixture.client.posted, authorizations = await fixture.client.authorizationCalls
        #expect(posted.isEmpty && authorizations == 0)
    }
}

@Test func remindersSelectionAndOpeningWaveAloneAreNotVerifiedViewingEvidence() async {
    let fixture = ReminderFixture(); await fixture.baseline()
    await fixture.submit(reminderSnapshot(.needsInput, selected: true), 2); await fixture.coordinator.flush()
    let posted = await fixture.client.posted
    #expect(posted.count == 1)
}

@Test func remindersSuppressOnlyTheExactlyVerifiedCurrentWaveBlock() async throws {
    let fixture = ReminderFixture(); await fixture.baseline()
    let location = reminderLocation(), snapshot = reminderSnapshot(.needsInput, location: location)
    let reference = snapshot.sessions[0].reference
    let viewing = VerifiedSessionViewing(reference: reference, blockID: location.blockID, tabID: location.tabID!,
                                         observedAt: reminderEpoch, validUntil: reminderEpoch.addingTimeInterval(5))
    await fixture.submit(snapshot, 2, viewing: viewing); await fixture.coordinator.flush()
    let posted = await fixture.client.posted, queries = await fixture.client.authorizationCalls
    #expect(posted.isEmpty && queries == 0)
    for expires in [false, true] {
        let gate = ReminderGate(), delayed = ReminderFixture(client: ReminderClient(authorizationGate: gate))
        await delayed.baseline()
        await delayed.submit(snapshot, 2)
        try await reminderEntered(gate.entries)
        await delayed.submit(snapshot, 3, viewing: viewing)
        if expires { delayed.clock.set(reminderEpoch.addingTimeInterval(5)) }
        await gate.open(); await delayed.coordinator.flush()
        let latest = await delayed.client.posted
        #expect(latest.count == (expires ? 1 : 0))
    }
}

@Test func remindersDoNotSuppressForMismatchedExpiredFutureOrUnboundedViewingClaims() async {
    for variant in 0..<6 {
        let fixture = ReminderFixture(); await fixture.baseline()
        let location = reminderLocation(), snapshot = reminderSnapshot(.needsInput, location: location)
        let reference = variant == 0 ? SessionReference(sessionID: "other", eventID: UUID()) : snapshot.sessions[0].reference
        let viewing = VerifiedSessionViewing(reference: reference, blockID: variant == 1 ? UUID() : location.blockID,
                                             tabID: variant == 2 ? UUID() : location.tabID!,
                                             observedAt: reminderEpoch.addingTimeInterval(variant == 3 ? 1 : variant == 4 ? -10 : 0),
                                             validUntil: reminderEpoch.addingTimeInterval(variant == 4 ? -5 : variant == 5 ? 60 : 5))
        await fixture.submit(snapshot, 2, viewing: viewing); await fixture.coordinator.flush()
        let posted = await fixture.client.posted
        #expect(posted.count == 1)
    }
}

@Test func remindersUnconfirmedNewEvidenceWaitsForPrimarySourceRecovery() async {
    let fixture = ReminderFixture(); await fixture.baseline(reminderSnapshot(.working))
    let waiting = reminderSnapshot(.needsInput)
    await fixture.submit(waiting, 2, primary: false); await fixture.coordinator.flush()
    let before = await fixture.client.posted
    #expect(before.isEmpty)
    await fixture.submit(waiting, 3); await fixture.coordinator.flush()
    let after = await fixture.client.posted
    #expect(after.count == 1)
}

@Test func remindersBaselineAlsoRemembersUnconfirmedStartupHistory() async {
    let fixture = ReminderFixture()
    let initial = reminderSnapshot(.needsInput, issue: .eventMissing)
    await fixture.submit(initial, 1); await fixture.coordinator.flush()
    await fixture.submit(reminderSnapshot(.needsInput), 2); await fixture.coordinator.flush()
    let posted = await fixture.client.posted
    #expect(posted.isEmpty)
}

@Test func remindersDoNotAlertFromStaleFutureOrMissingObservations() async {
    for choice in 0..<3 {
        let fixture = ReminderFixture(); await fixture.baseline()
        let snapshot = reminderSnapshot(.needsInput, at: reminderEpoch.addingTimeInterval(choice == 0 ? -300 : choice == 1 ? 1 : 0),
                                         issue: choice == 2 ? .eventMissing : nil)
        await fixture.submit(snapshot, 2); await fixture.coordinator.flush()
        let posted = await fixture.client.posted, queries = await fixture.client.authorizationCalls
        #expect(posted.isEmpty && queries == 0)
    }
}

@Test func remindersQuietHoursCrossMidnightAndSuppressCatchUpAfterTheWindow() async throws {
    let quiet = try SessionQuietHours(startMinute: 22 * 60, endMinute: 8 * 60)
    let settings = SessionReminderSettings(enabled: true, quietHours: quiet)
    let fixture = ReminderFixture(); await fixture.baseline()
    fixture.clock.set(reminderDate("2026-11-17T23:00:00Z"))
    await fixture.submit(reminderSnapshot(.needsInput, at: fixture.clock.read(), projectedAt: fixture.clock.read()), 2, settings: settings); await fixture.coordinator.flush()
    fixture.clock.set(reminderDate("2026-11-18T08:00:00Z"))
    await fixture.submit(reminderSnapshot(.needsInput, at: fixture.clock.read(), projectedAt: fixture.clock.read()), 3, settings: settings); await fixture.coordinator.flush()
    let suppressed = await fixture.client.posted
    #expect(suppressed.isEmpty)
    await fixture.submit(reminderSnapshot(.working, at: fixture.clock.read(), projectedAt: fixture.clock.read()), 4, settings: settings); await fixture.coordinator.flush()
    await fixture.submit(reminderSnapshot(.needsInput, at: fixture.clock.read(), projectedAt: fixture.clock.read()), 5, settings: settings); await fixture.coordinator.flush()
    let resumed = await fixture.client.posted
    #expect(resumed.count == 1)
}

@Test func reminderQuietHoursValidateDecodeAndUseInclusiveStartExclusiveEnd() throws {
    for pair in [(-1, 60), (0, 1440), (120, 120)] {
        #expect(throws: SessionReminderProblem.invalidSnapshot) { try SessionQuietHours(startMinute: pair.0, endMinute: pair.1) }
    }
    let invalid = Data("{\"startMinute\":-1,\"endMinute\":60}".utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SessionQuietHours.self, from: invalid) }
    let quiet = try SessionQuietHours(startMinute: 9 * 60, endMinute: 10 * 60)
    #expect(!quiet.contains(reminderDate("2026-11-17T08:59:00Z"), calendar: reminderCalendar))
    #expect(quiet.contains(reminderDate("2026-11-17T09:00:00Z"), calendar: reminderCalendar))
    #expect(!quiet.contains(reminderDate("2026-11-17T10:00:00Z"), calendar: reminderCalendar))
}

@Test func reminderQuietHoursUseLocalWallTimeForBothRepeatedDSTHours() throws {
    var calendar = reminderCalendar; calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let quiet = try SessionQuietHours(startMinute: 60, endMinute: 120)
    #expect(quiet.contains(reminderDate("2026-11-01T08:30:00Z"), calendar: calendar))
    #expect(quiet.contains(reminderDate("2026-11-01T09:30:00Z"), calendar: calendar))
    #expect(!quiet.contains(reminderDate("2026-11-01T10:00:00Z"), calendar: calendar))
}

@Test func remindersQueryPermissionWithoutPromptingAndRetryOnlyOnNewInput() async {
    for authorization in [SessionReminderAuthorization.notRequested, .denied] {
        let client = ReminderClient(authorization: authorization), fixture = ReminderFixture(client: client)
        await fixture.baseline(); let snapshot = reminderSnapshot(.needsInput)
        await fixture.submit(snapshot, 2); await fixture.coordinator.flush()
        let failed = await fixture.coordinator.current(), before = await client.posted
        #expect(before.isEmpty && failed.problem == (authorization == .notRequested ? .authorizationNotRequested : .permissionDenied))
        await client.setAuthorization(.allowed)
        await fixture.submit(snapshot, 3); await fixture.coordinator.flush()
        let after = await client.posted
        #expect(after.count == 1)
    }
}

@Test func remindersUncertainPostFailureNeverAutomaticallyRepostsTheSameEpisode() async throws {
    let client = ReminderClient(loseResponse: true), fixture = ReminderFixture(client: client)
    await fixture.baseline(); let snapshot = reminderSnapshot(.needsInput)
    await fixture.submit(snapshot, 2); await fixture.coordinator.flush()
    await fixture.submit(reminderSnapshot(.needsInput), 3); await fixture.coordinator.flush()
    let before = await client.posted, calls = await client.postCalls, failed = await fixture.coordinator.current()
    #expect(before.count == 1 && calls == 1 && failed.problem == .deliveryFailed && failed.submittedCount == 0)
    await fixture.submit(reminderSnapshot(.working), 4); await fixture.coordinator.flush()
    await fixture.submit(reminderSnapshot(.needsInput), 5); await fixture.coordinator.flush()
    let recovered = await fixture.coordinator.current()
    #expect(recovered.problem == nil && recovered.submittedCount == 1)
    let gate = ReminderGate(), queuedClient = ReminderClient(postGate: gate, loseResponse: true)
    let queued = ReminderFixture(client: queuedClient); await queued.baseline()
    await queued.submit(reminderSnapshot(.needsInput), 2)
    try await reminderEntered(gate.entries)
    await queued.submit(reminderSnapshot(.completed), 3)
    await gate.open(); await queued.coordinator.flush()
    let pending = await queuedClient.posted, delivered = await queued.coordinator.current()
    #expect(pending.count == 2 && pending.last?.kind == .turnEnded && delivered.submittedCount == 1)
}

@Test func remindersRecheckResumptionAndSourceAuthorityAfterPermissionAwait() async throws {
    for primary in [false, true] {
        let gate = ReminderGate(), fixture = ReminderFixture(client: ReminderClient(authorizationGate: gate))
        await fixture.baseline()
        await fixture.submit(reminderSnapshot(.needsInput), 2)
        try await reminderEntered(gate.entries)
        await fixture.submit(reminderSnapshot(primary ? .working : .needsInput), 3, primary: primary)
        await gate.open(); await fixture.coordinator.flush()
        let posted = await fixture.client.posted
        #expect(posted.isEmpty)
    }
}

@Test func remindersUseTheNewestReferenceMetadataAndSoundAfterPermissionAwait() async throws {
    let gate = ReminderGate(), fixture = ReminderFixture(client: ReminderClient(authorizationGate: gate))
    await fixture.baseline()
    await fixture.submit(reminderSnapshot(.needsInput), 2)
    try await reminderEntered(gate.entries)
    let latest = reminderSnapshot(.needsInput, project: "latest")
    await fixture.submit(latest, 3, settings: .init(enabled: true, sound: true))
    await gate.open(); await fixture.coordinator.flush()
    let posted = await fixture.client.posted
    #expect(posted.count == 1 && posted.first?.reference == latest.sessions.first?.reference)
    #expect(posted.first?.projectName == "latest" && posted.first?.sound == true)
}

@Test func remindersRecheckExpiryAndQuietHoursAfterPermissionAwait() async throws {
    for choice in 0..<2 {
        let gate = ReminderGate(), fixture = ReminderFixture(client: ReminderClient(authorizationGate: gate))
        let quiet = try SessionQuietHours(startMinute: 22 * 60, endMinute: 8 * 60)
        let settings = choice == 0 ? remindersEnabled : SessionReminderSettings(enabled: true, quietHours: quiet)
        if choice == 1 { fixture.clock.set(reminderDate("2026-11-17T21:59:00Z")) }
        await fixture.baseline()
        await fixture.submit(reminderSnapshot(.needsInput, at: fixture.clock.read(), projectedAt: fixture.clock.read()), 2, settings: settings)
        try await reminderEntered(gate.entries)
        fixture.clock.set(fixture.clock.read().addingTimeInterval(choice == 0 ? 300 : 60))
        await gate.open(); await fixture.coordinator.flush()
        let posted = await fixture.client.posted
        #expect(posted.isEmpty)
    }
}

@Test func remindersInvalidLatestSnapshotCannotLeaveAnOlderNotificationUsable() async throws {
    for posting in [false, true] {
        let gate = ReminderGate()
        let fixture = ReminderFixture(client: ReminderClient(authorizationGate: posting ? nil : gate, postGate: posting ? gate : nil))
        await fixture.baseline()
        let snapshot = reminderSnapshot(.needsInput)
        await fixture.submit(snapshot, 2)
        try await reminderEntered(gate.entries)
        let invalid = SessionSnapshot(sessions: snapshot.sessions + snapshot.sessions, ignoredSessions: [], preferredSessionID: nil, nextTransitionAt: nil)
        await fixture.submit(invalid, 3)
        await gate.open(); await fixture.coordinator.flush()
        let posted = await fixture.client.posted, result = await fixture.coordinator.current()
        #expect(posted.count == (posting ? 1 : 0) && result.problem == .invalidSnapshot && result.sourceSequence == 3)
    }
}

@Test func remindersRejectLateSourceSequencesIncludingTheirAuthorityAndSettings() async {
    let fixture = ReminderFixture(); await fixture.baseline()
    let current = reminderSnapshot(.needsInput)
    await fixture.submit(current, 3)
    let rejected = await fixture.coordinator.submit(snapshot: reminderSnapshot(nil), sequence: 2, isPrimary: false, settings: .init())
    await fixture.coordinator.flush()
    let posted = await fixture.client.posted
    #expect(!rejected && posted.count == 1)
}

@Test func remindersOversizedSourceFailsClosedWithoutSilentlyEvictingDedupHistory() async {
    let fixture = ReminderFixture(); await fixture.baseline()
    let statuses = (0...SessionReminderCoordinator.maximumSessions).flatMap { reminderSnapshot(.needsInput, id: "session-\($0)").sessions }
    let huge = SessionSnapshot(sessions: statuses, ignoredSessions: [], preferredSessionID: nil, nextTransitionAt: nil)
    await fixture.submit(huge, 2); await fixture.coordinator.flush()
    let result = await fixture.coordinator.current(), posted = await fixture.client.posted
    #expect(result.problem == .capacityExceeded && posted.isEmpty)
}

@Test func remindersShutdownSettlesAnInflightPostAndRejectsNewAlerts() async throws {
    let gate = ReminderGate(), client = ReminderClient(postGate: gate), fixture = ReminderFixture(client: client)
    await fixture.baseline()
    await fixture.submit(reminderSnapshot(.needsInput), 2)
    try await reminderEntered(gate.entries)
    let shutdown = Task { await fixture.coordinator.shutdown() }
    try await reminderStopped(fixture.coordinator.frames)
    let accepted = await fixture.coordinator.submit(snapshot: reminderSnapshot(.completed), sequence: 3, isPrimary: true, settings: remindersEnabled)
    await gate.open(); await shutdown.value
    let posted = await client.posted, result = await fixture.coordinator.current()
    #expect(!accepted && posted.count == 1 && result.stopped && result.submittedCount == 1)
}

@Test func remindersInvalidClockDoesNotConsumeAnEpisodeBeforeAnyPost() async {
    let fixture = ReminderFixture(); await fixture.baseline()
    let snapshot = reminderSnapshot(.needsInput)
    fixture.clock.set(Date(timeIntervalSince1970: .nan))
    await fixture.submit(snapshot, 2); await fixture.coordinator.flush()
    let failed = await fixture.coordinator.current()
    #expect(failed.problem == .invalidClock)
    fixture.clock.set(reminderEpoch)
    await fixture.submit(snapshot, 3); await fixture.coordinator.flush()
    let posted = await fixture.client.posted
    #expect(posted.count == 1)
}

private func reminderSnapshot(_ phase: AgentPhase?, id: String = "session", project: String = "project", at: Date = reminderEpoch,
                              projectedAt: Date = reminderEpoch,
                              turn: String? = nil, read: Bool = false, ignored: Bool = false, selected: Bool = false,
                              issue: SessionSourceIssue? = nil, location: WaveLocation? = nil) -> SessionSnapshot {
    guard let phase else { return .init(sessions: [], ignoredSessions: [], preferredSessionID: nil, nextTransitionAt: nil) }
    let event = AgentEvent(version: 2, sessionID: id, projectName: project, phase: phase, occurredAt: at, waveLocation: location,
                           context: EventContext(source: .manual, kind: .status, receivedAt: at, turnID: turn, toolName: "fixture-private-tool"))
    var status = SessionStatusPolicy.standard.status(for: AgentSession(event: event, turnID: turn), at: projectedAt).confirming(issue)
    status.attention = SessionAttention(isUnread: status.hasAttentionItem && !read, isIgnored: ignored, isSelected: selected)
    return .init(sessions: ignored ? [] : [status], ignoredSessions: ignored ? [status] : [],
                 preferredSessionID: selected ? id : nil, nextTransitionAt: status.nextTransitionAt)
}

private func reminderLocation() -> WaveLocation {
    .init(blockID: UUID(), tabID: UUID(), waveVersion: "0.14.5", observedAt: reminderEpoch, source: .environment)
}

private func reminderDate(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

private struct ReminderFixture {
    let clock: ReminderClock
    let client: ReminderClient
    let coordinator: SessionReminderCoordinator
    init(client: ReminderClient = ReminderClient()) {
        let clock = ReminderClock()
        self.client = client; self.clock = clock
        coordinator = SessionReminderCoordinator(client: client, now: { clock.read() }, calendar: { reminderCalendar })
    }
    func submit(_ snapshot: SessionSnapshot, _ sequence: UInt64, primary: Bool = true,
                settings: SessionReminderSettings = remindersEnabled, viewing: VerifiedSessionViewing? = nil) async {
        await coordinator.submit(snapshot: snapshot, sequence: sequence, isPrimary: primary, settings: settings, viewing: viewing)
    }
    func baseline(_ snapshot: SessionSnapshot = reminderSnapshot(nil)) async {
        await submit(snapshot, 1); await coordinator.flush()
    }
}

private final class ReminderClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = reminderEpoch
    func read() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}

private enum ReminderTestError: Error { case privateFailure }
private actor ReminderClient: SessionReminderClient {
    var posted: [SessionReminder] = []
    var authorizationCalls = 0
    var postCalls = 0
    var maximumOperations = 0
    private var operations = 0
    private var enabled: SessionReminderAuthorization
    private var loseResponse: Bool
    private let authorizationGate: ReminderGate?
    private let postGate: ReminderGate?
    init(authorization: SessionReminderAuthorization = .allowed, authorizationGate: ReminderGate? = nil,
         postGate: ReminderGate? = nil, loseResponse: Bool = false) {
        enabled = authorization; self.authorizationGate = authorizationGate; self.postGate = postGate; self.loseResponse = loseResponse
    }
    func setAuthorization(_ value: SessionReminderAuthorization) { enabled = value }
    func authorization() async -> SessionReminderAuthorization {
        authorizationCalls += 1; operations += 1; maximumOperations = max(operations, maximumOperations)
        defer { operations -= 1 }
        await authorizationGate?.hold(); return enabled
    }
    func post(_ reminder: SessionReminder) async throws {
        postCalls += 1; operations += 1; maximumOperations = max(operations, maximumOperations)
        defer { operations -= 1 }
        await postGate?.hold(); posted.append(reminder)
        if loseResponse { loseResponse = false; throw ReminderTestError.privateFailure }
    }
}

private actor ReminderGate {
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

private func reminderEntered(_ entries: AsyncStream<Void>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in entries { return }; throw CancellationError() }
        group.addTask { try await Task.sleep(for: .seconds(15)); throw ReminderTestError.privateFailure }
        defer { group.cancelAll() }; _ = try await group.next()
    }
}
private func reminderStopped(_ frames: AsyncStream<SessionReminderDelivery>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await frame in frames { if frame.stopped { return } }; throw CancellationError() }
        group.addTask { try await Task.sleep(for: .seconds(15)); throw ReminderTestError.privateFailure }
        defer { group.cancelAll() }; _ = try await group.next()
    }
}
