import Darwin
import Dispatch
import Foundation
import Testing
@testable import TideIslandCore

private let recoveryEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func channelConfirmationPreservesObservationAndAttentionWithoutLiveCounts() throws {
    let event = recoveryEvent(.needsInput)
    var store = SessionStore()
    try store.receive([event])
    let reference = SessionReference(sessionID: event.sessionID, eventID: event.id)
    let pinned = store.perform(.pin, for: reference, at: recoveryEpoch)
    #expect(pinned)
    let disconnected = store.snapshot(at: recoveryEpoch, sourceIssue: .channelUnavailable)
    #expect(disconnected.waitingCount == 0 && disconnected.unknownCount == 1 && disconnected.activitySession == nil)
    #expect(disconnected.sessions[0].session.updatedAt == event.occurredAt && disconnected.sessions[0].attention.isPinned)
    let empty = store.snapshot(at: recoveryEpoch, confirmedEvents: [:])
    #expect(empty.sessions[0].sourceIssue == .eventMissing && empty.waitingCount == 0)
    let confirmed = store.snapshot(at: recoveryEpoch, confirmedEvents: [event.id: event])
    #expect(confirmed.waitingCount == 1 && confirmed.sessions[0].attention.isPinned)
}

@Test func sameUUIDWithEditedContentsCannotConfirmAnOldInMemoryObservation() throws {
    let event = recoveryEvent(.working)
    var store = SessionStore()
    try store.receive([event])
    let changed = recoveryEvent(.completed, id: event.id)
    try store.receive([changed]) // Registry correctly refuses a repeated UUID.
    let frame = store.snapshot(at: recoveryEpoch, confirmedEvents: [changed.id: changed])
    #expect(frame.workingCount == 0 && frame.unknownCount == 1)
    #expect(frame.sessions[0].session.phase == .working && frame.sessions[0].sourceIssue == .eventMissing)
}

@Test func realDirectoryRenameAndReplacementRearmsTheWatcher() async throws {
    try await withRecoveryReceiver { fixture, receiver in
        let old = recoveryEvent(.working, session: "old")
        try fixture.inbox.write(old)
        let first = await receiver.start()
        #expect(first.snapshot.workingCount == 1)
        let moved = fixture.root.appendingPathComponent("retired")
        try FileManager.default.moveItem(at: fixture.inbox.directory, to: moved)
        let new = recoveryEvent(.needsInput, session: "new")
        try fixture.inbox.write(new)
        let recovered = try await waitForRecovery(receiver) {
            $0.health.state == .healthy && $0.snapshot.waitingCount == 1 && $0.snapshot.unknownCount == 1
        }
        #expect(recovered.snapshot.sessions.first { $0.id == "old" }?.session.updatedAt == old.occurredAt)
        let next = recoveryEvent(.working, session: "after-rearm")
        try fixture.inbox.write(next)
        let watched = try await waitForRecovery(receiver) { $0.snapshot.workingCount == 1 && $0.snapshot.waitingCount == 1 }
        #expect(watched.snapshot.sessions.contains { $0.id == next.sessionID })
    }
}

@Test func deletedInboxRecoversEmptyWithoutResurrectingOldWork() async throws {
    try await withRecoveryReceiver { fixture, receiver in
        let old = recoveryEvent(.working)
        try fixture.inbox.write(old)
        _ = await receiver.start()
        try FileManager.default.removeItem(at: fixture.inbox.directory)
        let empty = try await waitForRecovery(receiver) {
            $0.health.state == .healthy && $0.snapshot.sessions.first?.sourceIssue == .eventMissing
        }
        #expect(empty.snapshot.workingCount == 0 && empty.snapshot.sessions[0].session.updatedAt == old.occurredAt)
        let new = recoveryEvent(.needsInput, time: 1)
        try fixture.inbox.write(new)
        // Clock remains before this event; a repaired channel cannot defeat
        // the independent future-clock guard.
        let future = try await waitForRecovery(receiver) { $0.snapshot.sessions.first?.session.lastEventID == new.id }
        #expect(future.snapshot.waitingCount == 0 && future.snapshot.sessions[0].freshness == .clockSkew)
    }
}

