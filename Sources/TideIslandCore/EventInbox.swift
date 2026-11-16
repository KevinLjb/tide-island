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
        _ = try InboxDirectory(url: directory, create: true, requireMarker: true)
    }

    @discardableResult
    public func write(_ event: AgentEvent) throws -> URL {
        let data = try EventCodec.encode(event)
        let files = try InboxDirectory(url: directory, create: true, requireMarker: true)
        try files.write(data, id: event.id)
        let destination = directory.appendingPathComponent(event.id.uuidString + ".json")
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

        var events: [(event: AgentEvent, publishedAt: Date)] = []
        var rejected = 0
        for (url, publishedAt) in candidates {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= EventCodec.maximumBytes else { throw EventError.oversizedEvent }
                events.append((try EventCodec.decode(Data(contentsOf: url)), publishedAt))
            } catch {
                rejected += 1
            }
        }
        let ordered = events.sorted {
            if $0.event.occurredAt != $1.event.occurredAt { return $0.event.occurredAt < $1.event.occurredAt }
            if $0.publishedAt != $1.publishedAt { return $0.publishedAt < $1.publishedAt }
            return $0.event.id.uuidString < $1.event.id.uuidString
        }
        return InboxBatch(events: ordered.map(\.event), rejectedFiles: rejected)
    }
}

public struct InboxBatch: Sendable {
    public let events: [AgentEvent]
    public let rejectedFiles: Int
}
