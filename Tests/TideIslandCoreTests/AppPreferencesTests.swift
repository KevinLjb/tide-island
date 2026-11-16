import Foundation
import Testing
@testable import TideIslandCore

private let preferenceEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func preferencesDefaultToSilentOptInRemindersAndOneDayDisplay() {
    let preferences = AppPreferences()
    #expect(!preferences.reminders.enabled && !preferences.reminders.sound && !preferences.launchAtLogin)
    #expect(preferences.reminders.showsProjectName && preferences.reminders.quietHours == nil && preferences.historyVisibility == .oneDay)
}

@Test func preferencesRoundTripEveryExplicitChoice() throws {
    let quiet = try SessionQuietHours(startMinute: 22 * 60, endMinute: 8 * 60)
    let value = AppPreferences(reminders: .init(enabled: true, needsInput: false, turnEnded: true, sound: true,
                                              showsProjectName: false, quietHours: quiet), historyVisibility: .sixHours, launchAtLogin: true)
    let data = try AppPreferencesCodec.encode(value)
    let restored = try AppPreferencesCodec.decode(data)
    #expect(restored == value && data.count < AppPreferencesCodec.maximumBytes)
}

@Test func preferencesFutureVersionPreservesBytesAndBlocksOrdinaryWrites() throws {
    let bytes = Data("{\"kind\":\"tide-island-preferences\",\"version\":99}".utf8)
    var document = AppPreferenceDocument(data: bytes)
    #expect(document.problem == .unsupportedVersion && !document.preferences.reminders.enabled)
    #expect(!document.preferences.reminders.showsProjectName)
    let before = document.preferences
    #expect(throws: AppPreferenceProblem.unsupportedVersion) { try document.updating(AppPreferences()) }
    #expect(document.problem == .unsupportedVersion && document.preferences == before)
}

@Test func preferencesCorruptOrOversizedRecordsFailClosedWithoutAnAutomaticReset() {
    for bytes in [Data(), Data("invalid".utf8), Data(repeating: 0x20, count: AppPreferencesCodec.maximumBytes + 1)] {
        var document = AppPreferenceDocument(data: bytes)
        #expect(document.problem != nil && !document.preferences.reminders.enabled && !document.preferences.reminders.showsProjectName)
        #expect(throws: (any Error).self) { try document.updating(AppPreferences()) }
    }
}

@Test func preferencesRejectUnsupportedHistoryAndInvalidQuietHoursInsideTheEnvelope() throws {
    let original = try AppPreferencesCodec.encode(AppPreferences())
    let object = try JSONSerialization.jsonObject(with: original)
    let envelope = try #require(object as? [String: Any])
    let preferences = try #require(envelope["preferences"] as? [String: Any])
    for choice in 0..<2 {
        var changed = preferences
        if choice == 0 { changed["historyVisibility"] = 123 }
        else {
            var reminders = try #require(changed["reminders"] as? [String: Any])
            reminders["quietHours"] = ["startMinute": 120, "endMinute": 120]
            changed["reminders"] = reminders
        }
        var fields = envelope; fields["preferences"] = changed
        let bytes = try JSONSerialization.data(withJSONObject: fields)
        #expect(throws: AppPreferenceProblem.invalidData) { try AppPreferencesCodec.decode(bytes) }
    }
}

@Test func preferencesExplicitResetUnlocksTheDocumentAndPreservesCallerStartupIntent() throws {
    var document = AppPreferenceDocument(data: Data("broken".utf8))
    let reset = AppPreferences(launchAtLogin: true)
    let data = try document.resetting(to: reset)
    let decoded = try AppPreferencesCodec.decode(data)
    #expect(document.problem == nil && decoded == reset && decoded.launchAtLogin)
    var changed = reset; changed.reminders.sound = true
    let saved = try document.updating(changed)
    let restored = try AppPreferencesCodec.decode(saved)
    #expect(restored.reminders.sound && !restored.reminders.enabled)
}

