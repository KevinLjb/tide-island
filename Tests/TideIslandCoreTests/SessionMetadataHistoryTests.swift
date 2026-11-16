import Foundation
import Testing
@testable import TideIslandCore

private let metadataEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func metadataHistoryReturnsNewestRememberedObservationsForOnlyTheSelectedSession() async throws {
    try await withMetadataReceiver { fixture, receiver in
        let events = [metadataEvent(.working), metadataEvent(.needsInput, time: 1), metadataEvent(.completed, time: 2)]
        for event in events { try fixture.inbox.write(event) }
        try fixture.inbox.write(metadataEvent(.working, session: "other", time: 3))
        _ = await receiver.start()
        let reference = try await metadataReference(receiver)
        let history = try await metadataHistory(receiver, reference)
        #expect(history.entries.map(\.id) == events.reversed().map(\.id) && history.availableCount == 3)
        #expect(history.reference == reference && history.entries.first?.isCurrentObservation == true)
    }
}

@Test func metadataHistoryExcludesProjectLocationToolIdentityAndProviderContentFromItsDTO() async throws {
    try await withMetadataReceiver { fixture, receiver in
        let location = WaveLocation(blockID: UUID(), tabID: UUID(), waveVersion: "0.14.5", observedAt: metadataEpoch, source: .environment)
        let event = AgentEvent(version: 2, sessionID: "session", projectName: "fixture-private-project", phase: .working, occurredAt: metadataEpoch,
                               waveLocation: location, context: .init(source: .codexHook, kind: .toolStarted, receivedAt: metadataEpoch,
                                                                     turnID: "fixture-private-turn", toolName: "fixture-private-tool", toolUseID: "fixture-private-use"))
        try fixture.inbox.write(event); _ = await receiver.start()
        let reference = try await metadataReference(receiver), history = try await metadataHistory(receiver, reference)
        let entry = try #require(history.entries.first)
        let bytes = try EventCodec.jsonEncoder().encode(entry)
        let object = try JSONSerialization.jsonObject(with: bytes)
        let fields = try #require(object as? [String: Any])
        #expect(Set(fields.keys) == ["id", "phase", "occurredAt", "source", "kind", "isCurrentObservation"])
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("fixture-private") && !text.contains(location.blockID.uuidString))
        #expect(entry.kindTitle == "工具开始" && entry.sourceTitle == "Codex 生命周期")
    }
}

@Test func metadataHistoryLegacyRecordsDoNotInventAnUnrecordedSource() async throws {
    try await withMetadataReceiver { fixture, receiver in
        let event = metadataEvent(.working)
        try fixture.inbox.write(event); _ = await receiver.start()
        let reference = try await metadataReference(receiver), history = try await metadataHistory(receiver, reference)
        #expect(history.entries.first?.source == nil && history.entries.first?.kind == nil)
        #expect(history.entries.first?.sourceTitle == "未记录来源" && history.entries.first?.kindTitle == "状态观察")
    }
}

@Test func metadataHistoryRejectsAnOldObservationAfterNewEvidence() async throws {
    try await withMetadataReceiver { fixture, receiver in
        try fixture.inbox.write(metadataEvent(.working)); _ = await receiver.start()
        let original = try await metadataReference(receiver)
        await receiver.submit(metadataEvent(.needsInput, time: 1))
        let stale = await receiver.metadataHistory(for: original)
        #expect(metadataProblem(stale) == .staleSelection)
        let current = try await metadataReference(receiver), history = try await metadataHistory(receiver, current)
        #expect(history.entries.count == 2 && history.reference != original)
    }
}

@Test func metadataHistoryQueryKeepsOriginalTimesReadStateAndLastSourceConfirmation() async throws {
    try await withMetadataReceiver { fixture, receiver in
        try fixture.inbox.write(metadataEvent(.needsInput)); _ = await receiver.start()
        let before = await receiver.current(), reference = try await metadataReference(receiver)
        fixture.clock.set(metadataEpoch.addingTimeInterval(120))
        let history = try await metadataHistory(receiver, reference)
        let after = await receiver.current()
        #expect(history.confirmedAt == metadataEpoch.addingTimeInterval(100) && history.entries.first?.occurredAt == metadataEpoch)
        #expect(before.snapshot == after.snapshot && after.snapshot.sessions.first?.attention.isUnread == true)
        #expect(before.health.lastSuccessAt == after.health.lastSuccessAt)
    }
}

@Test func metadataHistoryUsesDefaultAndMaximumLimitsWithoutReturningUnboundedRecords() async throws {
    try await withMetadataReceiver { fixture, receiver in
        for index in 0..<25 { try fixture.inbox.write(metadataEvent(.working, time: Double(index))) }
        _ = await receiver.start()
        let reference = try await metadataReference(receiver)
        let normal = try await metadataHistory(receiver, reference)
        let maximumResult = await receiver.metadataHistory(for: reference, limit: SessionMetadataHistory.maximumResults)
        let maximum = try maximumResult.get()
        #expect(normal.entries.count == 8 && maximum.entries.count == 20 && maximum.availableCount == 25)
        for limit in [0, -1, 21, Int.max] {
            let result = await receiver.metadataHistory(for: reference, limit: limit)
            #expect(metadataProblem(result) == .invalidLimit)
        }
    }
}

