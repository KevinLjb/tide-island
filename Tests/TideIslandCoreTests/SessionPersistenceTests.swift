import Darwin
import Foundation
import Testing
@testable import TideIslandCore

private let persistenceEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func checkpointV2PreservesLocationAndItsClockAcrossReceiverRestarts() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let location = WaveLocation(blockID: UUID(), tabID: UUID(), workspaceID: UUID(), waveVersion: "0.14.5",
                                observedAt: persistenceEpoch.addingTimeInterval(-295), source: .blockListing)
    let event = AgentEvent(version: 2, sessionID: "location", projectName: "project", phase: .working,
                           occurredAt: persistenceEpoch, waveBlockID: location.blockID.uuidString, waveLocation: location,
                           context: EventContext(source: .manual, kind: .status, receivedAt: persistenceEpoch))
    try fixture.inbox.write(event)
    let first = fixture.receiver(at: persistenceEpoch)
    let initial = await first.start()
    #expect(initial.snapshot.sessions[0].waveLocation.validity == .recent)
    _ = await first.stop()
    let loaded = try fixture.state.load()
    let inspection = try fixture.state.inspect()
    #expect(loaded.schemaVersion == 2 && inspection.version == 2)
    let second = fixture.receiver()
    let restored = await second.start()
    #expect(restored.snapshot.sessions[0].session.waveLocation == location)
    #expect(restored.snapshot.sessions[0].waveLocation.validity == .stale && restored.snapshot.workingCount == 1)
    _ = await second.stop()
}

@Test func legacyCheckpointLoadsWithoutRewriteAndMigratesOnSuccessfulSave() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    var store = SessionStore()
    let event = persistenceEvent(.working)
    try store.receive([event])
    let encoded = try SessionCheckpointCodec.encode(store: store, index: [:], scope: fixture.state.scope)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["version"] = 1
    let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try fixture.writeState(legacy)
    let loaded = try fixture.state.load()
    let inspection = try fixture.state.inspect()
    let afterLoad = try Data(contentsOf: fixture.state.fileURL)
    #expect(loaded.schemaVersion == 1 && inspection.version == 1 && afterLoad == legacy)
    let restored = loaded.store.snapshot(at: persistenceEpoch)
    #expect(restored.sessions[0].session.waveLocation == nil && restored.sessions[0].session.lastEventID == event.id)
    _ = try fixture.state.save(loaded.store, index: loaded.importIndex, expected: loaded.revision)
    let migrated = try fixture.state.inspect()
    #expect(migrated.version == 2 && migrated.sessions == 1)
}

@Test func checkpointV1CannotHideLocationInCurrentOrPendingObservations() throws {
    let location = WaveLocation(blockID: UUID(), tabID: UUID(), waveVersion: "0.14.5",
                                observedAt: persistenceEpoch, source: .environment)
    for pendingOnly in [false, true] {
        var store = SessionStore()
        let first = AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: .working,
                               occurredAt: persistenceEpoch, waveLocation: pendingOnly ? nil : location,
                               context: EventContext(source: .codexHook, kind: .turnStarted, receivedAt: persistenceEpoch, turnID: "one"))
        try store.receive([first])
        if pendingOnly {
            let future = AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: .completed,
                                    occurredAt: persistenceEpoch, waveLocation: location,
                                    context: EventContext(source: .codexNotify, kind: .turnCompleted, receivedAt: persistenceEpoch, turnID: "two"))
            try store.receive([future])
        }
        let encoded = try SessionCheckpointCodec.encode(store: store, index: [:], scope: "test-scope")
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = 1
        let downgraded = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: SessionStateError.invalidData) { try SessionCheckpointCodec.decode(downgraded, scope: "test-scope") }
    }
}