@Test func preferencesMissingRecordIsWritableWithDefaults() throws {
    var document = AppPreferenceDocument(data: nil)
    var value = document.preferences; value.historyVisibility = .oneHour
    let data = try document.updating(value)
    let restored = try AppPreferencesCodec.decode(data)
    #expect(document.problem == nil && restored.historyVisibility == .oneHour)
}

@Test func preferencesHistoryVisibilityShortensOnlyResolvedDisplayAndKeepsOriginalState() {
    let statuses = [preferenceStatus(.completed), preferenceStatus(.failed), preferenceStatus(.interrupted),
                    preferenceStatus(.working), preferenceStatus(.needsInput)]
    let preferences = AppPreferences(historyVisibility: .oneHour)
    let at = preferenceEpoch.addingTimeInterval(3600)
    let visible = preferences.visibleStatuses(statuses, at: at)
    #expect(visible.map(\.session.phase) == [.working, .needsInput])
    #expect(statuses.count == 5 && statuses.allSatisfy { $0.session.updatedAt == preferenceEpoch })
}

@Test func preferencesHistoryBoundariesAreExclusiveAndCannotExtendSourceExpiry() {
    for visibility in HistoryVisibility.allCases {
        let preferences = AppPreferences(historyVisibility: visibility)
        let at = preferenceEpoch.addingTimeInterval(Double(visibility.rawValue))
        let status = preferenceStatus(.completed, projectedAt: at)
        #expect(preferences.visibleStatuses([status], at: at.addingTimeInterval(-1)).count == (visibility == .oneDay ? 0 : 1))
        #expect(preferences.visibleStatuses([status], at: at).isEmpty)
    }
    let ended = preferenceStatus(.ended, projectedAt: preferenceEpoch.addingTimeInterval(3600))
    #expect(AppPreferences().visibleStatuses([ended], at: preferenceEpoch.addingTimeInterval(3600)).isEmpty)
}

@Test func preferencesLongerDisplayNeverMakesAnUnconfirmedSessionFresh() {
    let at = preferenceEpoch.addingTimeInterval(301)
    let status = preferenceStatus(.working, projectedAt: at)
    let visible = AppPreferences().visibleStatuses([status], at: at)
    #expect(visible.count == 1 && visible.first?.activity == .unknown && visible.first?.isLiveActivity == false)
    #expect(visible.first?.session.updatedAt == preferenceEpoch)
}

@Test func preferencesInvalidDisplayClockDoesNotDeleteTheSourceRecord() {
    let status = preferenceStatus(.completed)
    #expect(AppPreferences().visibleStatuses([status], at: Date(timeIntervalSince1970: .nan)).isEmpty)
    #expect(AppPreferences().visibleStatuses([status], at: preferenceEpoch).count == 1)
}

@Test func preferencesHiddenDisplayNameDoesNotChangeTheSourceOrReference() {
    let status = preferenceStatus(.working)
    let preferences = AppPreferences(reminders: .init(showsProjectName: false))
    #expect(preferences.projectName(for: status) == "开发会话" && status.session.projectName == "private-project")
    #expect(status.reference.sessionID == "session" && status.session.updatedAt == preferenceEpoch)
}

@Test func preferencesActivityProjectionHidesNamesAndPreservesDeadlineCountsAndTarget() throws {
    let snapshot = preferenceSnapshot(.working)
    let normalResult = try IslandActivityPresentationPolicy.standard.presentation(for: snapshot, at: preferenceEpoch)
    let hiddenResult = try IslandActivityPresentationPolicy.standard.presentation(for: snapshot, at: preferenceEpoch, showsProjectName: false)
    let normal = try #require(normalResult), hidden = try #require(hiddenResult)
    let bytes = try EventCodec.jsonEncoder().encode(hidden.state)
    #expect(hidden.state.projectName == "开发会话" && !String(decoding: bytes, as: UTF8.self).contains("private-project"))
    #expect(hidden.sessionURL == normal.sessionURL && hidden.staleAt == normal.staleAt && hidden.state.updatedAt == normal.state.updatedAt)
    #expect(hidden.state.workingCount == normal.state.workingCount && snapshot.sessions[0].session.projectName == "private-project")
}