@Test func metadataHistoryTimestampTiesKeepTheCurrentObservationAndStableUUIDOrder() async throws {
    try await withMetadataReceiver { fixture, receiver in
        let ids = [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                   UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                   UUID(uuidString: "00000000-0000-0000-0000-000000000003")!]
        for id in ids { try fixture.inbox.write(metadataEvent(.working, id: id)) }
        _ = await receiver.start()
        let reference = try await metadataReference(receiver), history = try await metadataHistory(receiver, reference)
        #expect(reference.eventID == ids[2] && history.entries.map(\.id) == [ids[2], ids[0], ids[1]])
    }
}

@Test func metadataHistoryRememberedRetiredEventsNeverBecomeCurrentState() async throws {
    try await withMetadataReceiver { fixture, receiver in
        let events = [metadataScoped(.turnStarted, .working, turn: "a"),
                      metadataScoped(.turnCompleted, .completed, turn: "a", time: 1),
                      metadataScoped(.turnStarted, .working, turn: "b", time: 2),
                      metadataScoped(.toolFinished, .working, turn: "a", time: 3)]
        for event in events { try fixture.inbox.write(event) }
        _ = await receiver.start()
        let reference = try await metadataReference(receiver), history = try await metadataHistory(receiver, reference)
        #expect(reference.eventID == events[2].id && history.entries.first?.id == events[3].id)
        #expect(history.entries.first?.isCurrentObservation == false && history.entries.filter(\.isCurrentObservation).count == 1)
        let current = await receiver.current()
        #expect(current.snapshot.sessions.first?.session.updatedAt == events[2].occurredAt)
    }
}

@Test func metadataHistoryCheckpointRestoreReusesTheExistingRememberedWindow() async throws {
    try await withMetadataReceiver(persistent: true) { fixture, receiver in
        for index in 0..<4 { try fixture.inbox.write(metadataEvent(.working, time: Double(index))) }
        _ = await receiver.start(); _ = await receiver.stop()
        _ = await receiver.start()
        let reference = try await metadataReference(receiver), history = try await metadataHistory(receiver, reference)
        #expect(history.availableCount == 4 && history.entries.first?.occurredAt == metadataEpoch.addingTimeInterval(3))
        let saved = try SessionStateFile(inbox: fixture.inbox).load()
        #expect(saved.schemaVersion == 2)
    }
}

