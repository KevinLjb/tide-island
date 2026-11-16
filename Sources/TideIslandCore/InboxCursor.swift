import Foundation

public struct InboxReadLimits: Sendable {
    public let maximumFiles: Int
    public let maximumReadBytes: Int64

    public init() { maximumFiles = 16_384; maximumReadBytes = 64 * 1024 * 1024 }

    public init(maximumFiles: Int, maximumReadBytes: Int64) throws {
        guard maximumFiles > 0, maximumFiles <= 65_536, maximumReadBytes > 0,
              maximumReadBytes <= 256 * 1024 * 1024 else { throw InboxError.invalidPolicy }
        self.maximumFiles = maximumFiles
        self.maximumReadBytes = maximumReadBytes
    }
}

public struct InboxCursor: Sendable {
    var directoryIdentity: String?
    var files: [String: InboxIndexedFile] = [:]
    public init() {}

    var importIndex: [String: String] {
        files.compactMapValues { file in file.event == nil ? nil : file.digest }
    }

    func unimportedEvents(_ events: [AgentEvent], index: [String: String]) -> [AgentEvent] {
        let imported = Set(files.values.compactMap { file -> UUID? in
            guard let digest = file.digest, digest == index[file.name] else { return nil }
            return file.event?.id
        })
        return events.filter { !imported.contains($0.id) }
    }

    var confirmedEvents: [UUID: AgentEvent] {
        Dictionary(grouping: files.values.compactMap(\.event), by: \.id).compactMapValues { events in
            guard let first = events.first, events.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
    }
}

public enum InboxRejectionReason: String, Codable, Hashable, Sendable {
    case malformed
    case unsupportedVersion
    case oversized
    case filenameMismatch
}

public struct InboxUpdate: Sendable {
    public let events: [AgentEvent]
    public let scannedFiles: Int
    public let changedFiles: Int
    public let decodedFiles: Int
    public let unchangedFiles: Int
    public let removedFiles: Int
    public let rejectedFiles: Int
    public let skippedFiles: Int
    public let totalBytes: Int64
    public let directoryChanged: Bool
    public let rejectionCounts: [InboxRejectionReason: Int]
}

extension EventInbox {
    /// Lists file metadata each time; reads and decodes only new or changed
    /// files. A failed scan leaves the caller's cursor completely unchanged.
    public func readIncrementally(using cursor: inout InboxCursor, limits: InboxReadLimits = InboxReadLimits()) throws -> InboxUpdate {
        let directory = try InboxDirectory(url: self.directory, create: false, requireMarker: false)
        return try directory.locked(exclusive: false) {
            try directory.requireNoCleanupIntent()
            let scanned = try scan(directory, previous: cursor, limits: limits)
            cursor = scanned.cursor
            return scanned.update
        }
    }

    func scan(_ directory: InboxDirectory, previous: InboxCursor, limits: InboxReadLimits) throws -> (cursor: InboxCursor, update: InboxUpdate) {
        let inventory = try directory.entries(maximumFiles: limits.maximumFiles)
        let sameDirectory = previous.directoryIdentity == directory.identity
        let cached = sameDirectory ? previous.files : [:]
        var next = InboxCursor()
        next.directoryIdentity = directory.identity
        var changed: [InboxIndexedFile] = []
        var decoded = 0, unchanged = 0
        var readBytes: Int64 = 0, totalBytes: Int64 = 0
        for (name, stamp) in inventory.files {
            let total = totalBytes.addingReportingOverflow(stamp.size)
            guard !total.overflow else { throw InboxError.limitExceeded }
            totalBytes = total.partialValue
            if let old = cached[name], old.stamp == stamp {
                next.files[name] = old
                unchanged += 1
            } else {
                if stamp.size <= Int64(EventCodec.maximumBytes) {
                    readBytes += stamp.size
                    guard readBytes <= limits.maximumReadBytes else { throw InboxError.limitExceeded }
                    decoded += 1
                }
                let file = try directory.read(name, stamp: stamp)
                next.files[name] = file
                changed.append(file)
            }
        }
        try directory.verifyPath()
        return (next, InboxUpdate(
            events: Self.ordered(changed).compactMap(\.event), scannedFiles: inventory.files.count,
            changedFiles: changed.count, decodedFiles: decoded, unchangedFiles: unchanged,
            removedFiles: sameDirectory ? cached.keys.filter { next.files[$0] == nil }.count : previous.files.count,
            rejectedFiles: next.files.values.filter { $0.event == nil }.count,
            skippedFiles: inventory.skipped, totalBytes: totalBytes,
            directoryChanged: previous.directoryIdentity != nil && !sameDirectory,
            rejectionCounts: next.files.values.reduce(into: [:]) { counts, file in
                if let reason = file.rejection { counts[reason, default: 0] += 1 }
            }
        ))
    }

    static func ordered(_ files: [InboxIndexedFile]) -> [InboxIndexedFile] {
        files.sorted {
            if $0.event?.occurredAt != $1.event?.occurredAt {
                return ($0.event?.occurredAt ?? .distantPast) < ($1.event?.occurredAt ?? .distantPast)
            }
            if $0.stamp.publishedAt != $1.stamp.publishedAt { return $0.stamp.publishedAt < $1.stamp.publishedAt }
            return $0.name < $1.name
        }
    }
}