@Test func invalidSavedLocationCannotBypassEventValidationOnRestore() throws {
    var store = SessionStore()
    let location = WaveLocation(blockID: UUID(), observedAt: persistenceEpoch, source: .environment)
    let event = AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: .working,
                           occurredAt: persistenceEpoch, waveLocation: location,
                           context: EventContext(source: .manual, kind: .status, receivedAt: persistenceEpoch))
    try store.receive([event])
    let encoded = try SessionCheckpointCodec.encode(store: store, index: [:], scope: "test-scope")
    // Replace only the nested version token; the checkpoint header remains v2.
    let text = String(decoding: encoded, as: UTF8.self)
    let invalid = Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":999").utf8)
    #expect(invalid != encoded)
    #expect(throws: SessionStateError.invalidData) { try SessionCheckpointCodec.decode(invalid, scope: "test-scope") }
}

@Test func checkpointRestoresReadPinnedIgnoredAndSelectedObservationsAcrossReceivers() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let first = fixture.receiver()
    let a = persistenceEvent(.needsInput, session: "a")
    let b = persistenceEvent(.needsInput, session: "b")
    try fixture.inbox.write(a); try fixture.inbox.write(b)
    _ = await first.start()
    let pinned = await first.perform(.pin, for: .init(sessionID: a.sessionID, eventID: a.id))
    let selected = await first.perform(.select, for: .init(sessionID: a.sessionID, eventID: a.id))
    let ignored = await first.perform(.ignore, for: .init(sessionID: b.sessionID, eventID: b.id))
    #expect(pinned && selected && ignored)
    let saved = try fixture.state.inspect()
    #expect(saved.sessions == 2 && saved.preferences == 2)
    _ = await first.stop()
    let second = fixture.receiver()
    let restored = await second.start()
    #expect(restored.snapshot.waitingCount == 1 && restored.snapshot.ignoredSessions.count == 1)
    #expect(restored.snapshot.selectedSession?.id == "a" && restored.snapshot.sessions[0].attention.isPinned)
    #expect(!restored.snapshot.sessions[0].attention.isUnread && restored.snapshot.sessions[0].session.updatedAt == a.occurredAt)
    let next = persistenceEvent(.needsInput, session: "b", time: 1)
    try fixture.inbox.write(next)
    let updated = await second.reconnect()
    #expect(updated.snapshot.waitingCount == 2 && updated.snapshot.ignoredSessions.isEmpty)
    #expect(updated.snapshot.sessions.first { $0.id == "b" }?.attention.isUnread == true)
    _ = await second.stop()
}

@Test func restoredWorkNeedsCurrentSourceAndDoesNotGetANewFreshnessClock() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let original = persistenceEvent(.working)
    try fixture.inbox.write(original)
    let first = fixture.receiver()
    _ = await first.start(); _ = await first.stop()
    try FileManager.default.removeItem(at: fixture.inbox.directory)
    let second = fixture.receiver()
    let missing = await second.start()
    #expect(missing.snapshot.workingCount == 0 && missing.snapshot.unknownCount == 1)
    #expect(missing.snapshot.sessions[0].sourceIssue == .eventMissing && missing.snapshot.sessions[0].session.updatedAt == original.occurredAt)
    _ = await second.stop()
    try fixture.inbox.write(original)
    let old = fixture.receiver(at: persistenceEpoch.addingTimeInterval(700))
    let stale = await old.start()
    #expect(stale.snapshot.workingCount == 0 && stale.snapshot.sessions[0].freshness == .stale)
    #expect(stale.snapshot.sessions[0].session.updatedAt == original.occurredAt)
    _ = await old.stop()
}

