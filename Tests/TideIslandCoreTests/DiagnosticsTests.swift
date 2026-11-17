import Darwin
import Foundation
import Testing
@testable import TideIslandCore

private let diagnosticEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func diagnosticVersionsDoNotClaimInstalledToolOrNativeVerification() throws {
    let report = try DiagnosticReport.offline(at: diagnosticEpoch)
    let object = try diagnosticObject(report)
    #expect(report.scope == "versionsOnly" && report.inventory == nil && report.sessions == nil && report.source == nil)
    #expect(object["capturedAt"] as? Double == 1_800_000_000_000)
    #expect(report.versions.codexContract == CodexHookAdapter.contractCLIVersion)
    #expect(!report.versions.installedCodexQueried && !report.versions.installedWaveQueried)
    #expect(!report.nativeRuntimeVerified && !report.visibleWaveFocusVerified)
}

@Test func diagnosticOfflineInventoryAggregatesWithoutIdentifiersOrSourceWrites() throws {
    let root = try diagnosticDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let inbox = EventInbox(directory: root.appendingPathComponent("Events"))
    let event = diagnosticEvent()
    try inbox.write(event)
    let rejected = inbox.directory.appendingPathComponent(UUID().uuidString + ".json")
    try Data("private-rejected-body".utf8).write(to: rejected)
    let linked = inbox.directory.appendingPathComponent(UUID().uuidString + ".json")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: rejected)
    let before = try diagnosticFiles(inbox.directory)
    let report = try DiagnosticReport.offline(inbox: inbox, at: diagnosticEpoch)
    let after = try diagnosticFiles(inbox.directory)
    #expect(before == after)
    #expect(report.scope == "offlineInventory" && report.sessions == nil && report.source == nil)
    #expect(report.inventory?.acceptedEventFiles == 1 && report.inventory?.rejectedFiles == 1 && report.inventory?.unsafeFiles == 1)
    #expect(report.inventory?.rejectionCounts?["malformed"] == 1 && report.inventory?.sourceCounts?["manual"] == 1)
    #expect(report.inventory?.runtimeStateAssessed == false && report.inventory?.checkpointRead == false)
    let bytes = try report.encoded(), text = String(decoding: bytes, as: UTF8.self)
    for forbidden in [event.id.uuidString, event.sessionID, event.projectName, "private-turn", "private-tool", "private-block", "private-rejected-body", root.path, rejected.lastPathComponent] {
        #expect(!text.contains(forbidden))
    }
}

@Test func diagnosticInventoryDoesNotResurrectResetSuppressedEventsOrTouchCheckpoint() throws {
    let root = try diagnosticDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let inbox = EventInbox(directory: root.appendingPathComponent("Events"))
    try inbox.write(diagnosticEvent())
    let state = SessionStateFile(inbox: inbox)
    let preview = try state.previewReset()
    _ = try state.applyReset(preview, expectedFingerprint: preview.fingerprint)
    let before = try Data(contentsOf: state.fileURL)
    let report = try DiagnosticReport.offline(inbox: inbox, at: diagnosticEpoch)
    let after = try Data(contentsOf: state.fileURL)
    let inspection = try state.inspect()
    #expect(inspection.sessions == 0 && inspection.importedFiles == 1 && before == after)
    #expect(report.inventory?.acceptedEventFiles == 1 && report.sessions == nil)
}

@Test func diagnosticMissingDirectoryProducesFixedFailureAndCreatesNothing() throws {
    let root = try diagnosticDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("private-missing")
    let report = try DiagnosticReport.offline(inbox: EventInbox(directory: missing), at: diagnosticEpoch)
    #expect(report.inventory?.state == "unavailable" && report.inventory?.problem == "unsafeDirectory")
    #expect(report.inventory?.acceptedEventFiles == nil && !FileManager.default.fileExists(atPath: missing.path))
    let bytes = try report.encoded()
    #expect(!String(decoding: bytes, as: UTF8.self).contains("private-missing"))
}

