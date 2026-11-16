import Foundation

/// Provenance of ID metadata, never proof of authentication or visible focus.
public enum WaveLocationSource: String, Codable, Sendable {
    case environment
    case explicitArguments
    case blockListing
}

public struct WaveLocation: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let reviewedWaveVersion = "0.14.5"

    public let version: Int
    public let blockID: UUID
    public let tabID: UUID?
    public let workspaceID: UUID?
    public let windowID: UUID?
    public let waveVersion: String?
    public let observedAt: Date
    public let source: WaveLocationSource

    public init(version: Int = WaveLocation.currentVersion, blockID: UUID, tabID: UUID? = nil,
                workspaceID: UUID? = nil, windowID: UUID? = nil, waveVersion: String? = nil,
                observedAt: Date, source: WaveLocationSource) {
        self.version = version
        self.blockID = blockID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.waveVersion = waveVersion
        self.observedAt = observedAt
        self.source = source
    }

    public func validate(legacyBlockID: String? = nil) throws {
        guard version == Self.currentVersion, observedAt.timeIntervalSince1970.isFinite,
              waveVersion.map(Self.isVersion) != false,
              legacyBlockID.map({ Self.fullID($0) == blockID }) != false else {
            throw EventError.invalidField("waveLocation")
        }
    }

    static func fullID(_ value: String) -> UUID? {
        guard value.utf8.count == 36 else { return nil }
        return UUID(uuidString: value)
    }

    static func isVersion(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.range(
            of: #"\A(?:0|[1-9][0-9]{0,3})\.(?:0|[1-9][0-9]{0,3})\.(?:0|[1-9][0-9]{0,3})(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\z"#,
            options: .regularExpression
        ) != nil
    }
}

/// Pure allowlist capture; callers supply only these three environment values.
/// Explicit arguments form a separate group and never inherit environment IDs.
public struct WaveLocationCapture: Equatable, Sendable {
    public let waveBlockID: String?
    public let location: WaveLocation?

    public static func environment(_ values: [String: String], observedAt: Date) -> Self {
        guard let raw = values["WAVETERM_BLOCKID"], validLegacyBlock(raw) else {
            return Self(waveBlockID: nil, location: nil)
        }
        guard let block = WaveLocation.fullID(raw) else { return Self(waveBlockID: raw, location: nil) }
        let tab = values["WAVETERM_TABID"].flatMap(WaveLocation.fullID)
        let version = values["WAVETERM_VERSION"].flatMap { WaveLocation.isVersion($0) ? $0 : nil }
        let location = WaveLocation(blockID: block, tabID: tab, waveVersion: version,
                                    observedAt: observedAt, source: .environment)
        return Self(waveBlockID: raw, location: location)
    }

    public static func explicit(blockID: String?, tabID: String? = nil, waveVersion: String? = nil,
                                observedAt: Date) throws -> Self {
        guard let blockID, validLegacyBlock(blockID) else { throw EventError.invalidField("Wave location arguments") }
        guard let block = WaveLocation.fullID(blockID) else {
            guard tabID == nil, waveVersion == nil else { throw EventError.invalidField("Wave location arguments") }
            return Self(waveBlockID: blockID, location: nil)
        }
        let tab = tabID.flatMap(WaveLocation.fullID)
        guard tabID == nil || tab != nil, waveVersion.map(WaveLocation.isVersion) != false else {
            throw EventError.invalidField("Wave location arguments")
        }
        let location = WaveLocation(blockID: block, tabID: tab, waveVersion: waveVersion,
                                    observedAt: observedAt, source: .explicitArguments)
        try location.validate(legacyBlockID: blockID)
        return Self(waveBlockID: blockID, location: location)
    }

    private static func validLegacyBlock(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
