import Foundation

public enum WaveLocationValidity: String, Codable, Sendable {
    case unknown, legacyOnly, partial, recent, stale, clockSkew, unreviewedWaveVersion, unconfirmedSource
}

/// Validity of a metadata observation, independent of lifecycle or navigation.
public struct WaveLocationStatus: Equatable, Sendable {
    public let validity: WaveLocationValidity
    public let expiresAt: Date?
    public let nextTransitionAt: Date?

    func confirming(_ issue: SessionSourceIssue?) -> Self {
        guard issue != nil, validity != .unknown else { return self }
        return Self(validity: .unconfirmedSource, expiresAt: expiresAt, nextTransitionAt: nextTransitionAt)
    }
}

public struct WaveLocationPolicy: Sendable {
    public static let standard = WaveLocationPolicy()
    public let validFor: TimeInterval = 5 * 60

    public init() {}

    public func status(for location: WaveLocation?, legacyBlockID: String? = nil, at now: Date) -> WaveLocationStatus {
        guard let location else {
            return WaveLocationStatus(validity: legacyBlockID == nil ? .unknown : .legacyOnly,
                                      expiresAt: nil, nextTransitionAt: nil)
        }
        guard (try? location.validate(legacyBlockID: legacyBlockID)) != nil else {
            return WaveLocationStatus(validity: .unknown, expiresAt: nil, nextTransitionAt: nil)
        }
        let expiry = location.observedAt.addingTimeInterval(validFor)
        let age = now.timeIntervalSince(location.observedAt)
        let validity: WaveLocationValidity
        if !age.isFinite || age < 0 { validity = .clockSkew }
        else if now >= expiry { validity = .stale }
        else if let version = location.waveVersion, version != WaveLocation.reviewedWaveVersion {
            validity = .unreviewedWaveVersion
        } else if location.tabID == nil || location.waveVersion == nil { validity = .partial }
        else { validity = .recent }
        return WaveLocationStatus(validity: validity, expiresAt: expiry,
                                  nextTransitionAt: age >= 0 && now < expiry ? expiry : nil)
    }
}