@Test func metadataHistoryResetDoesNotRevealSuppressedFilesEvenWhenTheSameSessionResumes() async throws {
    try await withMetadataReceiver(persistent: true) { fixture, receiver in
        let originals = [metadataEvent(.working), metadataEvent(.needsInput, time: 1)]
        for event in originals { try fixture.inbox.write(event) }
        _ = await receiver.start()
        let reset = await receiver.previewReset()
        let preview = try #require(reset)
        let applied = await receiver.applyReset(expectedFingerprint: preview.fingerprint)
        #expect(applied)
        let next = metadataEvent(.working, time: 2)
        await receiver.submit(next)
        let reference = try await metadataReference(receiver), history = try await metadataHistory(receiver, reference)
        #expect(history.entries.map(\.id) == [next.id] && history.availableCount == 1)
        for event in originals { #expect(FileManager.default.fileExists(atPath: fixture.inbox.directory.appendingPathComponent(event.id.uuidString + ".json").path)) }
        _ = await receiver.stop(); _ = await receiver.start()
        let restored = try await metadataHistory(receiver, reference)
        #expect(restored.entries.map(\.id) == [next.id])
    }
}

@Test func metadataHistoryMissingCurrentFileCannotBeMaskedByOlderRememberedRecords() async throws {
    try await withMetadataReceiver { fixture, receiver in
        try fixture.inbox.write(metadataEvent(.working))
        let latest = metadataEvent(.needsInput, time: 1)
        let path = try fixture.inbox.write(latest)
        _ = await receiver.start(); let reference = try await metadataReference(receiver)
        try FileManager.default.removeItem(at: path)
        _ = await receiver.reconnect()
        let result = await receiver.metadataHistory(for: reference)
        #expect(metadataProblem(result) == .sourceUnavailable)
    }
}

@Test func metadataHistoryStoppedOrInvalidClockQueriesCannotRefreshSourceEvidence() async throws {
    try await withMetadataReceiver { fixture, receiver in
        let event = metadataEvent(.working), reference = SessionReference(sessionID: "session", eventID: UUID())
        let before = await receiver.metadataHistory(for: reference)
        #expect(metadataProblem(before) == .sourceUnavailable)
        try fixture.inbox.write(event); _ = await receiver.start()
        let current = try await metadataReference(receiver)
        fixture.clock.set(Date(timeIntervalSince1970: .nan))
        let invalid = await receiver.metadataHistory(for: current)
        #expect(metadataProblem(invalid) == .invalidClock)
        fixture.clock.set(metadataEpoch.addingTimeInterval(100))
        _ = await receiver.stop()
        let stopped = await receiver.metadataHistory(for: current)
        #expect(metadataProblem(stopped) == .sourceUnavailable)
    }
}

@Test func metadataHistoryCanInspectIgnoredStateWithoutRestoringOrReadingIt() async throws {
    try await withMetadataReceiver { fixture, receiver in
        try fixture.inbox.write(metadataEvent(.needsInput)); _ = await receiver.start()
        let reference = try await metadataReference(receiver)
        let ignored = await receiver.perform(.ignore, for: reference)
        #expect(ignored)
        let history = try await metadataHistory(receiver, reference), current = await receiver.current()
        #expect(history.entries.count == 1 && current.snapshot.sessions.isEmpty && current.snapshot.ignoredSessions.count == 1)
        #expect(current.snapshot.ignoredSessions.first?.attention.isIgnored == true && current.snapshot.ignoredSessions.first?.attention.isUnread == true)
    }
}

@Test func metadataHistoryUnavailableChannelAndExpiredRowsReturnExplicitProblems() async throws {
    try await withMetadataReceiver { fixture, receiver in
        try fixture.inbox.write(metadataEvent(.completed)); _ = await receiver.start()
        let reference = try await metadataReference(receiver)
        fixture.clock.set(metadataEpoch.addingTimeInterval(24 * 3600))
        let expired = await receiver.metadataHistory(for: reference)
        #expect(metadataProblem(expired) == .staleSelection)
        fixture.clock.set(metadataEpoch.addingTimeInterval(100))
        let bad = fixture.inbox.directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("invalid".utf8).write(to: bad)
        _ = await receiver.reconnect()
        let unavailable = await receiver.metadataHistory(for: reference)
        #expect(metadataProblem(unavailable) == .sourceUnavailable)
    }
}

@Test func metadataMembershipKeepsTheCurrentAnchorWithoutExtendingTheDedupWindow() throws {
    var registry = SessionRegistry()
    let current = metadataEvent(.completed)
    try registry.apply(current)
    for index in 1...(SessionRegistry.eventHistoryLimit + 10) { try registry.apply(metadataEvent(.working, time: -Double(index))) }
    let reference = SessionReference(sessionID: "session", eventID: current.id)
    let remembered = try #require(registry.metadataEventIDs(for: reference))
    #expect(remembered.count == SessionRegistry.eventHistoryLimit + 1 && remembered.contains(current.id))
    let decision = try registry.applyResult(current)
    #expect(decision == .timestampTie)
}

private func metadataEvent(_ phase: AgentPhase, session: String = "session", time: TimeInterval = 0, id: UUID = UUID()) -> AgentEvent {
    .init(id: id, sessionID: session, projectName: "project", phase: phase, occurredAt: metadataEpoch.addingTimeInterval(time))
}
private func metadataScoped(_ kind: EventKind, _ phase: AgentPhase, turn: String, time: TimeInterval = 0) -> AgentEvent {
    let at = metadataEpoch.addingTimeInterval(time)
    return .init(version: 2, sessionID: "session", projectName: "project", phase: phase, occurredAt: at,
                 context: .init(source: kind == .turnCompleted ? .codexNotify : .codexHook, kind: kind, receivedAt: at,
                                turnID: turn, toolName: kind == .toolFinished ? "fixture-tool" : nil,
                                toolUseID: kind == .toolFinished ? "fixture-use" : nil))
}
private func metadataReference(_ receiver: InboxReceiver, sessionID: String = "session") async throws -> SessionReference {
    let frame = await receiver.current()
    let status = try #require((frame.snapshot.sessions + frame.snapshot.ignoredSessions).first { $0.id == sessionID })
    return status.reference
}
private func metadataHistory(_ receiver: InboxReceiver, _ reference: SessionReference) async throws -> SessionMetadataHistory {
    let result = await receiver.metadataHistory(for: reference)
    return try result.get()
}
private func metadataProblem(_ result: Result<SessionMetadataHistory, SessionMetadataProblem>) -> SessionMetadataProblem? {
    if case .failure(let problem) = result { return problem }; return nil
}
private struct MetadataFixture: Sendable {
    let root: URL
    let inbox: EventInbox
    let clock = MetadataClock()
    init() throws {
        let temporary = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        root = temporary.appendingPathComponent(UUID().uuidString)
        inbox = EventInbox(directory: root.appendingPathComponent("Events"))
        try inbox.prepare()
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private final class MetadataClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = metadataEpoch.addingTimeInterval(100)
    func read() -> Date { lock.withLock { date } }
    func set(_ value: Date) { lock.withLock { date = value } }
}
private func withMetadataReceiver(persistent: Bool = false,
                                  _ body: (MetadataFixture, InboxReceiver) async throws -> Void) async throws {
    let fixture = try MetadataFixture()
    let receiver = InboxReceiver(inbox: fixture.inbox, persistence: persistent ? SessionStateFile(inbox: fixture.inbox) : nil,
                                 now: { fixture.clock.read() })
    defer { fixture.remove() }
    do { try await body(fixture, receiver) } catch { _ = await receiver.stop(); throw error }
    _ = await receiver.stop()
}
