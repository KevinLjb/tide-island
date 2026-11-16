import Foundation

public enum WaveFocusResponse: Sendable {
    case acknowledged, rejected, timedOut, unavailable
}

/// A trusted, explicitly supplied runtime boundary, not an environment parser.
/// Implementations must authenticate with Wave, pin the helper/version and tab
/// to one connection generation, bound IO and cancel it on task cancellation.
/// focus must atomically refuse changed/expired context before sending. It must
/// never rewrite TABID to target a different tab, guess a block or retry another.
/// No production wsh/relay implementation is installed by this shared module.
public protocol WaveNavigationDriver: Sendable {
    func context() async throws -> WaveNavigationContext?
    func lookup(_ request: WaveFocusRequest, context: WaveNavigationContext) async throws -> WaveTargetObservation?
    func focus(_ request: WaveFocusRequest, context: WaveNavigationContext) async throws -> WaveFocusResponse
}

/// Serializes navigation attempts while allowing actor reentrancy to reject a
/// concurrent click. A blocked/failed attempt never automatically steals focus
/// via an app fallback; the caller separately handles that explicit result.
public actor WaveNavigationCoordinator {
    private let driver: (any WaveNavigationDriver)?
    private let snapshot: @Sendable () async -> SessionSnapshot
    private let now: @Sendable () -> Date
    private let policy = WaveNavigationPolicy.standard
    private var running = false

    public init(driver: (any WaveNavigationDriver)? = nil,
                snapshot: @escaping @Sendable () async -> SessionSnapshot,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.driver = driver
        self.snapshot = snapshot
        self.now = now
    }

    public func navigate(to reference: SessionReference) async -> WaveNavigationResult {
        guard !Task.isCancelled else { return result(reference, .cancelled, .cancelled) }
        guard !running else { return result(reference, .busy, .busy) }
        running = true
        defer { running = false }
        var attempted: WaveNavigationRoute = .none
        do {
            let initial = await snapshot()
            guard !Task.isCancelled else { return result(reference, .cancelled, .cancelled) }
            // Reject unavailable metadata without touching a driver. A missing
            // context is the only reason to continue with runtime discovery.
            let initialPlan = policy.plan(for: reference, in: initial, context: nil, at: now())
            if initialPlan != .applicationFallback(.contextUnavailable) { return finish(initialPlan, reference: reference) }
            guard let driver else { return fallback(reference, .contextUnavailable) }
            let originalContext = try await driver.context()
            guard !Task.isCancelled else { return result(reference, .cancelled, .cancelled) }
            let current = await snapshot()
            guard !Task.isCancelled else { return result(reference, .cancelled, .cancelled) }
            let plan = policy.plan(for: reference, in: current, context: originalContext, at: now())
            guard case .verifyTarget(let request) = plan, let originalContext else { return finish(plan, reference: reference) }
            let target = try await driver.lookup(request, context: originalContext)
            guard !Task.isCancelled else { return result(reference, .cancelled, .cancelled) }
            let confirmedContext = try await driver.context()
            guard !Task.isCancelled else { return result(reference, .cancelled, .cancelled) }
            // Obtain the latest observation after every driver await that can
            // precede dispatch. Never reuse the row or a preflight clock.
            let latest = await snapshot()
            guard !Task.isCancelled else { return result(reference, .cancelled, .cancelled) }
            let actionTime = now()
            let confirmedPlan = policy.plan(for: reference, in: latest, context: confirmedContext, at: actionTime)
            guard case .verifyTarget(let confirmedRequest) = confirmedPlan, let confirmedContext else {
                return finish(confirmedPlan, reference: reference)
            }
            guard confirmedRequest == request else { return fallback(reference, .contextChanged) }
            if let issue = policy.targetIssue(target, for: request, at: actionTime) { return fallback(reference, issue) }
            attempted = .tabLayoutFocus
            let response = try await driver.focus(request, context: confirmedContext)
            guard !Task.isCancelled else { return result(reference, .cancelled, .cancelled, attempted: attempted) }
            switch response {
            case .acknowledged: return result(reference, .focusAcknowledged, nil, attempted: attempted)
            case .rejected: return fallback(reference, .focusRejected, attempted: attempted)
            case .timedOut: return fallback(reference, .focusTimedOut, attempted: attempted)
            case .unavailable: return fallback(reference, .driverUnavailable, attempted: attempted)
            }
        } catch is CancellationError {
            return result(reference, .cancelled, .cancelled, attempted: attempted)
        } catch {
            // Never export arbitrary driver errors, raw stdout/stderr or auth
            // data. A lost response may have applied: there is no blind retry.
            if Task.isCancelled { return result(reference, .cancelled, .cancelled, attempted: attempted) }
            return fallback(reference, .driverFailure, attempted: attempted)
        }
    }

    private func finish(_ plan: WaveNavigationPlan, reference: SessionReference) -> WaveNavigationResult {
        switch plan {
        case .rejected(let issue): result(reference, .rejected, issue)
        case .applicationFallback(let issue): fallback(reference, issue)
        case .verifyTarget: fallback(reference, .targetUnconfirmed)
        }
    }

    private func fallback(_ reference: SessionReference, _ reason: WaveNavigationReason,
                          attempted: WaveNavigationRoute = .none) -> WaveNavigationResult {
        result(reference, .applicationFallbackRequired, reason, attempted: attempted)
    }

    private func result(_ reference: SessionReference, _ outcome: WaveNavigationOutcome,
                        _ reason: WaveNavigationReason?, attempted: WaveNavigationRoute = .none) -> WaveNavigationResult {
        WaveNavigationResult(reference: reference, attemptedRoute: attempted, outcome: outcome, reason: reason)
    }
}