@Test func preferencesHidingNamesCannotConcealInvalidSourceMetadata() throws {
    let snapshot = preferenceSnapshot(.working, project: "invalid\nproject")
    #expect(throws: IslandActivityError.invalidContent) {
        try IslandActivityPresentationPolicy.standard.presentation(for: snapshot, at: preferenceEpoch, showsProjectName: false)
    }
}

@Test func preferencesActivityClientReceivesTheHiddenPayload() async throws {
    let client = PreferenceActivityClient(), controller = IslandActivityController(client: client, now: { preferenceEpoch })
    try await controller.update(snapshot: preferenceSnapshot(.working), showsProjectName: false)
    let contents = await client.contents
    #expect(contents.map(\.state.projectName) == ["开发会话"])
}

@Test func preferencesSchedulerOrdersNameVisibilityAndRejectsLateOptions() async {
    let client = PreferenceActivityClient(), scheduler = IslandActivityScheduler(client: client, now: { preferenceEpoch })
    let snapshot = preferenceSnapshot(.working)
    await scheduler.submit(snapshot: snapshot, sequence: 1); await scheduler.flush()
    await scheduler.submit(snapshot: snapshot, sequence: 2, showsProjectName: false); await scheduler.flush()
    let stale = await scheduler.submit(snapshot: snapshot, sequence: 1, showsProjectName: true)
    await scheduler.submit(snapshot: snapshot, sequence: 3, showsProjectName: false); await scheduler.flush()
    let contents = await client.contents
    #expect(!stale && contents.map(\.state.projectName) == ["private-project", "开发会话"])
}

@Test func preferencesHiddenProjectMetadataChangesStillDeduplicateTheActualPayload() async {
    let client = PreferenceActivityClient(), scheduler = IslandActivityScheduler(client: client, now: { preferenceEpoch })
    await scheduler.submit(snapshot: preferenceSnapshot(.working), sequence: 1, showsProjectName: false); await scheduler.flush()
    await scheduler.submit(snapshot: preferenceSnapshot(.working, project: "different-private-project"), sequence: 2, showsProjectName: false)
    await scheduler.flush()
    let contents = await client.contents
    #expect(contents.count == 1 && contents.first?.state.projectName == "开发会话")
}

@Test func preferencesVisibilityChangesDoNotResurrectASystemDismissedObservation() async throws {
    let client = PreferenceActivityClient(inventory: true)
    let controller = IslandActivityController(client: client, now: { preferenceEpoch.addingTimeInterval(2) })
    let snapshot = preferenceSnapshot(.working)
    try await controller.update(snapshot: snapshot)
    await client.dismiss()
    try await controller.update(snapshot: snapshot, showsProjectName: false)
    try await controller.update(snapshot: snapshot, showsProjectName: true)
    let requests = await client.requests
    #expect(requests == 1)
    try await controller.update(snapshot: preferenceSnapshot(.working, at: preferenceEpoch.addingTimeInterval(1)), showsProjectName: false)
    let resumed = await client.requests, contents = await client.contents
    #expect(resumed == 2 && contents.last?.state.projectName == "开发会话")
}

@Test func preferencesReminderPayloadHidesTheNameWithoutChangingTheSourceLink() async {
    let client = PreferenceReminderClient(), coordinator = SessionReminderCoordinator(client: client, now: { preferenceEpoch })
    await coordinator.submit(snapshot: preferenceSnapshot(nil), sequence: 1, isPrimary: true)
    await coordinator.flush()
    let snapshot = preferenceSnapshot(.needsInput)
    await coordinator.submit(snapshot: snapshot, sequence: 2, isPrimary: true, settings: .init(enabled: true, showsProjectName: false))
    await coordinator.flush()
    let posted = await client.posted
    let linked = posted.first.flatMap { SessionLink.sessionID(from: $0.sessionURL) }
    #expect(posted.first?.body == "开发会话" && posted.first?.reference == snapshot.sessions[0].reference)
    #expect(linked == "session" && snapshot.sessions[0].session.projectName == "private-project")
}

