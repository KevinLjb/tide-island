import Darwin
import Foundation
import Testing
@testable import TideIslandCore

private let inboxEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func initialIncrementalScanRestoresMoreThan256EventsAndReusesUnchangedBodies() throws {
    let inbox = try maintenanceInbox()
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    for index in 0..<300 { try inbox.write(maintenanceEvent(.working, session: "long-\(index)", time: -7200)) }
    var cursor = InboxCursor()
    let first = try inbox.readIncrementally(using: &cursor)
    #expect(first.events.count == 300 && first.scannedFiles == 300 && first.decodedFiles == 300)
    var store = SessionStore()
    try store.receive(first.events)
    #expect(store.snapshot(at: inboxEpoch).unknownCount == 300)
    let repeated = try inbox.readIncrementally(using: &cursor)
    #expect(repeated.events.isEmpty && repeated.decodedFiles == 0 && repeated.unchangedFiles == 300)
    let next = maintenanceEvent(.working, session: "new")
    let path = try inbox.write(next)
    let added = try inbox.readIncrementally(using: &cursor)
    #expect(added.events == [next] && added.decodedFiles == 1 && added.unchangedFiles == 300)
    try FileManager.default.removeItem(at: path)
    let removed = try inbox.readIncrementally(using: &cursor)
    #expect(removed.removedFiles == 1 && removed.events.isEmpty && removed.decodedFiles == 0)
}

@Test func cursorDetectsSameSizeEditsEvenWhenModificationTimeIsRestored() throws {
    let inbox = try maintenanceInbox()
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    let original = maintenanceEvent(.working, session: "one", project: "a")
    let path = try inbox.write(original)
    let modified = try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as! Date
    var cursor = InboxCursor()
    _ = try inbox.readIncrementally(using: &cursor)
    usleep(2000)
    let edited = maintenanceEvent(.working, session: "one", project: "b", id: original.id)
    let bytes = try EventCodec.encode(edited)
    #expect(bytes.count == (try EventCodec.encode(original)).count)
    let handle = try FileHandle(forWritingTo: path)
    try handle.write(contentsOf: bytes)
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
    let update = try inbox.readIncrementally(using: &cursor)
    #expect(update.decodedFiles == 1 && update.events == [edited])
}

@Test func badInputsAreCachedAndSymlinksHardlinksDirectoriesAndFifosStayUnread() throws {
    let inbox = try maintenanceInbox()
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    try inbox.write(maintenanceEvent(.working, session: "valid"))
    try Data("not-json".utf8).write(to: maintenancePath(inbox))
    try EventCodec.encode(maintenanceEvent(.completed, session: "wrong-name")).write(to: maintenancePath(inbox))
    try Data(repeating: 0x20, count: EventCodec.maximumBytes + 1).write(to: maintenancePath(inbox))
    let notes = inbox.directory.appendingPathComponent("transcript.json")
    try Data("private-chat-never-delete".utf8).write(to: notes)
    try FileManager.default.createSymbolicLink(at: maintenancePath(inbox), withDestinationURL: notes)
    try FileManager.default.linkItem(at: notes, to: maintenancePath(inbox))
    try FileManager.default.createDirectory(at: maintenancePath(inbox), withIntermediateDirectories: false)
    #expect(mkfifo(maintenancePath(inbox).path, 0o600) == 0)
    var cursor = InboxCursor()
    let first = try inbox.readIncrementally(using: &cursor)
    #expect(first.events.count == 1 && first.rejectedFiles == 3 && first.skippedFiles == 4)
    #expect(first.decodedFiles == 3 && first.changedFiles == 4)
    let repeatRead = try inbox.readIncrementally(using: &cursor)
    #expect(repeatRead.decodedFiles == 0 && repeatRead.rejectedFiles == 3 && repeatRead.unchangedFiles == 4)
    let policy = try InboxRetentionPolicy(maximumAge: 1, maximumFiles: 1, maximumBytes: 1)
    let plan = try inbox.previewCleanup(policy: policy, at: inboxEpoch.addingTimeInterval(10 * 86400))
    #expect(plan.removals.isEmpty && !plan.targetsMetAfterCleanup)
    #expect(try Data(contentsOf: notes) == Data("private-chat-never-delete".utf8))
}

