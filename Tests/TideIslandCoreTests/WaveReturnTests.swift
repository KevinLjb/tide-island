import Foundation
import Testing
@testable import TideIslandCore

private let returnEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private let returnBlock = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
private let returnTab = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
private let returnConnection = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!

@Test func returnLinksBoundDecodedUTF8IDsAndPreserveEncodedCharacters() throws {
    for id in ["thread with space&query=?", "潮汐/项目", String(repeating: "a", count: 256), String(repeating: "🐚", count: 64)] {
        let url = try #require(SessionLink.url(for: id))
        #expect(SessionLink.sessionID(from: url) == id)
    }
    for id in ["", "  ", "bad\nline", "bad\u{0}id", String(repeating: "a", count: 257), String(repeating: "潮", count: 86)] {
        #expect(SessionLink.url(for: id) == nil)
    }
}

@Test func returnLinksRejectForeignAuthorityFragmentsAndUndeclaredFields() throws {
    let values = ["https://session?id=a", "tide-island://other?id=a", "tide-island://user:pass@session?id=a",
                  "tide-island://session:80?id=a", "tide-island://session/?id=a", "tide-island://session/path?id=a",
                  "tide-island://session?id=a#fragment", "tide-island://session?id=a&id=b",
                  "tide-island://session?id=a&command=fixture-private", "tide-island://session?id=%00",
                  "tide-island://session?id=%20%20", "tide-island://session?id=" + String(repeating: "a", count: 4097)]
    for value in values {
        let url = try #require(URL(string: value))
        #expect(SessionLink.sessionID(from: url) == nil)
    }
}

@Test func returnLinksResolveTheCurrentObservationWithoutChangingSelection() throws {
    let event = returnEvent(), url = try #require(SessionLink.url(for: "session"))
    var store = SessionStore(); try store.receive([event])
    let before = store.snapshot(at: returnEpoch)
    let resolution = SessionLink.resolve(url, in: before, at: returnEpoch)
    #expect(resolution == .success(returnReference(event)))
    #expect(store.snapshot(at: returnEpoch) == before && before.preferredSessionID == nil)
}

@Test func returnLinksReportMissingIgnoredExpiredAndAmbiguousTargets() throws {
    let event = returnEvent(), url = try #require(SessionLink.url(for: "session"))
    var store = SessionStore(); try store.receive([event])
    let unknown = try #require(SessionLink.url(for: "fixture-private-missing"))
    #expect(SessionLink.resolve(unknown, in: store.snapshot(at: returnEpoch), at: returnEpoch) == .failure(.sessionUnavailable))
    let visible = store.snapshot(at: returnEpoch)
    let ambiguous = SessionSnapshot(sessions: visible.sessions + visible.sessions, ignoredSessions: [], preferredSessionID: nil, nextTransitionAt: nil)
    #expect(SessionLink.resolve(url, in: ambiguous, at: returnEpoch) == .failure(.ambiguousSession))
    store.perform(.ignore, for: returnReference(event), at: returnEpoch)
    #expect(SessionLink.resolve(url, in: store.snapshot(at: returnEpoch), at: returnEpoch) == .failure(.sessionUnavailable))
    var history = SessionStore(); try history.receive([returnEvent(phase: .completed)])
    let cached = history.snapshot(at: returnEpoch)
    #expect(SessionLink.resolve(url, in: cached, at: returnEpoch.addingTimeInterval(86400)) == .failure(.sessionUnavailable))
    let invalid = try #require(URL(string: "tide-island://session?id=fixture-private#invalid"))
    #expect(SessionLink.resolve(invalid, in: visible, at: returnEpoch) == .failure(.invalidLink))
    #expect(!SessionLinkError.invalidLink.message.contains("fixture-private"))
}