@Test func checkpointPreservesParallelPermissionToolsAndUnboundFutureTurnEvidence() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let observations = [persistenceHook(.turnStarted, time: 0),
                        persistenceHook(.toolStarted, time: 1, tool: "one"),
                        persistenceHook(.toolStarted, time: 2, tool: "two"),
                        persistenceHook(.permissionRequested, time: 3),
                        persistenceHook(.turnCompleted, turn: "next", time: 4)]
    for event in observations { try fixture.inbox.write(event) }
    var cursor = InboxCursor(), store = SessionStore()
    let update = try fixture.inbox.readIncrementally(using: &cursor)
    try store.receive(update.events)
    let absent = try fixture.state.load()
    _ = try fixture.state.save(store, index: cursor.importIndex, expected: absent.revision)
    var restored = try fixture.state.load().store
    try restored.receive([persistenceHook(.toolFinished, time: 5, tool: "one")])
    #expect(restored.snapshot(at: persistenceEpoch.addingTimeInterval(10)).waitingCount == 1)
    try restored.receive([persistenceHook(.toolFinished, time: 6, tool: "two")])
    #expect(restored.snapshot(at: persistenceEpoch.addingTimeInterval(10)).workingCount == 1)
    try restored.receive([persistenceHook(.turnStarted, turn: "next", time: 7)])
    let terminal = restored.snapshot(at: persistenceEpoch.addingTimeInterval(10))
    #expect(terminal.sessions[0].session.phase == .completed && terminal.sessions[0].session.turnID == "next")
    #expect(terminal.sessions[0].session.updatedAt == persistenceEpoch.addingTimeInterval(4))
    try restored.receive([persistenceHook(.turnStarted, turn: "turn", time: 8)])
    #expect(restored.snapshot(at: persistenceEpoch.addingTimeInterval(10)).sessions[0].session.phase == .completed)
    // The public v2 validator also accepts a source-supplied SessionEnd turn
    // hint. Preserve that raw context separately from the tracked turn.
    let endedAt = persistenceEpoch.addingTimeInterval(9)
    let ended = AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: .ended, occurredAt: endedAt,
                           context: EventContext(source: .codexHook, kind: .sessionEnded, receivedAt: endedAt, turnID: "source-hint"))
    try restored.receive([ended])
    let beforeEndSave = try fixture.state.load()
    _ = try fixture.state.save(restored, index: cursor.importIndex, expected: beforeEndSave.revision)
    let endState = try fixture.state.load().store.snapshot(at: persistenceEpoch.addingTimeInterval(10))
    #expect(endState.sessions[0].session.turnID == "next" && endState.sessions[0].session.context?.turnID == "source-hint")
}

@Test func checkpointPreservesEventFIFOSlotsAndNextEviction() throws {
    var registry = SessionRegistry()
    let events = (0..<(SessionRegistry.eventHistoryLimit + 7)).map {
        persistenceEvent(.working, time: Double($0))
    }
    for event in events { try registry.apply(event) }
    let bytes = try JSONEncoder().encode(registry.persistedState())
    let decoded = try JSONDecoder().decode(SessionRegistry.PersistedState.self, from: bytes)
    var restored = try SessionRegistry(persisted: decoded)
    let duplicate = try restored.applyResult(events[7])
    #expect(duplicate == .duplicateEvent)
    try restored.apply(persistenceEvent(.working, time: 1000))
    let evicted = try restored.applyResult(events[7])
    #expect(evicted == .olderEvent)
}

@Test func checkpointPreservesRetiredTurnFIFOEvidenceWithoutExtendingItsWindow() throws {
    var registry = SessionRegistry()
    for index in 0..<70 { try registry.apply(persistenceHook(.turnStarted, turn: "turn-\(index)", time: Double(index))) }
    let bytes = try JSONEncoder().encode(registry.persistedState())
    let decoded = try JSONDecoder().decode(SessionRegistry.PersistedState.self, from: bytes)
    var restored = try SessionRegistry(persisted: decoded)
    let retired = try restored.applyResult(persistenceHook(.turnStarted, turn: "turn-5", time: 100))
    #expect(retired == .retiredTurn)
    try restored.apply(persistenceHook(.turnStarted, turn: "turn-70", time: 71))
    let outsideWindow = try restored.applyResult(persistenceHook(.turnStarted, turn: "turn-5", time: 100))
    #expect(outsideWindow == .applied)
}

