import Foundation

public enum WaveNavigationRoute: String, Sendable {
    case none, tabLayoutFocus, application
}

public enum WaveNavigationReason: String, Sendable {
    case staleSelection, sourceUnconfirmed, locationMissing, legacyLocation, partialLocation
    case locationExpired, clockSkew, unreviewedVersion
    case contextUnavailable, contextExpired, contextChanged, differentTabUnsupported
    case targetUnconfirmed, targetConflict, targetExpired
    case focusRejected, focusTimedOut, driverUnavailable, driverFailure, cancelled, busy
}

/// Ephemeral metadata from an already authenticated driver connection. Merely
/// reading WAVETERM_TABID or finding a JWT must never construct this evidence.
/// connectionID identifies that driver's connection generation, not a token.
public struct WaveNavigationContext: Equatable, Sendable {
    public let connectionID: UUID
    public let tabID: UUID
    public let waveVersion: String
    public let observedAt: Date

    public init(connectionID: UUID, tabID: UUID, waveVersion: String, observedAt: Date) {
        self.connectionID = connectionID
        self.tabID = tabID
        self.waveVersion = waveVersion
        self.observedAt = observedAt
    }
}

/// A complete, unambiguous list result obtained on the supplied connection.
/// Use WaveBlockListing for CLI output; absent/partial output stays nil.
public struct WaveTargetObservation: Equatable, Sendable {
    public let connectionID: UUID
    public let location: WaveLocation

    public init(connectionID: UUID, location: WaveLocation) {
        self.connectionID = connectionID
        self.location = location
    }
}

public struct WaveFocusRequest: Equatable, Sendable {
    public let reference: SessionReference
    public let location: WaveLocation
    public let connectionID: UUID

    /// Pass as an argument array to an approved helper, never through a shell.
    /// This full ORef bypasses shorthand resolution; it supplies no credentials.
    public var arguments: [String] { ["focusblock", "-b", "block:\(location.blockID.uuidString)"] }
    public let rpcTimeout: TimeInterval = 2

    fileprivate init(reference: SessionReference, location: WaveLocation, connectionID: UUID) {
        self.reference = reference
        self.location = location
        self.connectionID = connectionID
    }
}

public enum WaveNavigationPlan: Equatable, Sendable {
    case rejected(WaveNavigationReason)
    case applicationFallback(WaveNavigationReason)
    case verifyTarget(WaveFocusRequest)
}

public enum WaveNavigationOutcome: String, Sendable {
    case applicationFallbackRequired, focusAcknowledged, rejected, cancelled, busy
}

/// Records the route actually attempted. A fallback recommendation does not
/// claim the app was activated, nor does an acknowledgement prove visible focus.
public struct WaveNavigationResult: Equatable, Sendable {
    public let reference: SessionReference
    public let attemptedRoute: WaveNavigationRoute
    public let outcome: WaveNavigationOutcome
    public let reason: WaveNavigationReason?

    public var fallbackRoute: WaveNavigationRoute? {
        outcome == .applicationFallbackRequired ? .application : nil
    }
}

public struct WaveNavigationPolicy: Sendable {
    public static let standard = WaveNavigationPolicy()
    public let evidenceValidFor: TimeInterval = 10

    public init() {}

    public func plan(for reference: SessionReference, in snapshot: SessionSnapshot,
                     context: WaveNavigationContext?, at now: Date) -> WaveNavigationPlan {
        let matches = snapshot.sessions.filter { $0.id == reference.sessionID }
        guard matches.count == 1, let status = matches.first, status.reference == reference,
              !status.attention.isIgnored, status.freshness != .expired,
              status.expiresAt.map({ now < $0 }) != false else { return .rejected(.staleSelection) }
        guard status.sourceIssue == nil else { return .applicationFallback(.sourceUnconfirmed) }
        // Recompute against the action clock even if a caller supplied a cached
        // snapshot. Preference changes and old projections cannot renew a map.
        let validity = WaveLocationPolicy.standard.status(for: status.session.waveLocation,
                                                          legacyBlockID: status.session.waveBlockID, at: now).validity
        switch validity {
        case .unknown: return .applicationFallback(.locationMissing)
        case .legacyOnly: return .applicationFallback(.legacyLocation)
        case .partial: return .applicationFallback(.partialLocation)
        case .stale: return .applicationFallback(.locationExpired)
        case .clockSkew: return .applicationFallback(.clockSkew)
        case .unreviewedWaveVersion: return .applicationFallback(.unreviewedVersion)
        case .unconfirmedSource: return .applicationFallback(.sourceUnconfirmed)
        case .recent: break
        }
        guard let location = status.session.waveLocation else { return .applicationFallback(.locationMissing) }
        guard let context else { return .applicationFallback(.contextUnavailable) }
        guard context.waveVersion == WaveLocation.reviewedWaveVersion else { return .applicationFallback(.unreviewedVersion) }
        guard isRecent(context.observedAt, at: now) else { return .applicationFallback(.contextExpired) }
        guard location.tabID == context.tabID else { return .applicationFallback(.differentTabUnsupported) }
        return .verifyTarget(WaveFocusRequest(reference: reference, location: location, connectionID: context.connectionID))
    }

    public func targetIssue(_ observation: WaveTargetObservation?, for request: WaveFocusRequest,
                            at now: Date) -> WaveNavigationReason? {
        guard let observation else { return .targetUnconfirmed }
        let target = observation.location
        guard (try? target.validate()) != nil, target.source == .blockListing,
              target.tabID != nil, target.workspaceID != nil,
              target.waveVersion == WaveLocation.reviewedWaveVersion else { return .targetUnconfirmed }
        guard observation.connectionID == request.connectionID,
              target.blockID == request.location.blockID, target.tabID == request.location.tabID,
              request.location.workspaceID.map({ $0 == target.workspaceID }) != false,
              request.location.windowID.map({ $0 == target.windowID }) != false else { return .targetConflict }
        guard isRecent(target.observedAt, at: now) else { return .targetExpired }
        return nil
    }

    private func isRecent(_ time: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(time)
        return age.isFinite && age >= 0 && age < evidenceValidFor
    }
}
