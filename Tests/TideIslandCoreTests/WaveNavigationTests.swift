import Foundation
import Testing
@testable import TideIslandCore

private let navigationEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private let navigationBlock = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
private let navigationTab = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
private let navigationWorkspace = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
private let navigationConnection = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!

@Test func navigationMetadataFailuresNeverProduceAFocusCandidate() throws {
    let cases: [(WaveLocation?, String?, WaveNavigationReason)] = [
        (nil, nil, .locationMissing), (nil, "block-1", .legacyLocation),
        (navigationLocation(tab: nil), nil, .partialLocation),
        (navigationLocation(version: nil), nil, .partialLocation),
        (navigationLocation(version: "0.14.6"), nil, .unreviewedVersion),
        (navigationLocation(time: -300), nil, .locationExpired),
        (navigationLocation(time: 1), nil, .clockSkew),
    ]
    for (location, legacy, reason) in cases {
        let event = navigationEvent(location: location, legacy: legacy)
        var store = SessionStore(); try store.receive([event])
        let plan = WaveNavigationPolicy.standard.plan(for: .init(sessionID: event.sessionID, eventID: event.id),
                                                     in: store.snapshot(at: navigationEpoch), context: navigationContext(), at: navigationEpoch)
        #expect(plan == .applicationFallback(reason))
    }
}

@Test func navigationRejectsOldMissingIgnoredAndExpiredRowsInsteadOfOpeningAnotherSession() throws {
    let event = navigationEvent(), reference = navigationReference(event)
    var store = SessionStore(); try store.receive([event])
    let policy = WaveNavigationPolicy.standard
    let stale = SessionReference(sessionID: event.sessionID, eventID: UUID())
    #expect(policy.plan(for: stale, in: store.snapshot(at: navigationEpoch), context: navigationContext(), at: navigationEpoch) == .rejected(.staleSelection))
    let missing = SessionReference(sessionID: "other", eventID: event.id)
    #expect(policy.plan(for: missing, in: store.snapshot(at: navigationEpoch), context: navigationContext(), at: navigationEpoch) == .rejected(.staleSelection))
    store.perform(.ignore, for: reference, at: navigationEpoch)
    #expect(policy.plan(for: reference, in: store.snapshot(at: navigationEpoch), context: navigationContext(), at: navigationEpoch) == .rejected(.staleSelection))
    let terminal = navigationEvent(phase: .completed)
    var history = SessionStore(); try history.receive([terminal])
    let cached = history.snapshot(at: navigationEpoch)
    let expired = policy.plan(for: navigationReference(terminal), in: cached, context: navigationContext(),
                              at: navigationEpoch.addingTimeInterval(24 * 60 * 60))
    #expect(expired == .rejected(.staleSelection))
}

@Test func navigationSourceLossGatesEvenRecentLocationMetadata() throws {
    let event = navigationEvent()
    var store = SessionStore(); try store.receive([event])
    for snapshot in [store.snapshot(at: navigationEpoch, sourceIssue: .channelUnavailable),
                     store.snapshot(at: navigationEpoch, confirmedEvents: [:])] {
        let plan = WaveNavigationPolicy.standard.plan(for: navigationReference(event), in: snapshot,
                                                     context: navigationContext(), at: navigationEpoch)
        #expect(plan == .applicationFallback(.sourceUnconfirmed))
    }
}

@Test func navigationRequiresReviewedRecentAuthenticatedContextForTheSameTab() throws {
    let event = navigationEvent()
    var store = SessionStore(); try store.receive([event])
    let cases: [(WaveNavigationContext?, WaveNavigationReason)] = [
        (nil, .contextUnavailable), (navigationContext(version: "0.14.6"), .unreviewedVersion),
        (navigationContext(time: -10), .contextExpired), (navigationContext(time: 1), .contextExpired),
        (navigationContext(tab: UUID()), .differentTabUnsupported),
    ]
    for (context, reason) in cases {
        let plan = WaveNavigationPolicy.standard.plan(for: navigationReference(event), in: store.snapshot(at: navigationEpoch),
                                                     context: context, at: navigationEpoch)
        #expect(plan == .applicationFallback(reason))
    }
}