@Test func receiverCleanupPersistsTerminalProtectionBeforeDeletingItsSourceChain() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let history = [persistenceHook(.turnStarted, time: -10 * 86400 - 1),
                   persistenceHook(.turnCompleted, time: -10 * 86400)]
    for event in history { try fixture.inbox.write(event) }
    let first = fixture.receiver()
    _ = await first.start()
    let initialSave = await first.flushSavedState()
    #expect(initialSave)
    let validState = try Data(contentsOf: fixture.state.fileURL)
    try fixture.writeState(Data("private-external-corruption".utf8))
    await first.previewCleanup(); await first.applyCleanup()
    for event in history { #expect(FileManager.default.fileExists(atPath: fixture.path(event).path)) }
    let refused = await first.current()
    #expect(refused.persistence.phase == .unavailable && refused.persistence.problem == .conflict)
    try fixture.writeState(validState)
    let repaired = await first.reconnect()
    #expect(repaired.persistence.phase == .saved)
    await first.previewCleanup(); await first.applyCleanup()
    for event in history {
        #expect(!FileManager.default.fileExists(atPath: fixture.path(event).path))
    }
    _ = await first.stop()
    let second = fixture.receiver()
    _ = await second.start()
    try fixture.inbox.write(persistenceHook(.toolStarted, time: 0, tool: "late"))
    let late = await second.reconnect()
    #expect(late.snapshot.workingCount == 0 && late.snapshot.sessions.isEmpty)
    try fixture.inbox.write(persistenceHook(.turnStarted, turn: "new", time: 1))
    let next = await second.reconnect()
    #expect(next.snapshot.workingCount == 1 && next.snapshot.sessions[0].session.turnID == "new")
    _ = await second.stop()
}

@Test func offlineCleanupAlsoSavesTerminalStateAndRefusesWrongFingerprintBeforeWriting() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let history = [persistenceHook(.turnStarted, time: -10 * 86400 - 1), persistenceHook(.turnCompleted, time: -10 * 86400)]
    for event in history { try fixture.inbox.write(event) }
    let plan = try fixture.inbox.previewCleanup(at: persistenceEpoch)
    #expect(throws: InboxError.stalePlan) { try fixture.state.applyCleanup(plan, expectedFingerprint: "wrong") }
    #expect(!FileManager.default.fileExists(atPath: fixture.state.directory.path))
    let result = try fixture.state.applyCleanup(plan, expectedFingerprint: plan.fingerprint)
    #expect(result.removedFiles == 2)
    var restored = try fixture.state.load().store
    try restored.receive([persistenceHook(.toolStarted, time: 0, tool: "late")])
    #expect(restored.snapshot(at: persistenceEpoch).workingCount == 0)
}

@Test func activeReceiverExcludesStandaloneResetAndCleanupWriters() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    try fixture.inbox.write(persistenceEvent(.completed, time: -10 * 86400))
    let receiver = fixture.receiver()
    _ = await receiver.start()
    let flushed = await receiver.flushSavedState()
    #expect(flushed)
    let preview = try fixture.state.previewReset()
    let cleanup = try fixture.inbox.previewCleanup(at: persistenceEpoch)
    let original = try Data(contentsOf: fixture.state.fileURL)
    #expect(throws: InboxError.receiverAlreadyRunning) { try fixture.state.applyReset(preview, expectedFingerprint: preview.fingerprint) }
    #expect(throws: InboxError.receiverAlreadyRunning) { try fixture.state.applyCleanup(cleanup, expectedFingerprint: cleanup.fingerprint) }
    let after = try Data(contentsOf: fixture.state.fileURL)
    #expect(after == original)
    _ = await receiver.stop()
}