@Test func receiverLeaseSurvivesInboxReplacementAndReleasesOnStop() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let first = InboxReceiver(inbox: fixture.inbox, now: { recoveryEpoch })
    let second = InboxReceiver(inbox: fixture.inbox, now: { recoveryEpoch })
    _ = await first.start()
    let repeated = await first.start()
    #expect(repeated.health.state == .healthy)
    try FileManager.default.removeItem(at: fixture.inbox.directory)
    try fixture.inbox.prepare()
    let denied = await second.start()
    #expect(denied.health.problem == .receiverInUse && !denied.health.willRetry)
    _ = await first.stop()
    let acquired = await second.reconnect()
    #expect(acquired.health.state == .healthy)
    _ = await second.stop()
    let locks = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "lock" }
    #expect(locks.count == 1)
    let lock = try #require(locks.first)
    let lockBytes = try Data(contentsOf: lock)
    #expect(lockBytes.isEmpty)
}

@Test func staleWatcherCallbacksCannotInvalidateARearmedOrStoppedReceiver() async throws {
    try await withRecoveryReceiver { _, receiver in
        _ = await receiver.start()
        let oldGeneration = await receiver.directoryGeneration
        _ = await receiver.reconnect()
        await receiver.monitorChanged(flags: DispatchSource.FileSystemEvent.delete.rawValue,
                                      generation: oldGeneration, parent: false)
        let active = await receiver.current()
        #expect(active.health.state == .healthy)
        _ = await receiver.stop()
        await receiver.monitorChanged(flags: DispatchSource.FileSystemEvent.write.rawValue,
                                      generation: oldGeneration, parent: false)
        let stopped = await receiver.current()
        #expect(stopped.health.state == .stopped)
    }
}

@Test func unsafeDirectoryReplacementSuppressesCountsAndRecoversAfterRepair() async throws {
    try await withRecoveryReceiver { fixture, receiver in
        let event = recoveryEvent(.working)
        try fixture.inbox.write(event)
        _ = await receiver.start()
        let original = fixture.root.appendingPathComponent("original")
        let provider = fixture.root.appendingPathComponent("provider")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: false)
        let secret = provider.appendingPathComponent("chat.jsonl")
        try Data("private-provider-chat".utf8).write(to: secret)
        try FileManager.default.moveItem(at: fixture.inbox.directory, to: original)
        try FileManager.default.createSymbolicLink(at: fixture.inbox.directory, withDestinationURL: provider)
        let unavailable = await receiver.reconnect()
        #expect(unavailable.health.state != .healthy && unavailable.snapshot.workingCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: provider.path) == ["chat.jsonl"])
        try FileManager.default.removeItem(at: fixture.inbox.directory)
        try FileManager.default.moveItem(at: original, to: fixture.inbox.directory)
        let repaired = try await waitForRecovery(receiver) { $0.health.state == .healthy && $0.snapshot.workingCount == 1 }
        #expect(repaired.snapshot.sessions[0].session.updatedAt == event.occurredAt)
        #expect(try Data(contentsOf: secret) == Data("private-provider-chat".utf8))
    }
}