@Test func navigationBuildsOnlyAFullORefArgumentArrayAndNeverClaimsTabActivation() throws {
    let request = try navigationRequest()
    #expect(request.arguments == ["focusblock", "-b", "block:\(navigationBlock.uuidString)"])
    #expect(request.rpcTimeout == 2 && request.connectionID == navigationConnection)
    #expect(request.location.tabID == navigationTab)
    #expect(!request.arguments.contains("this") && !request.arguments.contains("--tab"))
}

@Test func navigationChecksEveryKnownTargetIdentityAndConnectionGeneration() throws {
    let expected = navigationLocation(workspace: navigationWorkspace)
    let request = try navigationRequest(location: expected)
    let locations = [navigationLocation(block: UUID(), workspace: navigationWorkspace, source: .blockListing),
                     navigationLocation(tab: UUID(), workspace: navigationWorkspace, source: .blockListing),
                     navigationLocation(workspace: UUID(), source: .blockListing)]
    for location in locations {
        let issue = WaveNavigationPolicy.standard.targetIssue(.init(connectionID: navigationConnection, location: location),
                                                              for: request, at: navigationEpoch)
        #expect(issue == .targetConflict)
    }
    let wrongConnection = WaveTargetObservation(connectionID: UUID(), location: navigationTarget().location)
    #expect(WaveNavigationPolicy.standard.targetIssue(wrongConnection, for: request, at: navigationEpoch) == .targetConflict)
    let withWindow = navigationLocation(workspace: navigationWorkspace, window: UUID())
    let windowRequest = try navigationRequest(location: withWindow)
    #expect(WaveNavigationPolicy.standard.targetIssue(navigationTarget(), for: windowRequest, at: navigationEpoch) == .targetConflict)
}