@Test func clearAtomicallyResetsPreferencesAndSuppressesExistingFilesAcrossRestart() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let event = persistenceEvent(.needsInput)
    try fixture.inbox.write(event)
    let original = try Data(contentsOf: fixture.path(event))
    let first = fixture.receiver()
    _ = await first.start()
    _ = await first.perform(.pin, for: .init(sessionID: event.sessionID, eventID: event.id))
    let previewValue = await first.previewReset()
    let preview = try #require(previewValue)
    let cleared = await first.applyReset(expectedFingerprint: preview.fingerprint)
    #expect(cleared)
    let empty = await first.current()
    #expect(empty.snapshot.sessions.isEmpty && empty.snapshot.preferredSessionID == nil)
    let untouched = try Data(contentsOf: fixture.path(event))
    #expect(untouched == original)
    _ = await first.stop()
    let second = fixture.receiver()
    let restarted = await second.start()
    #expect(restarted.snapshot.sessions.isEmpty)
    let next = persistenceEvent(.needsInput, time: 1)
    try fixture.inbox.write(next)
    let current = await second.reconnect()
    #expect(current.snapshot.waitingCount == 1 && !current.snapshot.sessions[0].attention.isPinned)
    #expect(current.snapshot.sessions[0].attention.isUnread)
    _ = await second.stop()
}

@Test func clearedRecordsStayHiddenWhenTheDirectoryOrMarkerIsReplacedWithIdenticalFiles() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let old = persistenceEvent(.working)
    try fixture.inbox.write(old)
    let receiver = fixture.receiver()
    _ = await receiver.start()
    let value = await receiver.previewReset()
    let preview = try #require(value)
    _ = await receiver.applyReset(expectedFingerprint: preview.fingerprint)
    let retired = fixture.root.appendingPathComponent("retired")
    try FileManager.default.moveItem(at: fixture.inbox.directory, to: retired)
    try fixture.inbox.write(old)
    let rebuilt = await receiver.reconnect()
    #expect(rebuilt.health.state == .healthy && rebuilt.snapshot.sessions.isEmpty)
    _ = await receiver.stop()
}

@Test func newStateOrInboxContentsInvalidateClearPreviewWithoutClearingAnything() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let original = persistenceEvent(.working)
    try fixture.inbox.write(original)
    let receiver = fixture.receiver()
    _ = await receiver.start()
    let value = await receiver.previewReset()
    let preview = try #require(value)
    try fixture.inbox.write(persistenceEvent(.needsInput, session: "new"))
    let refused = await receiver.applyReset(expectedFingerprint: preview.fingerprint)
    #expect(!refused)
    let current = await receiver.reconnect()
    #expect(current.snapshot.sessions.count == 2)
    _ = await receiver.stop()
}

@Test func corruptSavedDataIsPreservedAndCanOnlyBeReplacedByReviewedClear() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    try fixture.inbox.write(persistenceEvent(.working))
    try fixture.writeState(Data("private-corrupt-checkpoint".utf8))
    let receiver = fixture.receiver()
    let failed = await receiver.start()
    #expect(failed.health.problem == .savedStateUnavailable && failed.persistence.problem == .invalidData)
    #expect(failed.snapshot.workingCount == 0 && failed.snapshot.sessions.isEmpty)
    _ = await receiver.reconnect()
    let preserved = try Data(contentsOf: fixture.state.fileURL)
    #expect(preserved == Data("private-corrupt-checkpoint".utf8))
    let value = await receiver.previewReset()
    let preview = try #require(value)
    let cleared = await receiver.applyReset(expectedFingerprint: preview.fingerprint)
    #expect(cleared)
    let current = await receiver.current()
    #expect(current.health.state == .healthy && current.snapshot.sessions.isEmpty && current.persistence.phase == .saved)
    _ = await receiver.stop()
}

@Test func unsupportedFutureCheckpointIsNotInterpretedAsEmptyOrOverwritten() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let future = Data("{\"version\":999,\"future\":\"private-unknown-fields\"}".utf8)
    try fixture.writeState(future)
    #expect(throws: SessionStateError.unsupportedVersion) { try fixture.state.load() }
    let after = try Data(contentsOf: fixture.state.fileURL)
    #expect(after == future)
}

@Test func checkpointCannotBeCopiedToAnotherInboxScope() throws {
    let first = try PersistenceFixture(), second = try PersistenceFixture()
    defer { first.remove(); second.remove() }
    var store = SessionStore()
    try store.receive([persistenceEvent(.working)])
    let initial = try first.state.load()
    _ = try first.state.save(store, index: [:], expected: initial.revision)
    let bytes = try Data(contentsOf: first.state.fileURL)
    try second.writeState(bytes)
    #expect(throws: SessionStateError.scopeMismatch) { try second.state.load() }
}