@Test func failedReadLimitsDoNotAdvanceTheCursorOrReturnAnIncompleteStartupBatch() throws {
    let inbox = try maintenanceInbox()
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    try inbox.write(maintenanceEvent(.working, session: "one"))
    try inbox.write(maintenanceEvent(.working, session: "two"))
    var cursor = InboxCursor()
    let fewFiles = try InboxReadLimits(maximumFiles: 1, maximumReadBytes: 10000)
    #expect(throws: InboxError.limitExceeded) { try inbox.readIncrementally(using: &cursor, limits: fewFiles) }
    #expect(cursor.files.isEmpty && cursor.directoryIdentity == nil)
    let fewBytes = try InboxReadLimits(maximumFiles: 10, maximumReadBytes: 1)
    #expect(throws: InboxError.limitExceeded) { try inbox.readIncrementally(using: &cursor, limits: fewBytes) }
    #expect(cursor.files.isEmpty && cursor.directoryIdentity == nil)
    #expect(try inbox.readIncrementally(using: &cursor).events.count == 2)
}

@Test func directoryReplacementInvalidatesFileIdentitiesWithoutSilentlyReusingOldEntries() throws {
    let inbox = try maintenanceInbox()
    let moved = inbox.directory.appendingPathExtension("moved")
    defer {
        try? FileManager.default.removeItem(at: inbox.directory)
        try? FileManager.default.removeItem(at: moved)
    }
    try inbox.write(maintenanceEvent(.working, session: "old"))
    var cursor = InboxCursor()
    _ = try inbox.readIncrementally(using: &cursor)
    try FileManager.default.moveItem(at: inbox.directory, to: moved)
    let replacement = maintenanceEvent(.working, session: "new")
    try inbox.write(replacement)
    let update = try inbox.readIncrementally(using: &cursor)
    #expect(update.directoryChanged && update.removedFiles == 1 && update.events == [replacement])
}

@Test func legacyReadingAndUnmanagedCleanupPreviewDoNotCreateFiles() throws {
    let inbox = try maintenanceInbox(prepared: false)
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    let event = maintenanceEvent(.working, session: "legacy")
    try EventCodec.encode(event).write(to: inbox.directory.appendingPathComponent(event.id.uuidString + ".json"))
    let before = try maintenanceBytes(inbox)
    var cursor = InboxCursor()
    #expect(try inbox.readIncrementally(using: &cursor).events == [event])
    #expect(throws: InboxError.unmanagedDirectory) { try inbox.previewCleanup(at: inboxEpoch) }
    #expect(try maintenanceBytes(inbox) == before)
    try inbox.prepare()
    #expect(try Data(contentsOf: inbox.directory.appendingPathComponent(".tide-island-inbox")) == Data("TideIsland event inbox v1\n".utf8))
    #expect(try inbox.readIncrementally(using: &cursor).directoryChanged)
}

@Test func managedWritersKeepUUIDContentsImmutableAndLeaveNoStagingFiles() throws {
    let inbox = try maintenanceInbox()
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    let event = maintenanceEvent(.working, session: "one")
    let path = try inbox.write(event)
    let original = try Data(contentsOf: path)
    try inbox.write(event)
    #expect(throws: InboxError.conflictingEventID) {
        try inbox.write(maintenanceEvent(.completed, session: "one", id: event.id))
    }
    #expect(try Data(contentsOf: path) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.directory.path).count == 2)
    #expect(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int == 0o600)
}

@Test func independentWritersPublishCompleteEventsAndOneCompleteMarker() async throws {
    let inbox = try maintenanceInbox(prepared: false)
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
            group.addTask { _ = try inbox.write(maintenanceEvent(.working, session: "writer-\(index)")) }
        }
        try await group.waitForAll()
    }
    var cursor = InboxCursor()
    let update = try inbox.readIncrementally(using: &cursor)
    #expect(update.events.count == 20 && update.rejectedFiles == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.directory.path).count == 21)
}

@Test func ageCleanupPreservesCompleteUnresolvedHistoriesAndRebuildsTheirState() throws {
    let inbox = try maintenanceInbox()
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    let active = [maintenanceHook(.turnStarted, session: "work", turn: "one", time: -90 * 86400),
                  maintenanceHook(.toolStarted, session: "work", turn: "one", time: -89 * 86400),
                  maintenanceHook(.permissionRequested, session: "wait", turn: "one", time: -80 * 86400)]
    let expired = [maintenanceHook(.turnStarted, session: "done", turn: "one", time: -9 * 86400),
                   maintenanceHook(.turnCompleted, session: "done", turn: "one", time: -8 * 86400)]
    for event in active + expired { try inbox.write(event) }
    let original = try maintenanceBytes(inbox)
    let plan = try inbox.previewCleanup(at: inboxEpoch)
    #expect(plan.protectedFiles == active.count && plan.removals.count == expired.count)
    #expect(plan.removals.allSatisfy { $0.reason == .age })
    #expect(try maintenanceBytes(inbox) == original)
    let result = try inbox.applyCleanup(plan, expectedFingerprint: plan.fingerprint)
    #expect(result.removedFiles == expired.count && result.failedFiles.isEmpty)
    var cursor = InboxCursor(), store = SessionStore()
    let update = try inbox.readIncrementally(using: &cursor)
    try store.receive(update.events)
    #expect(store.snapshot(at: inboxEpoch).unknownCount == 2)
    for event in active {
        let name = event.id.uuidString + ".json"
        #expect(try Data(contentsOf: inbox.directory.appendingPathComponent(name)) == original[name])
    }
}