@Test func busyReadsStopAfterFiveRetriesAndExplicitReconnectRecovers() async throws {
    try await withRecoveryReceiver { fixture, receiver in
        try fixture.inbox.write(recoveryEvent(.working))
        _ = await receiver.start()
        let fd = open(fixture.inbox.directory.appendingPathComponent(InboxDirectory.markerName).path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let busy = await receiver.reconnect()
        #expect(busy.health.problem == .busy && busy.health.willRetry && busy.snapshot.workingCount == 0)
        let exhausted = try await waitForRecovery(receiver, attempts: 400) {
            $0.health.problem == .busy && $0.health.retryAttempt == 5 && !$0.health.willRetry
        }
        #expect(exhausted.health.state == .unavailable && exhausted.snapshot.unknownCount == 1)
        #expect(flock(fd, LOCK_UN) == 0)
        let repaired = await receiver.reconnect()
        #expect(repaired.health.state == .healthy && repaired.snapshot.workingCount == 1)
    }
}

@Test func malformedUnsupportedOversizedAndMismatchedEventsAreDiagnosedAndPreserved() async throws {
    try await withRecoveryReceiver { fixture, receiver in
        let valid = recoveryEvent(.working)
        try fixture.inbox.write(valid)
        _ = await receiver.start()
        let unknown: [String: Any] = ["version": 999, "future-shape": "not-a-v2-event"]
        let bodies = [Data("private-malformed".utf8), try JSONSerialization.data(withJSONObject: unknown),
                      Data(repeating: 0x20, count: EventCodec.maximumBytes + 1), try EventCodec.encode(valid)]
        let paths = try bodies.map { data -> URL in
            let path = fixture.eventPath()
            try data.write(to: path)
            return path
        }
        let damaged = await receiver.reconnect()
        #expect(damaged.health.state == .degraded && damaged.snapshot.workingCount == 0)
        #expect(damaged.health.rejectionCounts == [.malformed: 1, .unsupportedVersion: 1, .oversized: 1, .filenameMismatch: 1])
        #expect(damaged.health.message?.contains("private-") == false)
        for (path, bytes) in zip(paths, bodies) {
            #expect(try Data(contentsOf: path) == bytes)
            try FileManager.default.removeItem(at: path)
        }
        let repaired = await receiver.reconnect()
        #expect(repaired.health.state == .healthy && repaired.health.message == nil && repaired.snapshot.workingCount == 1)
        #expect(repaired.snapshot.sessions[0].session.updatedAt == valid.occurredAt)
    }
}

@Test func receiverReadLimitFailureDoesNotImportPartialBatches() async throws {
    let limits = try InboxReadLimits(maximumFiles: 1, maximumReadBytes: 16384)
    try await withRecoveryReceiver(limits: limits) { fixture, receiver in
        try fixture.inbox.write(recoveryEvent(.working, session: "old"))
        _ = await receiver.start()
        let path = try fixture.inbox.write(recoveryEvent(.needsInput, session: "new"))
        let failed = await receiver.reconnect()
        #expect(failed.health.problem == .readLimitExceeded && !failed.health.willRetry)
        #expect(failed.snapshot.sessions.count == 1 && failed.snapshot.workingCount == 0)
        try FileManager.default.removeItem(at: path)
        let repaired = await receiver.reconnect()
        #expect(repaired.health.state == .healthy && repaired.snapshot.workingCount == 1)
    }
}

@Test func removedOrEditedCurrentEventStaysUnconfirmedUntilNewEvidenceArrives() async throws {
    try await withRecoveryReceiver { fixture, receiver in
        let original = recoveryEvent(.working)
        let path = try fixture.inbox.write(original)
        _ = await receiver.start()
        try FileManager.default.removeItem(at: path)
        let removed = await receiver.reconnect()
        #expect(removed.health.state == .healthy && removed.snapshot.workingCount == 0)
        try EventCodec.encode(recoveryEvent(.completed, id: original.id)).write(to: path)
        let edited = await receiver.reconnect()
        #expect(edited.snapshot.workingCount == 0 && edited.snapshot.sessions[0].sourceIssue == .eventMissing)
        try fixture.inbox.write(recoveryEvent(.needsInput))
        let latest = try await waitForRecovery(receiver) { $0.snapshot.waitingCount == 1 }
        #expect(latest.snapshot.sessions[0].sourceIssue == nil)
    }
}

@Test func sharedReceiverExpiresLiveCountsWithoutAnotherFilesystemEvent() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let receiver = InboxReceiver(inbox: fixture.inbox)
    let at = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 298)
    let event = AgentEvent(sessionID: "timer", projectName: "project", phase: .working, occurredAt: at)
    try fixture.inbox.write(event)
    let first = await receiver.start()
    #expect(first.snapshot.workingCount == 1)
    // Consume emitted frames: polling current() would recompute time and hide
    // a missing timer, while the native app relies on a real stream update.
    let expired = try await waitForRecoveryStream(receiver.frames) { $0.snapshot.unknownCount == 1 }
    #expect(expired.health.state == .healthy && expired.snapshot.workingCount == 0)
    #expect(expired.snapshot.sessions[0].session.updatedAt == at)
    _ = await receiver.stop()
}