@Test func applicationReturnDistinguishesLaunchAndActivationRequestsWithoutClaimingFocus() async throws {
    for state in [WaveApplicationState.notRunning, .running] {
        let fixture = try ReturnFixture(), driver = ReturnApplicationDriver(state: state)
        let result = await fixture.coordinator(driver: driver).returnToWave(for: fixture.reference)
        let calls = await driver.calls
        #expect(result.outcome == .applicationRequested && result.applicationState == state)
        #expect(result.navigation?.reason == .locationMissing && result.attemptedRoutes == [.application])
        #expect(calls == ["state", "open"] && result.message?.contains("确认目标会话") == true)
        #expect(result.message?.contains(state == .notRunning ? "启动" : "返回") == true)
    }
}

@Test func applicationReturnDoesNotOpenAnUninstalledApplication() async throws {
    let fixture = try ReturnFixture(), driver = ReturnApplicationDriver(state: .notInstalled)
    let result = await fixture.coordinator(driver: driver).returnToWave(for: fixture.reference)
    let calls = await driver.calls
    #expect(result.outcome == .notInstalled && result.attemptedRoutes.isEmpty && !result.applicationAttempted)
    #expect(calls == ["state"] && result.message?.contains("未找到 Wave") == true)
}

@Test func applicationReturnRetainsAttemptsWhenInstallationDisappearsOrOpenFails() async throws {
    let cases: [(WaveApplicationResponse, WaveReturnOutcome)] = [(.unavailable, .notInstalled), (.failed, .openFailed)]
    for (response, outcome) in cases {
        let fixture = try ReturnFixture(), driver = ReturnApplicationDriver(response: response)
        let result = await fixture.coordinator(driver: driver).returnToWave(for: fixture.reference)
        let calls = await driver.calls
        #expect(result.outcome == outcome && result.attemptedRoutes == [.application])
        #expect(result.applicationAttempted && calls == ["state", "open"])
    }
}

@Test func applicationReturnSanitizesLauncherErrorsAndReleasesItsGate() async throws {
    for failure in [ReturnDriverFailure.state, .open] {
        let fixture = try ReturnFixture(), driver = ReturnApplicationDriver(failure: failure)
        let coordinator = fixture.coordinator(driver: driver)
        let result = await coordinator.returnToWave(for: fixture.reference)
        let again = await coordinator.returnToWave(for: fixture.reference)
        #expect(result.outcome == .openFailed && again.outcome != .busy)
        #expect(result.applicationAttempted == (failure == .open))
        #expect(!String(describing: result).contains("fixture-private") && !((result.message ?? "").contains("fixture-private")))
    }
}

@Test func applicationReturnRejectsOldRowsBeforeTouchingTheLauncher() async throws {
    let fixture = try ReturnFixture(), driver = ReturnApplicationDriver()
    let stale = SessionReference(sessionID: "session", eventID: UUID())
    let result = await fixture.coordinator(driver: driver).returnToWave(for: stale)
    let calls = await driver.calls
    #expect(result.outcome == .staleSelection && result.navigation == nil && result.attemptedRoutes.isEmpty)
    #expect(calls.isEmpty)
}

@Test func applicationReturnRechecksTheLinkedObservationAfterTheApplicationProbe() async throws {
    let fixture = try ReturnFixture()
    let driver = ReturnApplicationDriver(afterState: { try? await fixture.state.receive(returnEvent(time: 1)) })
    let result = await fixture.coordinator(driver: driver).returnToWave(for: fixture.reference)
    let calls = await driver.calls
    #expect(result.outcome == .staleSelection && result.attemptedRoutes.isEmpty && calls == ["state"])
}

@Test func applicationReturnCanFallBackWithAnUnconfirmedSourceOrExpiredMapping() async throws {
    for uncertainSource in [false, true] {
        let location = WaveLocation(blockID: returnBlock, tabID: returnTab, waveVersion: "0.14.5",
                                    observedAt: returnEpoch.addingTimeInterval(-400), source: .environment)
        let fixture = try ReturnFixture(location: location), driver = ReturnApplicationDriver()
        if uncertainSource { await fixture.state.loseSource() }
        let result = await fixture.coordinator(driver: driver).returnToWave(for: fixture.reference)
        #expect(result.outcome == .applicationRequested && result.attemptedRoutes == [.application])
        #expect(result.navigation?.reason == (uncertainSource ? .sourceUnconfirmed : .locationExpired))
    }
}

