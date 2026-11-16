import Foundation

/// Each event has its own atomically written file, so concurrent CLI processes
/// never interleave JSON. The inbox contains metadata only, not chat transcripts.
public struct EventInbox: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func applicationDefault() throws -> EventInbox {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return EventInbox(directory: support.appendingPathComponent("TideIsland/Events", isDirectory: true))
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    @discardableResult
    public func write(_ event: AgentEvent) throws -> URL {
        let data = try EventCodec.encode(event)
        try prepare()
        let destination = directory.appendingPathComponent(event.id.uuidString + ".json")
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    public func readRecent(limit: Int = 256) throws -> InboxBatch {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return InboxBatch(events: [], rejectedFiles: 0)
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ).compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "json",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }.prefix(max(0, limit))

        var events: [AgentEvent] = []
        var rejected = 0
        for (url, _) in candidates {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= EventCodec.maximumBytes else { throw EventError.oversizedEvent }
                events.append(try EventCodec.decode(Data(contentsOf: url)))
            } catch {
                rejected += 1
            }
        }
        return InboxBatch(events: events.reversed().sorted { $0.occurredAt < $1.occurredAt }, rejectedFiles: rejected)
    }
}

public struct InboxBatch: Sendable {
    public let events: [AgentEvent]
    public let rejectedFiles: Int
}