@Test func completeOrphanStageIsPreviewedWithoutMutationAndPublishedWithOriginalIdentity() throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let event = recoveryEvent(.needsInput)
    let data = try EventCodec.encode(event)
    let stage = try fixture.stage(data)
    let preview = try fixture.inbox.inspectRecovery()
    #expect(preview.interruptedStages == 1 && preview.issues.isEmpty && preview.recoveredEvents == 0)
    #expect(try Data(contentsOf: stage) == data)
    var cursor = InboxCursor()
    let before = try fixture.inbox.readIncrementally(using: &cursor)
    #expect(before.events.isEmpty)
    let recovered = try fixture.inbox.recoverInterruptedOperations()
    #expect(recovered.recoveredEvents == 1 && recovered.removedStages == 1 && recovered.issues.isEmpty)
    let after = try fixture.inbox.readIncrementally(using: &cursor)
    #expect(after.events == [event] && !FileManager.default.fileExists(atPath: stage.path))
    let repeated = try fixture.inbox.recoverInterruptedOperations()
    #expect(repeated.recoveredEvents == 0 && repeated.interruptedStages == 0)
}

@Test func crashAfterEventLinkRemovesOnlyRedundantStageAndRestoresSingleLink() throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let event = recoveryEvent(.working)
    let bytes = try EventCodec.encode(event)
    let stage = try fixture.stage(bytes)
    let final = fixture.inbox.directory.appendingPathComponent(event.id.uuidString + ".json")
    try FileManager.default.linkItem(at: stage, to: final)
    var cursor = InboxCursor()
    let before = try fixture.inbox.readIncrementally(using: &cursor)
    #expect(before.skippedFiles == 1 && before.events.isEmpty)
    let recovered = try fixture.inbox.recoverInterruptedOperations()
    #expect(recovered.removedStages == 1 && recovered.recoveredEvents == 0 && recovered.issues.isEmpty)
    let after = try fixture.inbox.readIncrementally(using: &cursor)
    #expect(after.events == [event] && after.skippedFiles == 0)
    #expect(try Data(contentsOf: final) == bytes)
}

@Test func partialConflictingAndUnsafeStagesArePreservedWithoutReadingProviderData() throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let event = recoveryEvent(.working)
    let final = try fixture.inbox.write(event)
    let original = try Data(contentsOf: final)
    let same = try fixture.stage(original)
    let conflict = try fixture.stage(EventCodec.encode(recoveryEvent(.completed, id: event.id)))
    let partial = try fixture.stage(Data("private-partial".utf8))
    let external = fixture.root.appendingPathComponent("transcript.jsonl")
    try Data("private-chat".utf8).write(to: external)
    let link = fixture.stagePath()
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    let report = try fixture.inbox.recoverInterruptedOperations()
    #expect(report.removedStages == 1 && !FileManager.default.fileExists(atPath: same.path))
    #expect(Set(report.issues.map(\.reason)) == [.conflictingEvent, .invalidStagingEvent, .unsafeStagingFile])
    #expect(try Data(contentsOf: final) == original)
    #expect(FileManager.default.fileExists(atPath: conflict.path) && FileManager.default.fileExists(atPath: partial.path))
    #expect(try Data(contentsOf: external) == Data("private-chat".utf8))
    #expect(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private-") == false)
}

@Test func recoveryReadBudgetFailurePreservesStageAndCursor() throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let stage = try fixture.stage(EventCodec.encode(recoveryEvent(.working)))
    let limits = try InboxReadLimits(maximumFiles: 10, maximumReadBytes: 1)
    #expect(throws: InboxError.limitExceeded) { try fixture.inbox.recoverInterruptedOperations(limits: limits) }
    #expect(FileManager.default.fileExists(atPath: stage.path))
}