@Test func diagnosticScanBudgetFailureNeverReturnsPartialCounts() throws {
    let root = try diagnosticDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let inbox = EventInbox(directory: root.appendingPathComponent("Events"))
    try inbox.write(diagnosticEvent()); try inbox.write(diagnosticEvent())
    let limits = try InboxReadLimits(maximumFiles: 1, maximumReadBytes: 10000)
    let report = try DiagnosticReport.offline(inbox: inbox, at: diagnosticEpoch, limits: limits)
    #expect(report.inventory?.problem == "limitExceeded" && report.inventory?.acceptedEventFiles == nil)
    #expect(report.inventory?.sourceCounts == nil && report.sessions == nil)
}

@Test func diagnosticLegacyInventoryDoesNotInventEventSource() throws {
    let root = try diagnosticDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let inbox = EventInbox(directory: root)
    let event = AgentEvent(version: 1, sessionID: "private-legacy", projectName: "private-project", phase: .working, occurredAt: diagnosticEpoch)
    try EventCodec.encode(event).write(to: root.appendingPathComponent(event.id.uuidString + ".json"))
    let before = try diagnosticFiles(root)
    let report = try DiagnosticReport.offline(inbox: inbox, at: diagnosticEpoch)
    let after = try diagnosticFiles(root)
    #expect(report.inventory?.legacyWithoutSource == 1 && report.inventory?.sourceCounts?.isEmpty == true && before == after)
}

@Test func diagnosticLiveFramePreservesConfirmationAgeAndIndependentProblems() throws {
    var store = SessionStore(); try store.receive([diagnosticEvent()])
    let snapshot = store.snapshot(at: diagnosticEpoch, sourceIssue: .channelUnavailable)
    var health = InboxHealth(); health.state = .degraded; health.problem = .savedStateUnavailable
    health.lastSuccessAt = diagnosticEpoch.addingTimeInterval(-120); health.rejectionCounts = [.unsupportedVersion: 2]
    var persistence = SessionPersistenceStatus(); persistence.phase = .unavailable; persistence.problem = .unsupportedVersion
    let frame = InboxFrame(snapshot: snapshot, health: health, cleanupPlan: nil, notice: "private-notice", persistence: persistence, resetPreview: nil)
    let report = try DiagnosticReport.live(frame: frame, frameReceivedAt: diagnosticEpoch.addingTimeInterval(-60), at: diagnosticEpoch)
    #expect(report.source?.state == "degraded" && report.source?.problem == "savedStateUnavailable")
    #expect(report.source?.lastSuccessAt == health.lastSuccessAt && report.source?.frameReceivedAt == diagnosticEpoch.addingTimeInterval(-60))
    #expect(report.source?.persistenceProblem == "unsupportedVersion" && report.source?.rejectionCounts["unsupportedVersion"] == 2)
    #expect(report.sessions?.working == 0 && report.sessions?.unknown == 1 && report.inventory == nil)
    let bytes = try report.encoded()
    #expect(!String(decoding: bytes, as: UTF8.self).contains("private-"))
}

@Test func diagnosticUnavailableLiveFrameDoesNotReportConfirmedEmptySessions() throws {
    let report = try DiagnosticReport.live(frame: nil, frameReceivedAt: nil, at: diagnosticEpoch)
    #expect(report.scope == "liveUnavailable" && report.sessions == nil && report.source == nil)
}

@Test func diagnosticWaveFallbackRecommendationIsNotAnActualRoute() throws {
    let reference = SessionReference(sessionID: "private-session", eventID: UUID())
    let navigation = WaveNavigationResult(reference: reference, attemptedRoute: .none, outcome: .applicationFallbackRequired, reason: .contextUnavailable)
    let result = WaveReturnResult(reference: reference, navigation: navigation, applicationState: .notInstalled, applicationAttempted: false, outcome: .notInstalled)
    let observation = try DiagnosticWaveReturn(result: result, at: diagnosticEpoch)
    #expect(observation.attemptedRoutes.isEmpty && observation.navigationReason == "contextUnavailable")
    #expect(observation.outcome == "notInstalled" && !observation.visibleFocusVerified)
    let report = try DiagnosticReport.live(frame: nil, frameReceivedAt: nil, at: diagnosticEpoch, waveReturn: observation)
    let bytes = try report.encoded()
    #expect(!String(decoding: bytes, as: UTF8.self).contains("private-session"))
}