@Test func capacityCleanupEvictsWholeOldestExpiredGroupsAndReportsProtectedPressure() throws {
    let inbox = try maintenanceInbox()
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    var groups: [[AgentEvent]] = []
    for day in [6, 5, 2] {
        let group = [maintenanceHook(.turnStarted, session: "day-\(day)", turn: "one", time: Double(-day * 86400 - 1)),
                     maintenanceHook(.turnCompleted, session: "day-\(day)", turn: "one", time: Double(-day * 86400))]
        groups.append(group)
        for event in group { try inbox.write(event) }
    }
    let policy = try InboxRetentionPolicy(maximumAge: 7 * 86400, maximumFiles: 3, maximumBytes: 1000000)
    let plan = try inbox.previewCleanup(policy: policy, at: inboxEpoch)
    #expect(Set(plan.removals.map(\.fileName)) == Set(groups.prefix(2).flatMap { $0 }.map { $0.id.uuidString + ".json" }))
    #expect(plan.removals.allSatisfy { $0.reason == .capacity })
    #expect(plan.remainingFiles == 2 && plan.targetsMetAfterCleanup)
    let result = try inbox.applyCleanup(plan, expectedFingerprint: plan.fingerprint)
    #expect(result.removedFiles == 4 && result.remainingFiles == 2 && result.targetsMet)
    try inbox.write(maintenanceEvent(.working, session: "protected", time: -100 * 86400))
    let pressure = try InboxRetentionPolicy(maximumAge: 7 * 86400, maximumFiles: 1, maximumBytes: 1)
    let pressured = try inbox.previewCleanup(policy: pressure, at: inboxEpoch)
    #expect(pressured.protectedFiles == 1 && pressured.removals.count == 2)
    #expect(!pressured.targetsMetAfterCleanup)
    let final = try inbox.applyCleanup(pressured, expectedFingerprint: pressured.fingerprint)
    #expect(final.remainingFiles == 1 && final.remainingBytes > 1 && !final.targetsMet)
}

@Test func recentFutureAndUnboundTurnEvidenceCannotBecomeCleanupCandidates() throws {
    let inbox = try maintenanceInbox()
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    for event in [maintenanceEvent(.completed, session: "recent", time: -3600),
                  maintenanceEvent(.ended, session: "exit", time: -7200),
                  maintenanceEvent(.completed, session: "future", time: 3600),
                  maintenanceHook(.turnCompleted, session: "unbound", turn: "old", time: -10 * 86400),
                  maintenanceHook(.toolStarted, session: "unbound", turn: "new", time: -9 * 86400)] {
        try inbox.write(event)
    }
    let policy = try InboxRetentionPolicy(maximumAge: 1, maximumFiles: 1, maximumBytes: 1)
    let plan = try inbox.previewCleanup(policy: policy, at: inboxEpoch)
    #expect(plan.protectedFiles == 5 && plan.removals.isEmpty && !plan.targetsMetAfterCleanup)
}

@Test func previewsRemainUsableAcrossClockTicksButNotAfterManagedInventoryChanges() throws {
    let inbox = try maintenanceInbox()
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    try inbox.write(maintenanceEvent(.completed, session: "expired", time: -10 * 86400))
    let first = try inbox.previewCleanup(at: inboxEpoch)
    let later = try inbox.previewCleanup(at: inboxEpoch.addingTimeInterval(1))
    #expect(first.fingerprint == later.fingerprint)
    let original = try maintenanceBytes(inbox)
    #expect(throws: InboxError.stalePlan) { try inbox.applyCleanup(first, expectedFingerprint: "wrong") }
    #expect(try maintenanceBytes(inbox) == original)
    try inbox.write(maintenanceEvent(.working, session: "new"))
    let changed = try maintenanceBytes(inbox)
    #expect(throws: InboxError.stalePlan) { try inbox.applyCleanup(first, expectedFingerprint: first.fingerprint) }
    #expect(try maintenanceBytes(inbox) == changed)
}