@Test func navigationRequiresCompleteFreshListingEvidenceRatherThanRecordedProvenance() throws {
    let request = try navigationRequest(), policy = WaveNavigationPolicy.standard
    let cases: [(WaveTargetObservation?, WaveNavigationReason)] = [
        (nil, .targetUnconfirmed),
        (.init(connectionID: navigationConnection, location: navigationLocation()), .targetUnconfirmed),
        (.init(connectionID: navigationConnection, location: navigationLocation(source: .blockListing)), .targetUnconfirmed),
        (navigationTarget(time: -10), .targetExpired), (navigationTarget(time: 1), .targetExpired),
        (.init(connectionID: navigationConnection, location: navigationLocation(workspace: navigationWorkspace, version: "0.14.6", source: .blockListing)), .targetUnconfirmed),
    ]
    for (observation, reason) in cases { #expect(policy.targetIssue(observation, for: request, at: navigationEpoch) == reason) }
    #expect(policy.targetIssue(navigationTarget(time: -9.999), for: request, at: navigationEpoch) == nil)
}

@Test func navigationUsesOnlyTheExactUniqueTargetFromTheStrictListingParser() throws {
    let row: [String: Any] = ["blockid": navigationBlock.uuidString, "tabid": navigationTab.uuidString,
                              "workspaceid": navigationWorkspace.uuidString, "meta": ["cwd": "fixture-private"]]
    var other = row; other["blockid"] = UUID().uuidString
    let request = try navigationRequest()
    let cases: [([[String: Any]], WaveNavigationReason?)] = [([other, row], nil), ([row, row], .targetUnconfirmed), ([other], .targetUnconfirmed)]
    for (rows, expected) in cases {
        let bytes = try JSONSerialization.data(withJSONObject: rows)
        let parsed = WaveBlockListing.location(stdout: bytes, stderr: Data(), exitCode: 0, blockID: request.location.blockID,
                                               expectedTabID: navigationTab, waveVersion: "0.14.5", observedAt: navigationEpoch)
        let evidence = parsed.map { WaveTargetObservation(connectionID: navigationConnection, location: $0) }
        let issue = WaveNavigationPolicy.standard.targetIssue(evidence, for: request, at: navigationEpoch)
        #expect(issue == expected)
    }
}

@Test func navigationDefaultsToAnExplicitApplicationFallbackWithoutARuntimeDriver() async throws {
    let fixture = try NavigationFixture()
    let coordinator = fixture.coordinator()
    let result = await coordinator.navigate(to: fixture.reference)
    #expect(result.outcome == .applicationFallbackRequired && result.reason == .contextUnavailable)
    #expect(result.attemptedRoute == .none && result.fallbackRoute == .application)
}

@Test func navigationAcknowledgesOnlyTheRequestedLayoutAndDoesNotModifySessionState() async throws {
    let fixture = try NavigationFixture(phase: .completed)
    let driver = NavigationDriver()
    let before = await fixture.snapshot()
    let result = await fixture.coordinator(driver: driver).navigate(to: fixture.reference)
    let calls = await driver.calls, requests = await driver.requests
    let after = await fixture.snapshot()
    #expect(result.reference == fixture.reference && result.outcome == .focusAcknowledged)
    #expect(result.attemptedRoute == .tabLayoutFocus && result.fallbackRoute == nil)
    #expect(calls == ["context", "lookup", "context", "focus"] && requests.count == 1)
    #expect(requests.first?.location.blockID == navigationBlock && before == after)
}

@Test func navigationSkipsTheDriverWhenMetadataOrTheClickedRowIsUnavailable() async throws {
    let fixture = try NavigationFixture(location: nil)
    let driver = NavigationDriver()
    let coordinator = fixture.coordinator(driver: driver)
    let absent = await coordinator.navigate(to: fixture.reference)
    let stale = await coordinator.navigate(to: .init(sessionID: "missing", eventID: UUID()))
    let calls = await driver.calls
    #expect(absent.reason == .locationMissing && stale.outcome == .rejected && stale.fallbackRoute == nil)
    #expect(calls.isEmpty)
}

@Test func navigationCannotQueryOrFocusWithoutAnAuthenticatedDriverContext() async throws {
    let fixture = try NavigationFixture()
    let driver = NavigationDriver(contexts: [nil])
    let result = await fixture.coordinator(driver: driver).navigate(to: fixture.reference)
    let calls = await driver.calls
    #expect(result.reason == .contextUnavailable && result.attemptedRoute == .none)
    #expect(calls == ["context"])
}

@Test func navigationMissingOrConflictingPreflightNeverSelectsAnotherBlock() async throws {
    for target in [nil, WaveTargetObservation(connectionID: navigationConnection,
                                             location: navigationLocation(block: UUID(), workspace: navigationWorkspace, source: .blockListing))] {
        let fixture = try NavigationFixture()
        let driver = NavigationDriver(target: target)
        let result = await fixture.coordinator(driver: driver).navigate(to: fixture.reference)
        let requests = await driver.requests
        #expect(result.reason == (target == nil ? .targetUnconfirmed : .targetConflict))
        #expect(result.attemptedRoute == .none && requests.isEmpty)
    }
}

@Test func navigationRechecksTheExactSessionAfterTheLookupAwait() async throws {
    let fixture = try NavigationFixture()
    let newer = navigationEvent(time: 1, location: navigationLocation(block: UUID()))
    let driver = NavigationDriver(afterLookup: { try? await fixture.state.receive(newer) })
    let result = await fixture.coordinator(driver: driver).navigate(to: fixture.reference)
    let requests = await driver.requests
    #expect(result.outcome == .rejected && result.reason == .staleSelection)
    #expect(result.fallbackRoute == nil && requests.isEmpty)
}

@Test func navigationRechecksChannelConfirmationAfterTheLookupAwait() async throws {
    let fixture = try NavigationFixture()
    let driver = NavigationDriver(afterLookup: { await fixture.state.loseSource() })
    let result = await fixture.coordinator(driver: driver).navigate(to: fixture.reference)
    let requests = await driver.requests
    #expect(result.reason == .sourceUnconfirmed && requests.isEmpty)
}

@Test func navigationRefusesChangedConnectionsAndTabsBeforeDispatch() async throws {
    let cases: [(WaveNavigationContext?, WaveNavigationReason)] = [
        (navigationContext(connection: UUID()), .contextChanged),
        (navigationContext(tab: UUID()), .differentTabUnsupported),
        (nil, .contextUnavailable),
    ]
    for (changed, reason) in cases {
        let fixture = try NavigationFixture()
        let driver = NavigationDriver(contexts: [navigationContext(), changed])
        let result = await fixture.coordinator(driver: driver).navigate(to: fixture.reference)
        let requests = await driver.requests
        #expect(result.reason == reason && requests.isEmpty)
    }
}

@Test func navigationRecomputesLocationAndPreflightDeadlinesAtDispatchTime() async throws {
    let delays: [TimeInterval] = [10, 300]
    for delay in delays {
        let fixture = try NavigationFixture()
        let driver = NavigationDriver(contexts: [navigationContext(), navigationContext(time: delay)],
                                      afterLookup: { fixture.clock.set(navigationEpoch.addingTimeInterval(delay)) })
        let result = await fixture.coordinator(driver: driver).navigate(to: fixture.reference)
        let requests = await driver.requests
        #expect(result.reason == (delay == 10 ? .targetExpired : .locationExpired))
        #expect(result.attemptedRoute == .none && requests.isEmpty)
    }
}

@Test func navigationReportsActualAttemptedRouteForFailuresAndNeverBlindlyRetries() async throws {
    let cases: [(WaveFocusResponse, WaveNavigationReason)] = [(.rejected, .focusRejected), (.timedOut, .focusTimedOut), (.unavailable, .driverUnavailable)]
    for (response, reason) in cases {
        let fixture = try NavigationFixture()
        let driver = NavigationDriver(response: response)
        let result = await fixture.coordinator(driver: driver).navigate(to: fixture.reference)
        let calls = await driver.calls, requests = await driver.requests
        #expect(result.outcome == .applicationFallbackRequired && result.reason == reason)
        #expect(result.attemptedRoute == .tabLayoutFocus && result.fallbackRoute == .application)
        #expect(calls.filter { $0 == "lookup" }.count == 1 && requests.count == 1)
    }
}

@Test func navigationSanitizesDriverErrorsAndRetainsTheAttemptedRoute() async throws {
    for stage in [NavigationFailure.context, .lookup, .focus] {
        let fixture = try NavigationFixture()
        let driver = NavigationDriver(failure: stage)
        let coordinator = fixture.coordinator(driver: driver)
        let result = await coordinator.navigate(to: fixture.reference)
        #expect(result.reason == .driverFailure && result.attemptedRoute == (stage == .focus ? .tabLayoutFocus : .none))
        #expect(!String(describing: result).contains("fixture-private"))
        let retry = await coordinator.navigate(to: fixture.reference)
        #expect(retry.outcome != .busy)
    }
}

@Test func navigationRejectsConcurrentClicksAndReleasesItsGateAfterCompletion() async throws {
    let fixture = try NavigationFixture(), gate = NavigationGate()
    let driver = NavigationDriver(lookupGate: gate)
    let coordinator = fixture.coordinator(driver: driver)
    let first = Task { await coordinator.navigate(to: fixture.reference) }
    try await navigationWaitForEntry(gate.entries)
    let concurrent = await coordinator.navigate(to: fixture.reference)
    #expect(concurrent.outcome == .busy && concurrent.attemptedRoute == .none && concurrent.fallbackRoute == nil)
    await gate.open()
    let completed = await first.value
    #expect(completed.outcome == .focusAcknowledged)
    let next = await coordinator.navigate(to: fixture.reference)
    #expect(next.outcome == .focusAcknowledged)
}

@Test func navigationCancellationDuringLookupPreventsDispatchAndFallback() async throws {
    let fixture = try NavigationFixture(), gate = NavigationGate()
    let driver = NavigationDriver(lookupGate: gate)
    let coordinator = fixture.coordinator(driver: driver)
    let request = Task { await coordinator.navigate(to: fixture.reference) }
    try await navigationWaitForEntry(gate.entries)
    request.cancel(); await gate.open()
    let result = await request.value
    let requests = await driver.requests
    #expect(result.outcome == .cancelled && result.attemptedRoute == .none && result.fallbackRoute == nil)
    #expect(requests.isEmpty)
}

@Test func navigationCancellationAfterDispatchDoesNotClaimThatFocusWasUndone() async throws {
    let fixture = try NavigationFixture(), gate = NavigationGate()
    let driver = NavigationDriver(focusGate: gate)
    let coordinator = fixture.coordinator(driver: driver)
    let request = Task { await coordinator.navigate(to: fixture.reference) }
    try await navigationWaitForEntry(gate.entries)
    request.cancel(); await gate.open()
    let result = await request.value
    let requests = await driver.requests
    #expect(result.outcome == .cancelled && result.attemptedRoute == .tabLayoutFocus && result.fallbackRoute == nil)
    #expect(requests.count == 1)
}

private func navigationLocation(block: UUID = navigationBlock, tab: UUID? = navigationTab, workspace: UUID? = nil,
                                window: UUID? = nil, version: String? = "0.14.5", time: TimeInterval = 0,
                                source: WaveLocationSource = .environment) -> WaveLocation {
    WaveLocation(blockID: block, tabID: tab, workspaceID: workspace, windowID: window, waveVersion: version,
                 observedAt: navigationEpoch.addingTimeInterval(time), source: source)
}

private func navigationContext(connection: UUID = navigationConnection, tab: UUID = navigationTab,
                               version: String = "0.14.5", time: TimeInterval = 0) -> WaveNavigationContext {
    WaveNavigationContext(connectionID: connection, tabID: tab, waveVersion: version, observedAt: navigationEpoch.addingTimeInterval(time))
}

private func navigationTarget(time: TimeInterval = 0) -> WaveTargetObservation {
    WaveTargetObservation(connectionID: navigationConnection,
                           location: navigationLocation(workspace: navigationWorkspace, time: time, source: .blockListing))
}

private func navigationEvent(time: TimeInterval = 0, phase: AgentPhase = .working, location: WaveLocation? = navigationLocation(),
                             legacy: String? = nil) -> AgentEvent {
    let at = navigationEpoch.addingTimeInterval(time)
    return AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: phase, occurredAt: at,
                      waveBlockID: legacy ?? location?.blockID.uuidString, waveLocation: location,
                      context: EventContext(source: .manual, kind: .status, receivedAt: at))
}