@Test func diagnosticWaveRetainsBothActualAttemptsAfterFailure() throws {
    let reference = SessionReference(sessionID: "private-session", eventID: UUID())
    let navigation = WaveNavigationResult(reference: reference, attemptedRoute: .tabLayoutFocus, outcome: .applicationFallbackRequired, reason: .focusTimedOut)
    let result = WaveReturnResult(reference: reference, navigation: navigation, applicationState: .running, applicationAttempted: true, outcome: .openFailed)
    let observation = try DiagnosticWaveReturn(result: result, at: diagnosticEpoch)
    #expect(observation.attemptedRoutes == ["tabLayoutFocus", "application"])
    #expect(observation.outcome == "openFailed" && observation.navigationReason == "focusTimedOut" && !observation.visibleFocusVerified)
}

@Test func diagnosticExportCreatesPrivateNewFileAndPreservesExistingDestination() throws {
    let root = try diagnosticDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let report = try DiagnosticReport.offline(at: diagnosticEpoch)
    let output = root.appendingPathComponent("report.json")
    try DiagnosticExport.write(report, to: output, excluding: [])
    let original = try Data(contentsOf: output), expected = try report.encoded()
    let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int
    #expect(original == expected && permissions == 0o600)
    #expect(throws: DiagnosticError.exportFailed) { try DiagnosticExport.write(report, to: output, excluding: []) }
    let after = try Data(contentsOf: output)
    #expect(after == original)
}

@Test func diagnosticExportRejectsProtectedRootsAliasesAndSymlinkDestinations() throws {
    let root = try diagnosticDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("Data"), alias = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: data)
    let report = try DiagnosticReport.offline(at: diagnosticEpoch)
    for destination in [data.appendingPathComponent("report.json"), alias.appendingPathComponent("report.json")] {
        #expect(throws: DiagnosticError.invalidDestination) { try DiagnosticExport.write(report, to: destination, excluding: [data]) }
    }
    let foreign = root.appendingPathComponent("foreign.json"), linked = root.appendingPathComponent("link.json")
    try Data("preserve".utf8).write(to: foreign)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: foreign)
    #expect(throws: DiagnosticError.exportFailed) { try DiagnosticExport.write(report, to: linked, excluding: []) }
    let after = try Data(contentsOf: foreign)
    #expect(after == Data("preserve".utf8))
    let sibling = root.appendingPathComponent("Data-report.json")
    try DiagnosticExport.write(report, to: sibling, excluding: [data])
    #expect(FileManager.default.fileExists(atPath: sibling.path))
}

@Test func diagnosticRejectsInvalidClockWithoutCopyingItToJSON() throws {
    let invalid = Date(timeIntervalSince1970: .infinity)
    #expect(throws: DiagnosticError.invalidClock) { try DiagnosticReport.offline(at: invalid) }
    #expect(throws: DiagnosticError.invalidClock) { try DiagnosticReport.live(frame: nil, frameReceivedAt: nil, at: invalid) }
}

@Test func diagnosticSystemStatusKeepsIndependentPermissionAndDeliveryCodes() throws {
    let status = DiagnosticSystemStatus(activity: .allowed, activityProblem: .updateFailed, remindersEnabled: true,
        notificationAuthorization: .denied, reminderProblem: .deliveryFailed, login: .requiresApproval)
    #expect(status.activityAvailability == "allowed" && status.activityProblem == "updateFailed")
    #expect(status.notificationAuthorization == "denied" && status.reminderProblem == "deliveryFailed" && status.loginItem == "requiresApproval")
}

private func diagnosticObject(_ report: DiagnosticReport) throws -> [String: Any] {
    let data = try report.encoded()
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

private func diagnosticEvent() -> AgentEvent {
    AgentEvent(version: 2, sessionID: "private-session", projectName: "private-project", phase: .working,
        occurredAt: diagnosticEpoch, waveBlockID: "private-block",
        context: EventContext(source: .manual, kind: .status, receivedAt: diagnosticEpoch,
                              turnID: "private-turn", toolName: "private-tool", toolUseID: "private-use"))
}

private func diagnosticDirectory() throws -> URL {
    let base = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    let root = base.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func diagnosticFiles(_ directory: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
        let path = directory.appendingPathComponent(name)
        let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        if values.isSymbolicLink == true { result[name] = Data("symbolic-link".utf8) }
        else if values.isRegularFile == true { result[name] = try Data(contentsOf: path) }
    }
    return result
}