@Test func malformedWindowPreferenceAndImportIndexAreRejectedAsAWhole() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    var store = SessionStore()
    try store.receive([persistenceEvent(.working)])
    let valid = try SessionCheckpointCodec.encode(store: store, index: [:], scope: fixture.state.scope)
    let source = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
    var badIndex = source
    badIndex["importIndex"] = ["../provider.json": String(repeating: "a", count: 64)]
    var badPreference = source
    var payload = source["store"] as! [String: Any]
    payload["preferredSessionID"] = "missing-session"
    badPreference["store"] = payload
    var badWindow = source
    payload = source["store"] as! [String: Any]
    var registry = payload["registry"] as! [String: Any]
    var storage = registry["storage"] as! [String: Any]
    var state = storage["session"] as! [String: Any]
    var seen = state["seen"] as! [String: Any]
    seen["capacity"] = 0
    state["seen"] = seen; storage["session"] = state; registry["storage"] = storage
    payload["registry"] = registry; badWindow["store"] = payload
    for object in [badIndex, badPreference, badWindow] {
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: SessionStateError.invalidData) { try SessionCheckpointCodec.decode(data, scope: fixture.state.scope) }
    }
}

@Test func checkpointUsesCompareAndSwapAndDoesNotRewriteUnchangedData() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let initial = try fixture.state.load()
    var store = SessionStore()
    try store.receive([persistenceEvent(.working)])
    let first = try fixture.state.save(store, index: [:], expected: initial.revision)
    let bytes = try Data(contentsOf: fixture.state.fileURL)
    #expect(throws: SessionStateError.conflict) { try fixture.state.save(SessionStore(), index: [:], expected: initial.revision) }
    let again = try fixture.state.save(store, index: [:], expected: first)
    let after = try Data(contentsOf: fixture.state.fileURL)
    #expect(again == first && after == bytes)
}

@Test func busyStateLockLeavesThePublishedCheckpointUnchanged() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let initial = try fixture.state.load()
    let revision = try fixture.state.save(SessionStore(), index: [:], expected: initial.revision)
    let fd = open(fixture.state.directory.appendingPathComponent(SessionStateDirectory.lockName).path, O_RDONLY)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: SessionStateError.busy) { try fixture.state.save(SessionStore(), index: [:], expected: revision) }
    #expect(flock(fd, LOCK_UN) == 0)
    let after = try fixture.state.load()
    #expect(after.revision == revision)
}

@Test func saveFailureIsVisibleAndPreventsHistoryDeletionUntilStateIsDurable() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let old = persistenceEvent(.completed, time: -10 * 86400)
    try fixture.inbox.write(old)
    let receiver = fixture.receiver()
    _ = await receiver.start()
    let saved = await receiver.flushSavedState()
    #expect(saved)
    let fd = open(fixture.state.directory.appendingPathComponent(SessionStateDirectory.lockName).path, O_RDONLY)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    let fresh = persistenceEvent(.needsInput, session: "fresh")
    try fixture.inbox.write(fresh)
    _ = await receiver.reconnect()
    let selected = await receiver.perform(.select, for: .init(sessionID: fresh.sessionID, eventID: fresh.id))
    #expect(selected)
    let failed = await receiver.current()
    #expect(failed.persistence.phase == .unavailable && failed.persistence.problem == .busy)
    await receiver.previewCleanup(); await receiver.applyCleanup()
    #expect(FileManager.default.fileExists(atPath: fixture.path(old).path))
    #expect(flock(fd, LOCK_UN) == 0)
    let recovered = await receiver.flushSavedState()
    #expect(recovered)
    await receiver.previewCleanup(); await receiver.applyCleanup()
    #expect(!FileManager.default.fileExists(atPath: fixture.path(old).path))
    _ = await receiver.stop()
}