@Test func applicationReturnActivatesTheAppEvenAfterOnlyALayoutFocusAcknowledgement() async throws {
    for response in [WaveFocusResponse.acknowledged, .rejected] {
        let location = WaveLocation(blockID: returnBlock, tabID: returnTab, waveVersion: "0.14.5", observedAt: returnEpoch, source: .environment)
        let fixture = try ReturnFixture(location: location), driver = ReturnApplicationDriver()
        let focus = ReturnFocusDriver(response: response)
        let navigator = WaveNavigationCoordinator(driver: focus, snapshot: { await fixture.snapshot() }, now: { returnEpoch })
        let result = await fixture.coordinator(driver: driver, navigator: navigator).returnToWave(for: fixture.reference)
        #expect(result.outcome == .applicationRequested && result.attemptedRoutes == [.tabLayoutFocus, .application])
        #expect(result.navigation?.outcome == (response == .acknowledged ? .focusAcknowledged : .applicationFallbackRequired))
    }
}

@Test func applicationReturnNeverRunsAnAppFallbackAfterNavigationCancellation() async throws {
    let location = WaveLocation(blockID: returnBlock, tabID: returnTab, waveVersion: "0.14.5", observedAt: returnEpoch, source: .environment)
    let fixture = try ReturnFixture(location: location), driver = ReturnApplicationDriver()
    let focus = ReturnFocusDriver(cancelled: true)
    let navigator = WaveNavigationCoordinator(driver: focus, snapshot: { await fixture.snapshot() }, now: { returnEpoch })
    let result = await fixture.coordinator(driver: driver, navigator: navigator).returnToWave(for: fixture.reference)
    let calls = await driver.calls
    #expect(result.outcome == .cancelled && result.attemptedRoutes.isEmpty && result.message == nil && calls.isEmpty)
}

@Test func applicationReturnRejectsConcurrentClicksWithoutQueuingLaunches() async throws {
    let fixture = try ReturnFixture(), gate = ReturnGate()
    let driver = ReturnApplicationDriver(stateGate: gate), coordinator = fixture.coordinator(driver: driver)
    let first = Task { await coordinator.returnToWave(for: fixture.reference) }
    try await returnWaitForEntry(gate.entries)
    let busy = await coordinator.returnToWave(for: fixture.reference)
    #expect(busy.outcome == .busy && busy.attemptedRoutes.isEmpty)
    await gate.open()
    let completed = await first.value
    let calls = await driver.calls
    #expect(completed.outcome == .applicationRequested && calls == ["state", "open"])
    let later = await coordinator.returnToWave(for: fixture.reference)
    #expect(later.outcome == .applicationRequested)
}

@Test func applicationReturnCancellationDuringTheProbePreventsOpening() async throws {
    let fixture = try ReturnFixture(), gate = ReturnGate()
    let driver = ReturnApplicationDriver(stateGate: gate), coordinator = fixture.coordinator(driver: driver)
    let pending = Task { await coordinator.returnToWave(for: fixture.reference) }
    try await returnWaitForEntry(gate.entries)
    pending.cancel(); await gate.open()
    let result = await pending.value
    let calls = await driver.calls
    #expect(result.outcome == .cancelled && result.attemptedRoutes.isEmpty && calls == ["state"])
}

@Test func applicationReturnCancellationAfterOpeningRetainsTheActualAttempt() async throws {
    let fixture = try ReturnFixture(), gate = ReturnGate()
    let driver = ReturnApplicationDriver(openGate: gate), coordinator = fixture.coordinator(driver: driver)
    let pending = Task { await coordinator.returnToWave(for: fixture.reference) }
    try await returnWaitForEntry(gate.entries)
    pending.cancel(); await gate.open()
    let result = await pending.value
    #expect(result.outcome == .cancelled && result.attemptedRoutes == [.application] && result.applicationAttempted)
    #expect(result.message == nil)
}