@Test func preferencesLatestNameVisibilityWinsAfterReminderPermissionAwait() async throws {
    let gate = PreferenceGate(), client = PreferenceReminderClient(gate: gate)
    let coordinator = SessionReminderCoordinator(client: client, now: { preferenceEpoch })
    await coordinator.submit(snapshot: preferenceSnapshot(nil), sequence: 1, isPrimary: true)
    await coordinator.flush()
    let snapshot = preferenceSnapshot(.needsInput)
    await coordinator.submit(snapshot: snapshot, sequence: 2, isPrimary: true, settings: .init(enabled: true))
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in gate.entries { return }; throw CancellationError() }
        group.addTask { try await Task.sleep(for: .seconds(15)); throw CancellationError() }
        defer { group.cancelAll() }; _ = try await group.next()
    }
    await coordinator.submit(snapshot: snapshot, sequence: 3, isPrimary: true, settings: .init(enabled: true, showsProjectName: false))
    await gate.open(); await coordinator.flush()
    let posted = await client.posted
    #expect(posted.count == 1 && posted.first?.body == "开发会话")
}

private func preferenceStatus(_ phase: AgentPhase, project: String = "private-project", at: Date = preferenceEpoch,
                              projectedAt: Date = preferenceEpoch) -> SessionStatus {
    let event = AgentEvent(version: 2, sessionID: "session", projectName: project, phase: phase, occurredAt: at,
                           context: .init(source: .manual, kind: .status, receivedAt: at))
    var status = SessionStatusPolicy.standard.status(for: AgentSession(event: event), at: projectedAt)
    status.attention = SessionAttention(isUnread: status.hasAttentionItem)
    return status
}
private func preferenceSnapshot(_ phase: AgentPhase?, project: String = "private-project", at: Date = preferenceEpoch) -> SessionSnapshot {
    .init(sessions: phase.map { [preferenceStatus($0, project: project, at: at, projectedAt: at)] } ?? [],
          ignoredSessions: [], preferredSessionID: nil, nextTransitionAt: nil)
}

private actor PreferenceActivityClient: IslandActivityClient {
    var contents: [IslandActivityPresentation] = []
    var requests = 0
    private let inventory: Bool
    private var record: IslandActivityRecord?
    init(inventory: Bool = false) { self.inventory = inventory }
    func activities(scope: IslandActivityScope) async throws -> [IslandActivityRecord]? { inventory ? record.map { [$0] } ?? [] : nil }
    func isEnabled() async -> Bool { true }
    func request(_ presentation: IslandActivityPresentation) async throws -> String {
        requests += 1; contents.append(presentation)
        record = .init(identifier: "owned", state: .active, content: presentation.state, staleAt: presentation.staleAt)
        return "owned"
    }
    func update(_ identifier: String, presentation: IslandActivityPresentation) async throws {
        contents.append(presentation)
        record = .init(identifier: identifier, state: .active, content: presentation.state, staleAt: presentation.staleAt)
    }
    func end(_ identifier: String) async throws { record = nil }
    func dismiss() {
        if let record { self.record = .init(identifier: record.identifier, state: .dismissed, content: record.content, staleAt: record.staleAt) }
    }
}
private actor PreferenceReminderClient: SessionReminderClient {
    var posted: [SessionReminder] = []
    private let gate: PreferenceGate?
    init(gate: PreferenceGate? = nil) { self.gate = gate }
    func authorization() async -> SessionReminderAuthorization { await gate?.hold(); return .allowed }
    func post(_ reminder: SessionReminder) async throws { posted.append(reminder) }
}

private actor PreferenceGate {
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