@Test func stateLoadAndResetPreviewCreateNoFoldersAndNeverChangeInboxBytes() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let event = persistenceEvent(.working)
    try fixture.inbox.write(event)
    let original = try Data(contentsOf: fixture.path(event))
    let absent = try fixture.state.inspect()
    let first = try fixture.state.previewReset()
    let second = try fixture.state.previewReset()
    #expect(!absent.exists && first.fingerprint == second.fingerprint && first.eventFiles == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.state.directory.path))
    #expect(throws: SessionStateError.conflict) { try fixture.state.applyReset(first, expectedFingerprint: "wrong") }
    #expect(!FileManager.default.fileExists(atPath: fixture.state.directory.path))
    let after = try Data(contentsOf: fixture.path(event))
    #expect(after == original)
}

@Test func stateFilesRejectSymlinksHardlinksAndLinkedDirectoriesWithoutReadingProviderData() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let provider = fixture.root.appendingPathComponent("provider")
    try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: false)
    let secret = provider.appendingPathComponent("chat.jsonl")
    try Data("private-provider-chat".utf8).write(to: secret)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
    try FileManager.default.createSymbolicLink(at: fixture.state.directory, withDestinationURL: provider)
    #expect(throws: SessionStateError.unsafePath) { try fixture.state.load() }
    try FileManager.default.removeItem(at: fixture.state.directory)
    try FileManager.default.createDirectory(at: fixture.state.directory, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: fixture.state.fileURL, withDestinationURL: secret)
    #expect(throws: SessionStateError.unsafePath) { try fixture.state.load() }
    try FileManager.default.removeItem(at: fixture.state.fileURL)
    try FileManager.default.linkItem(at: secret, to: fixture.state.fileURL)
    #expect(throws: SessionStateError.unsafePath) { try fixture.state.load() }
    let bytes = try Data(contentsOf: secret)
    #expect(bytes == Data("private-provider-chat".utf8))
}

@Test func storageLimitsRefuseTruncationAndPreserveTheLastCompleteState() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let absent = try fixture.state.load()
    let revision = try fixture.state.save(SessionStore(), index: [:], expected: absent.revision)
    let original = try Data(contentsOf: fixture.state.fileURL)
    var large = SessionStore()
    try large.receive((0...SessionCheckpointCodec.maximumSessions).map { persistenceEvent(.working, session: "s-\($0)") })
    #expect(throws: SessionStateError.limitExceeded) { try fixture.state.save(large, index: [:], expected: revision) }
    let after = try Data(contentsOf: fixture.state.fileURL)
    #expect(after == original)
    let handle = try FileHandle(forWritingTo: fixture.state.fileURL)
    try handle.truncate(atOffset: UInt64(SessionCheckpointCodec.maximumBytes + 1))
    try handle.close()
    #expect(throws: SessionStateError.limitExceeded) { try fixture.state.load() }
}

@Test func failedInboxScanDoesNotCommitAPartialCheckpointOrConfirmRestoredWork() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    try fixture.inbox.write(persistenceEvent(.working))
    let first = fixture.receiver()
    _ = await first.start(); _ = await first.stop()
    let original = try Data(contentsOf: fixture.state.fileURL)
    let limits = try InboxReadLimits(maximumFiles: 10, maximumReadBytes: 1)
    let second = InboxReceiver(inbox: fixture.inbox, limits: limits, persistence: fixture.state, now: { persistenceEpoch })
    let failed = await second.start()
    #expect(failed.health.problem == .readLimitExceeded && failed.snapshot.workingCount == 0)
    _ = await second.stop()
    let after = try Data(contentsOf: fixture.state.fileURL)
    #expect(after == original)
    let fresh = try PersistenceFixture()
    defer { fresh.remove() }
    try fresh.inbox.write(persistenceEvent(.working))
    let neverLoaded = InboxReceiver(inbox: fresh.inbox, limits: limits, persistence: fresh.state, now: { persistenceEpoch })
    let initialFailure = await neverLoaded.start()
    #expect(initialFailure.health.problem == .readLimitExceeded)
    _ = await neverLoaded.stop()
    #expect(!FileManager.default.fileExists(atPath: fresh.state.directory.path))
}