@Test func interruptedApprovedCleanupBlocksPartialHistoryThenResumesIdempotently() throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let old = [recoveryEvent(.working, session: "expired", time: -10 * 86400 - 1),
               recoveryEvent(.completed, session: "expired", time: -10 * 86400)]
    for event in old { try fixture.inbox.write(event) }
    let live = recoveryEvent(.working, session: "live")
    let protected = try fixture.inbox.write(live)
    let plan = try fixture.authorizeCleanup()
    #expect(plan.removals.count == 2)
    try FileManager.default.removeItem(at: fixture.inbox.directory.appendingPathComponent(plan.removals[0].fileName))
    var cursor = InboxCursor()
    #expect(throws: InboxError.recoveryRequired) { try fixture.inbox.readIncrementally(using: &cursor) }
    #expect(cursor.files.isEmpty)
    let preview = try fixture.inbox.inspectRecovery()
    #expect(preview.pendingCleanupFiles == 1 && preview.resumedCleanupFiles == 0)
    let recovered = try fixture.inbox.recoverInterruptedOperations()
    #expect(recovered.resumedCleanupFiles == 1 && recovered.issues.isEmpty)
    let after = try fixture.inbox.readIncrementally(using: &cursor)
    #expect(after.events == [live] && FileManager.default.fileExists(atPath: protected.path))
    let repeated = try fixture.inbox.recoverInterruptedOperations()
    #expect(repeated.pendingCleanupFiles == 0 && repeated.resumedCleanupFiles == 0)
}

@Test func cleanupRecoveryRefusesChangedEntriesAndOnlyContinuesAfterConflictIsRemoved() async throws {
    try await withRecoveryReceiver { fixture, receiver in
        try fixture.inbox.write(recoveryEvent(.completed, session: "old-a", time: -10 * 86400))
        try fixture.inbox.write(recoveryEvent(.completed, session: "old-b", time: -10 * 86400))
        try fixture.inbox.write(recoveryEvent(.working, session: "live"))
        _ = await receiver.start()
        _ = await receiver.stop()
        let plan = try fixture.authorizeCleanup()
        let conflict = fixture.inbox.directory.appendingPathComponent(plan.removals[0].fileName)
        let preserved = fixture.inbox.directory.appendingPathComponent(plan.removals[1].fileName)
        try Data("private-replaced".utf8).write(to: conflict, options: .atomic)
        let blocked = await receiver.reconnect()
        #expect(blocked.health.problem == .interruptedOperation && blocked.snapshot.workingCount == 0)
        #expect(FileManager.default.fileExists(atPath: preserved.path))
        let report = try fixture.inbox.inspectRecovery()
        #expect(report.issues.first?.reason == .cleanupConflict)
        let saved = fixture.root.appendingPathComponent("kept-conflict")
        try FileManager.default.moveItem(at: conflict, to: saved)
        let repaired = await receiver.reconnect()
        #expect(repaired.health.state == .healthy && repaired.snapshot.workingCount == 1)
        #expect(try Data(contentsOf: saved) == Data("private-replaced".utf8))
        #expect(!FileManager.default.fileExists(atPath: preserved.path))
    }
}

@Test func cleanupIntentCannotBeReplayedIntoAReplacementDirectory() throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    try fixture.inbox.write(recoveryEvent(.completed, time: -10 * 86400))
    _ = try fixture.authorizeCleanup()
    let journal = fixture.inbox.directory.appendingPathComponent(InboxDirectory.cleanupIntentName)
    let bytes = try Data(contentsOf: journal)
    let old = fixture.root.appendingPathComponent("old")
    try FileManager.default.moveItem(at: fixture.inbox.directory, to: old)
    try fixture.inbox.prepare()
    try bytes.write(to: journal)
    let report = try fixture.inbox.recoverInterruptedOperations()
    #expect(report.issues.first?.reason == .invalidCleanupIntent && report.resumedCleanupFiles == 0)
    #expect(try Data(contentsOf: journal) == bytes)
}

@Test func cleanupCrashAfterJournalPublicationRecoversItsRedundantDraftLink() throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    try fixture.inbox.write(recoveryEvent(.completed, time: -10 * 86400))
    _ = try fixture.authorizeCleanup()
    let journal = fixture.inbox.directory.appendingPathComponent(InboxDirectory.cleanupIntentName)
    let draft = fixture.inbox.directory.appendingPathComponent(".tide-island-cleanup-" + UUID().uuidString + ".tmp")
    try FileManager.default.linkItem(at: journal, to: draft)
    let preview = try fixture.inbox.inspectRecovery()
    #expect(preview.pendingCleanupFiles == 1 && preview.issues.isEmpty)
    let result = try fixture.inbox.recoverInterruptedOperations()
    #expect(result.resumedCleanupFiles == 1 && result.issues.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: journal.path) && !FileManager.default.fileExists(atPath: draft.path))
    var cursor = InboxCursor()
    let empty = try fixture.inbox.readIncrementally(using: &cursor)
    #expect(empty.events.isEmpty)
}