private func returnEvent(time: TimeInterval = 0, phase: AgentPhase = .working, location: WaveLocation? = nil) -> AgentEvent {
    let at = returnEpoch.addingTimeInterval(time)
    return AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: phase, occurredAt: at,
                      waveLocation: location, context: EventContext(source: .manual, kind: .status, receivedAt: at))
}

private func returnReference(_ event: AgentEvent) -> SessionReference { .init(sessionID: event.sessionID, eventID: event.id) }

private struct ReturnFixture: Sendable {
    let state: ReturnState
    let reference: SessionReference
    init(location: WaveLocation? = nil) throws {
        let event = returnEvent(location: location)
        var store = SessionStore(); try store.receive([event])
        state = ReturnState(store: store); reference = returnReference(event)
    }
    func snapshot() async -> SessionSnapshot { await state.snapshot() }
    func coordinator(driver: any WaveApplicationDriver, navigator: WaveNavigationCoordinator? = nil) -> WaveReturnCoordinator {
        WaveReturnCoordinator(driver: driver, navigator: navigator, snapshot: { await self.snapshot() }, now: { returnEpoch })
    }
}

private actor ReturnState {
    var store: SessionStore
    var issue: SessionSourceIssue?
    init(store: SessionStore) { self.store = store }
    func snapshot() -> SessionSnapshot { store.snapshot(at: returnEpoch, sourceIssue: issue) }
    func receive(_ event: AgentEvent) throws { try store.receive([event]) }
    func loseSource() { issue = .channelUnavailable }
}

private enum ReturnDriverFailure: Sendable { case none, state, open }
private enum ReturnTestError: Error, CustomStringConvertible {
    case failed
    var description: String { "fixture-private-launch-error" }
}

private actor ReturnApplicationDriver: WaveApplicationDriver {
    var calls: [String] = []
    let applicationState: WaveApplicationState
    let response: WaveApplicationResponse
    let failure: ReturnDriverFailure
    let afterState: @Sendable () async -> Void
    let stateGate: ReturnGate?
    let openGate: ReturnGate?
    init(state: WaveApplicationState = .running, response: WaveApplicationResponse = .accepted,
         failure: ReturnDriverFailure = .none, afterState: @escaping @Sendable () async -> Void = {},
         stateGate: ReturnGate? = nil, openGate: ReturnGate? = nil) {
        applicationState = state; self.response = response; self.failure = failure
        self.afterState = afterState; self.stateGate = stateGate; self.openGate = openGate
    }
    func state() async throws -> WaveApplicationState {
        calls.append("state")
        if failure == .state { throw ReturnTestError.failed }
        await stateGate?.hold(); await afterState()
        return applicationState
    }
    func open() async throws -> WaveApplicationResponse {
        calls.append("open")
        if failure == .open { throw ReturnTestError.failed }
        await openGate?.hold()
        return response
    }
}

private actor ReturnFocusDriver: WaveNavigationDriver {
    let response: WaveFocusResponse
    let cancelled: Bool
    init(response: WaveFocusResponse = .acknowledged, cancelled: Bool = false) { self.response = response; self.cancelled = cancelled }
    func context() async throws -> WaveNavigationContext? {
        if cancelled { throw CancellationError() }
        return WaveNavigationContext(connectionID: returnConnection, tabID: returnTab, waveVersion: "0.14.5", observedAt: returnEpoch)
    }
    func lookup(_ request: WaveFocusRequest, context: WaveNavigationContext) async throws -> WaveTargetObservation? {
        let target = WaveLocation(blockID: returnBlock, tabID: returnTab, workspaceID: UUID(), waveVersion: "0.14.5",
                                  observedAt: returnEpoch, source: .blockListing)
        return WaveTargetObservation(connectionID: returnConnection, location: target)
    }
    func focus(_ request: WaveFocusRequest, context: WaveNavigationContext) async throws -> WaveFocusResponse { response }
}

private actor ReturnGate {
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

private func returnWaitForEntry(_ entries: AsyncStream<Void>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in entries { return }; throw CancellationError() }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw ReturnTestError.failed }
        defer { group.cancelAll() }
        _ = try await group.next()
    }
}