private func navigationReference(_ event: AgentEvent) -> SessionReference {
    SessionReference(sessionID: event.sessionID, eventID: event.id)
}

private func navigationRequest(location: WaveLocation = navigationLocation()) throws -> WaveFocusRequest {
    let event = navigationEvent(location: location)
    var store = SessionStore(); try store.receive([event])
    let plan = WaveNavigationPolicy.standard.plan(for: navigationReference(event), in: store.snapshot(at: navigationEpoch),
                                                 context: navigationContext(), at: navigationEpoch)
    guard case .verifyTarget(let request) = plan else { throw NavigationTestError.failed }
    return request
}

private struct NavigationFixture: Sendable {
    let state: NavigationState
    let clock = NavigationClock()
    let reference: SessionReference

    init(location: WaveLocation? = navigationLocation(), phase: AgentPhase = .working) throws {
        let event = navigationEvent(phase: phase, location: location)
        var store = SessionStore(); try store.receive([event])
        state = NavigationState(store: store)
        reference = navigationReference(event)
    }

    func snapshot() async -> SessionSnapshot { await state.snapshot(at: clock.read()) }
    func coordinator(driver: (any WaveNavigationDriver)? = nil) -> WaveNavigationCoordinator {
        WaveNavigationCoordinator(driver: driver, snapshot: { await self.snapshot() }, now: { self.clock.read() })
    }
}