@Test func checkpointSaveUsesPrivateAtomicFilesAndExcludesProviderContent() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let provider = fixture.inbox.directory.appendingPathComponent("transcript.jsonl")
    try Data("private-chat-body-and-token".utf8).write(to: provider)
    try fixture.inbox.write(persistenceEvent(.working))
    var cursor = InboxCursor(), store = SessionStore()
    let update = try fixture.inbox.readIncrementally(using: &cursor)
    try store.receive(update.events)
    let absent = try fixture.state.load()
    _ = try fixture.state.save(store, index: cursor.importIndex, expected: absent.revision)
    let data = try Data(contentsOf: fixture.state.fileURL)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("private-") && !text.contains("transcript") && !text.contains("environment"))
    let permissions = try FileManager.default.attributesOfItem(atPath: fixture.state.fileURL.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.state.directory.path)
    #expect(names.count == 2 && !names.contains { $0.hasSuffix(".tmp") })
}

@Test func saveWindowPublishesDurabilityStatusThroughTheRealFrameStream() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    try fixture.inbox.write(persistenceEvent(.working))
    let receiver = fixture.receiver()
    let started = await receiver.start()
    #expect(started.persistence.phase == .pending)
    let saved = try await withThrowingTaskGroup(of: InboxFrame.self) { group in
        group.addTask {
            for await frame in receiver.frames {
                if frame.persistence.phase == .saved { return frame }
            }
            throw CancellationError()
        }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw SessionStateError.fileOperation }
        defer { group.cancelAll() }
        guard let frame = try await group.next() else { throw SessionStateError.fileOperation }
        return frame
    }
    #expect(saved.snapshot.workingCount == 1 && saved.persistence.problem == nil)
    let inspection = try fixture.state.inspect()
    #expect(inspection.sessions == 1 && inspection.importedFiles == 1)
    _ = await receiver.stop()
}

private struct PersistenceFixture: Sendable {
    let root: URL
    let inbox: EventInbox
    var state: SessionStateFile { SessionStateFile(inbox: inbox) }

    init() throws {
        let temporary = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        root = temporary.appendingPathComponent(UUID().uuidString)
        inbox = EventInbox(directory: root.appendingPathComponent("Events"))
        try inbox.prepare()
    }

    func path(_ event: AgentEvent) -> URL { inbox.directory.appendingPathComponent(event.id.uuidString + ".json") }
    func receiver(at: Date = persistenceEpoch.addingTimeInterval(10)) -> InboxReceiver {
        InboxReceiver(inbox: inbox, persistence: state, now: { at })
    }
    func writeState(_ data: Data) throws {
        try FileManager.default.createDirectory(at: state.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: state.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.fileURL.path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func persistenceEvent(_ phase: AgentPhase, session: String = "session", time: TimeInterval = 0) -> AgentEvent {
    let at = persistenceEpoch.addingTimeInterval(time)
    return AgentEvent(version: 2, sessionID: session, projectName: "project", phase: phase, occurredAt: at,
                      context: EventContext(source: .manual, kind: .status, receivedAt: at))
}

private func persistenceHook(_ kind: EventKind, turn: String = "turn", time: TimeInterval,
                             tool: String? = nil) -> AgentEvent {
    let at = persistenceEpoch.addingTimeInterval(time)
    let isTool = kind == .toolStarted || kind == .toolFinished || kind == .permissionRequested
    return AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: kind.expectedPhase!, occurredAt: at,
                      context: EventContext(source: kind == .turnCompleted ? .codexNotify : .codexHook, kind: kind,
                                            receivedAt: at, turnID: turn, toolName: isTool ? "Bash" : nil,
                                            toolUseID: kind == .permissionRequested ? nil : tool))
}
