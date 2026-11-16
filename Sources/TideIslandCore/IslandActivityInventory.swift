import Foundation

/// Application scope requires the caller's current primary-receiver authority.
/// A client must never return handles owned by another running instance.
public enum IslandActivityScope: Equatable, Sendable {
    case ownedOnly, application
}

public enum IslandActivityState: Equatable, Sendable {
    case active, stale, ended, dismissed, unknown
}

/// Public SDK metadata only. Unknown or malformed inventories are left intact.
public struct IslandActivityRecord: Sendable {
    public let identifier: String
    public let state: IslandActivityState
    public let content: IslandActivityContent
    public let staleAt: Date?

    public init(identifier: String, state: IslandActivityState, content: IslandActivityContent, staleAt: Date?) {
        self.identifier = identifier; self.state = state; self.content = content; self.staleAt = staleAt
    }

    var isLive: Bool { state == .active || state == .stale }

    static func validate(_ records: [Self]) throws {
        guard records.count <= 64, Set(records.map(\.identifier)).count == records.count else {
            throw IslandActivityError.invalidInventory
        }
        for record in records {
            guard validIdentifier(record.identifier), record.state != .unknown,
                  record.staleAt.map({ $0.timeIntervalSince1970.isFinite }) != false else {
                throw IslandActivityError.invalidInventory
            }
            do { try IslandActivityPresentationPolicy.standard.validate(record.content) }
            catch { throw IslandActivityError.invalidInventory }
        }
    }

    static func validIdentifier(_ identifier: String) -> Bool {
        !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && identifier.utf8.count <= 1024 &&
            !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