@Test func cleanupNeverFollowsDirectoryOrEventLinksIntoProviderFiles() throws {
    let inbox = try maintenanceInbox()
    let outside = inbox.directory.appendingPathExtension("provider")
    defer {
        try? FileManager.default.removeItem(at: inbox.directory)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let transcript = outside.appendingPathComponent("chat.jsonl")
    let text = Data("private-provider-chat".utf8)
    try text.write(to: transcript)
    try FileManager.default.createSymbolicLink(at: maintenancePath(inbox), withDestinationURL: transcript)
    try inbox.write(maintenanceEvent(.completed, session: "expired", time: -10 * 86400))
    let plan = try inbox.previewCleanup(at: inboxEpoch)
    #expect(plan.skippedFiles == 1 && plan.removals.count == 1)
    let renamed = outside.appendingPathComponent("original-inbox")
    try FileManager.default.moveItem(at: inbox.directory, to: renamed)
    try FileManager.default.createSymbolicLink(at: inbox.directory, withDestinationURL: outside)
    #expect(throws: InboxError.unsafeDirectory) { try inbox.applyCleanup(plan, expectedFingerprint: plan.fingerprint) }
    #expect(try Data(contentsOf: transcript) == text)
    #expect(FileManager.default.fileExists(atPath: renamed.appendingPathComponent(plan.removals[0].fileName).path))
}

@Test func markerTamperingAndExclusiveMaintenanceLocksPreventCleanupOrCursorProgress() throws {
    let inbox = try maintenanceInbox()
    defer { try? FileManager.default.removeItem(at: inbox.directory) }
    try inbox.write(maintenanceEvent(.completed, session: "expired", time: -10 * 86400))
    let plan = try inbox.previewCleanup(at: inboxEpoch)
    let marker = inbox.directory.appendingPathComponent(".tide-island-inbox")
    let fd = open(marker.path, O_RDONLY)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    var cursor = InboxCursor()
    #expect(throws: InboxError.busy) { try inbox.readIncrementally(using: &cursor) }
    #expect(throws: InboxError.busy) { try inbox.applyCleanup(plan, expectedFingerprint: plan.fingerprint) }
    #expect(cursor.files.isEmpty)
    #expect(flock(fd, LOCK_UN) == 0)
    try Data("invalid-marker".utf8).write(to: marker)
    #expect(throws: InboxError.unmanagedDirectory) { try inbox.applyCleanup(plan, expectedFingerprint: plan.fingerprint) }
    #expect(FileManager.default.fileExists(atPath: inbox.directory.appendingPathComponent(plan.removals[0].fileName).path))
}

@Test func invalidRetentionAndReadPoliciesAreRejected() throws {
    for age in [0.0, -1, .infinity, .nan] {
        #expect(throws: InboxError.invalidPolicy) { try InboxRetentionPolicy(maximumAge: age, maximumFiles: 1, maximumBytes: 1) }
    }
    #expect(throws: InboxError.invalidPolicy) { try InboxRetentionPolicy(maximumAge: 1, maximumFiles: 0, maximumBytes: 1) }
    #expect(throws: InboxError.invalidPolicy) { try InboxReadLimits(maximumFiles: 1, maximumReadBytes: 0) }
}

private func maintenanceInbox(prepared: Bool = true) throws -> EventInbox {
    let root = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.temporaryDirectory
    let inbox = EventInbox(directory: root.appendingPathComponent(UUID().uuidString))
    if prepared { try inbox.prepare() }
    else { try FileManager.default.createDirectory(at: inbox.directory, withIntermediateDirectories: true) }
    return inbox
}

private func maintenancePath(_ inbox: EventInbox) -> URL { inbox.directory.appendingPathComponent(UUID().uuidString + ".json") }

private func maintenanceBytes(_ inbox: EventInbox) throws -> [String: Data] {
    var bytes: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: inbox.directory.path) {
        bytes[name] = try Data(contentsOf: inbox.directory.appendingPathComponent(name))
    }
    return bytes
}

private func maintenanceEvent(_ phase: AgentPhase, session: String, time: Double = 0, project: String = "project", id: UUID = UUID()) -> AgentEvent {
    let at = inboxEpoch.addingTimeInterval(time)
    return AgentEvent(version: 2, id: id, sessionID: session, projectName: project, phase: phase, occurredAt: at,
                      context: EventContext(source: .manual, kind: .status, receivedAt: at))
}

private func maintenanceHook(_ kind: EventKind, session: String, turn: String, time: Double) -> AgentEvent {
    let at = inboxEpoch.addingTimeInterval(time)
    return AgentEvent(version: 2, sessionID: session, projectName: "project", phase: kind.expectedPhase!, occurredAt: at,
                      context: EventContext(source: kind == .turnCompleted ? .codexNotify : .codexHook, kind: kind, receivedAt: at,
                                            turnID: turn, toolName: kind == .toolStarted || kind == .permissionRequested ? "Bash" : nil,
                                            toolUseID: kind == .toolStarted ? UUID().uuidString : nil))
}