@Test func replacedConsumerLockCannotLeaveTheOldReceiverUsingAnUnlinkedLease() async throws {
    try await withRecoveryReceiver { fixture, receiver in
        try fixture.inbox.write(recoveryEvent(.working))
        _ = await receiver.start()
        let files = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
        let lock = try #require(files.first { $0.pathExtension == "lock" })
        try FileManager.default.removeItem(at: lock)
        var competitor: InboxConsumerLease? = try InboxConsumerLease(inbox: fixture.inbox.directory)
        let changed = await receiver.reconnect()
        #expect(changed.health.state != .healthy && changed.snapshot.workingCount == 0)
        let denied = try await waitForRecovery(receiver) { $0.health.problem == .receiverInUse }
        #expect(denied.snapshot.workingCount == 0 && !denied.health.willRetry)
        try competitor?.verifyPath()
        competitor = nil
        let repaired = await receiver.reconnect()
        #expect(repaired.health.state == .healthy && repaired.snapshot.workingCount == 1)
    }
}

private struct RecoveryFixture: Sendable {
    let root: URL
    let inbox: EventInbox

    init() throws {
        let temporary = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        root = temporary.appendingPathComponent(UUID().uuidString)
        inbox = EventInbox(directory: root.appendingPathComponent("Events"))
        try inbox.prepare()
    }

    func eventPath() -> URL { inbox.directory.appendingPathComponent(UUID().uuidString + ".json") }
    func stagePath() -> URL { inbox.directory.appendingPathComponent(".tide-island-" + UUID().uuidString + ".tmp") }
    func stage(_ bytes: Data) throws -> URL {
        let path = stagePath()
        try bytes.write(to: path)
        return path
    }

    func authorizeCleanup() throws -> InboxCleanupPlan {
        let plan = try inbox.previewCleanup(at: recoveryEpoch)
        let directory = try InboxDirectory(url: inbox.directory, create: false, requireMarker: true)
        try directory.locked(exclusive: true) {
            let inventory = try inbox.scan(directory, previous: InboxCursor(), limits: InboxReadLimits())
            try directory.createCleanupIntent(plan, files: inventory.cursor.files)
        }
        return plan
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func recoveryEvent(_ phase: AgentPhase, session: String = "session", time: TimeInterval = 0,
                           id: UUID = UUID()) -> AgentEvent {
    let at = recoveryEpoch.addingTimeInterval(time)
    return AgentEvent(version: 2, id: id, sessionID: session, projectName: "project", phase: phase,
                      occurredAt: at, context: EventContext(source: .manual, kind: .status, receivedAt: at))
}

private func withRecoveryReceiver(limits: InboxReadLimits = InboxReadLimits(),
                                  _ body: (RecoveryFixture, InboxReceiver) async throws -> Void) async throws {
    let fixture = try RecoveryFixture()
    let receiver = InboxReceiver(inbox: fixture.inbox, limits: limits, now: { recoveryEpoch })
    defer { fixture.remove() }
    do { try await body(fixture, receiver) }
    catch { _ = await receiver.stop(); throw error }
    _ = await receiver.stop()
}

private func waitForRecovery(_ receiver: InboxReceiver, attempts: Int = 250,
                             _ condition: (InboxFrame) -> Bool) async throws -> InboxFrame {
    for _ in 0..<attempts {
        let frame = await receiver.current()
        if condition(frame) { return frame }
        try await Task.sleep(for: .milliseconds(20))
    }
    let last = await receiver.current()
    Issue.record("Receiver did not reach expected state: \(last.health.state), \(String(describing: last.health.problem))")
    throw InboxError.fileOperation
}

private func waitForRecoveryStream(_ stream: AsyncStream<InboxFrame>,
                                   _ condition: @escaping @Sendable (InboxFrame) -> Bool) async throws -> InboxFrame {
    try await withThrowingTaskGroup(of: InboxFrame.self) { group in
        group.addTask {
            for await frame in stream {
                if condition(frame) { return frame }
            }
            throw CancellationError()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw InboxError.fileOperation
        }
        defer { group.cancelAll() }
        guard let frame = try await group.next() else { throw InboxError.fileOperation }
        return frame
    }
}