private actor NavigationState {
    var store: SessionStore
    var issue: SessionSourceIssue?
    init(store: SessionStore) { self.store = store }
    func receive(_ event: AgentEvent) throws { try store.receive([event]) }
    func loseSource() { issue = .eventMissing }
    func snapshot(at now: Date) -> SessionSnapshot { store.snapshot(at: now, sourceIssue: issue) }
}

/// Mutable test clock; every read/write is protected by the same lock.
private final class NavigationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = navigationEpoch
    func read() -> Date { lock.withLock { time } }
    func set(_ date: Date) { lock.withLock { time = date } }
}

private enum NavigationFailure: Sendable { case none, context, lookup, focus }
private enum NavigationTestError: Error, CustomStringConvertible {
    case failed
    var description: String { "fixture-private-driver-error" }
}

private actor NavigationDriver: WaveNavigationDriver {
    var calls: [String] = []
    var requests: [WaveFocusRequest] = []
    let contexts: [WaveNavigationContext?]
    var contextIndex = 0
    let target: WaveTargetObservation?
    let response: WaveFocusResponse
    let failure: NavigationFailure
    let afterLookup: @Sendable () async -> Void
    let lookupGate: NavigationGate?
    let focusGate: NavigationGate?

    init(contexts: [WaveNavigationContext?] = [navigationContext()], target: WaveTargetObservation? = navigationTarget(),
         response: WaveFocusResponse = .acknowledged, failure: NavigationFailure = .none,
         afterLookup: @escaping @Sendable () async -> Void = {}, lookupGate: NavigationGate? = nil, focusGate: NavigationGate? = nil) {
        self.contexts = contexts; self.target = target; self.response = response; self.failure = failure
        self.afterLookup = afterLookup; self.lookupGate = lookupGate; self.focusGate = focusGate
    }

    func context() async throws -> WaveNavigationContext? {
        calls.append("context")
        if failure == .context { throw NavigationTestError.failed }
        guard !contexts.isEmpty else { return nil }
        defer { contextIndex += 1 }
        return contexts[min(contextIndex, contexts.count - 1)]
    }

    func lookup(_ request: WaveFocusRequest, context: WaveNavigationContext) async throws -> WaveTargetObservation? {
        calls.append("lookup")
        if failure == .lookup { throw NavigationTestError.failed }
        await lookupGate?.hold()
        await afterLookup()
        return target
    }

    func focus(_ request: WaveFocusRequest, context: WaveNavigationContext) async throws -> WaveFocusResponse {
        calls.append("focus"); requests.append(request)
        if failure == .focus { throw NavigationTestError.failed }
        await focusGate?.hold()
        return response
    }
}

private actor NavigationGate {
    nonisolated let entries: AsyncStream<Void>
    private let entry: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation

    init() {
        let entryPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        entries = entryPair.stream; entry = entryPair.continuation
        let releasePair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        releases = releasePair.stream; release = releasePair.continuation
    }
    func hold() async { entry.yield(()); for await _ in releases { break } }
    func open() { release.yield(()); release.finish() }
}

private func navigationWaitForEntry(_ entries: AsyncStream<Void>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in entries { return }; throw CancellationError() }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw NavigationTestError.failed }
        defer { group.cancelAll() }
        _ = try await group.next()
    }
}
