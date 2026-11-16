import Darwin
import Foundation

public struct SessionStateInspection: Encodable, Sendable {
    public let exists: Bool
    public let version: Int?
    public let sessions: Int
    public let preferences: Int
    public let importedFiles: Int
    public let revision: String
}

public struct SessionResetPreview: Encodable, Sendable {
    public let fingerprint: String
    public let eventFiles: Int
    let scope: String

    private enum CodingKeys: String, CodingKey { case fingerprint, eventFiles }
}

/// Only allowlisted metadata is serialized. A valid state file is bound to one
/// inbox path; neither corrupt nor future data is silently replaced on load.
public struct SessionStateFile: Sendable {
    public let inbox: EventInbox
    public let directory: URL

    public init(inbox: EventInbox, directory: URL? = nil) {
        self.inbox = inbox
        self.directory = directory ?? inbox.directory.deletingLastPathComponent().appendingPathComponent("State")
    }

    var scope: String { InboxDirectory.hash(Data(inbox.directory.standardizedFileURL.path.utf8)) }
    public var fileURL: URL { directory.appendingPathComponent(scope + ".json") }

    public func load() throws -> SessionStateSnapshot {
        let raw = try readBytes()
        let revision = revision(raw)
        guard let raw else {
            return SessionStateSnapshot(store: SessionStore(), revision: revision, existed: false, importIndex: [:])
        }
        let decoded = try SessionCheckpointCodec.decode(raw.data, scope: scope)
        return SessionStateSnapshot(store: decoded.store, revision: revision, existed: true, importIndex: decoded.index)
    }

    public func inspect() throws -> SessionStateInspection {
        let snapshot = try load()
        return SessionStateInspection(exists: snapshot.existed, version: snapshot.existed ? 1 : nil,
                                      sessions: snapshot.store.sessionCount, preferences: snapshot.store.preferenceCount,
                                      importedFiles: snapshot.importIndex.count, revision: snapshot.revision.fingerprint)
    }

    /// Offline maintenance must retain the observed terminal/turn protection
    /// before removing its source files. An active app uses its own receiver.
    public func applyCleanup(_ plan: InboxCleanupPlan, expectedFingerprint: String,
                             limits: InboxReadLimits = InboxReadLimits()) throws -> InboxCleanupResult {
        guard expectedFingerprint == plan.fingerprint, plan.inboxPath == inbox.directory.standardizedFileURL.path else {
            throw InboxError.stalePlan
        }
        let lease = try InboxConsumerLease(inbox: inbox.directory)
        try lease.verifyPath()
        let current = try inbox.previewCleanup(policy: plan.policy, at: plan.evaluatedAt, limits: limits)
        guard current.fingerprint == plan.fingerprint else { throw InboxError.stalePlan }
        let restored = try load()
        var cursor = InboxCursor()
        let update = try inbox.readIncrementally(using: &cursor, limits: limits)
        var store = restored.store
        try store.receive(cursor.unimportedEvents(update.events, index: restored.importIndex))
        _ = try save(store, index: cursor.importIndex, expected: restored.revision)
        let result = try inbox.applyCleanup(plan, expectedFingerprint: expectedFingerprint, limits: limits)
        try lease.verifyPath()
        return result
    }

    func save(_ store: SessionStore, index: [String: String], expected: SessionStateRevision) throws -> SessionStateRevision {
        let data = try SessionCheckpointCodec.encode(store: store, index: index, scope: scope)
        let files = try SessionStateDirectory(url: directory, create: true)
        return try files.locked {
            let current = try files.read(fileURL.lastPathComponent)
            guard revision(current) == expected else { throw SessionStateError.conflict }
            if current?.data == data { return expected }
            try files.publish(data, name: fileURL.lastPathComponent)
            let published = try files.read(fileURL.lastPathComponent)
            guard published?.data == data else { throw SessionStateError.conflict }
            return revision(published)
        }
    }

    /// Preview does not create a state folder, marker, lock or checkpoint.
    public func previewReset(limits: InboxReadLimits = InboxReadLimits()) throws -> SessionResetPreview {
        try withResetInventory(limits: limits) { directory, inventory in
            let expected = revision(try readBytes())
            return try resetPreview(directory: directory, cursor: inventory.cursor,
                             count: inventory.update.scannedFiles + inventory.update.skippedFiles,
                             stateRevision: expected)
        }
    }

    /// Standalone CLI mutation needs the same consumer lease as the app.
    @discardableResult
    public func applyReset(_ preview: SessionResetPreview, expectedFingerprint: String,
                           limits: InboxReadLimits = InboxReadLimits()) throws -> SessionStateInspection {
        guard preview.scope == scope, preview.fingerprint == expectedFingerprint else { throw SessionStateError.conflict }
        let lease = try InboxConsumerLease(inbox: inbox.directory)
        try lease.verifyPath()
        _ = try resetWhileReceiving(preview, expectedFingerprint: expectedFingerprint, limits: limits)
        try lease.verifyPath()
        return try inspect()
    }

    func resetWhileReceiving(_ preview: SessionResetPreview, expectedFingerprint: String,
                             limits: InboxReadLimits) throws -> (snapshot: SessionStateSnapshot, cursor: InboxCursor) {
        guard preview.scope == scope, preview.fingerprint == expectedFingerprint else { throw SessionStateError.conflict }
        return try withResetInventory(limits: limits) { directory, inventory in
            let expected = revision(try readBytes())
            let current = try resetPreview(directory: directory, cursor: inventory.cursor,
                                           count: inventory.update.scannedFiles + inventory.update.skippedFiles,
                                           stateRevision: expected)
            guard current.fingerprint == preview.fingerprint else { throw SessionStateError.conflict }
            // Capture the cleared import boundary in the very same atomic file
            // as the empty store; old inbox files must not resurrect the rows.
            let store = SessionStore()
            let index = inventory.cursor.importIndex
            let saved = try save(store, index: index, expected: expected)
            return (SessionStateSnapshot(store: store, revision: saved, existed: true, importIndex: index), inventory.cursor)
        }
    }

    private func withResetInventory<T>(limits: InboxReadLimits,
                                        _ body: (InboxDirectory, (cursor: InboxCursor, update: InboxUpdate)) throws -> T) throws -> T {
        let directory = try InboxDirectory(url: inbox.directory, create: false, requireMarker: true)
        return try directory.locked(exclusive: false) {
            try directory.requireNoCleanupIntent()
            let inventory = try inbox.scan(directory, previous: InboxCursor(), limits: limits)
            try directory.verifyPath()
            let result = try body(directory, inventory)
            try directory.verifyPath()
            return result
        }
    }

    private func resetPreview(directory: InboxDirectory, cursor: InboxCursor, count: Int,
                              stateRevision: SessionStateRevision) throws -> SessionResetPreview {
        struct Entry: Encodable {
            let name: String
            let stamp: InboxFileStamp
            let digest: String?
        }
        struct Fingerprint: Encodable {
            let scope: String
            let directory: String
            let stateRevision: String
            let candidateFiles: Int
            let files: [Entry]
        }
        let fingerprint = Fingerprint(scope: scope, directory: directory.identity,
                                      stateRevision: stateRevision.fingerprint, candidateFiles: count,
                                      files: cursor.files.values.sorted { $0.name < $1.name }.map {
                                          Entry(name: $0.name, stamp: $0.stamp, digest: $0.digest)
                                      })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SessionResetPreview(fingerprint: InboxDirectory.hash(try encoder.encode(fingerprint)), eventFiles: count, scope: scope)
    }

    private func readBytes() throws -> SessionStateBytes? {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw SessionStateError.unsafePath }
            return nil
        }
        return try SessionStateDirectory(url: directory, create: false).read(fileURL.lastPathComponent)
    }

    private func revision(_ raw: SessionStateBytes?) -> SessionStateRevision {
        guard let raw else { return SessionStateRevision(fingerprint: InboxDirectory.hash(Data((scope + ":absent").utf8))) }
        let stamp = raw.stamp
        let fields = [scope, stamp.identity, String(stamp.size), String(stamp.modifiedSeconds),
                      String(stamp.modifiedNanoseconds), String(stamp.changedSeconds), String(stamp.changedNanoseconds),
                      String(stamp.mode), String(stamp.owner), String(stamp.links), InboxDirectory.hash(raw.data)]
        return SessionStateRevision(fingerprint: InboxDirectory.hash(Data(fields.joined(separator: ":").utf8)))
    }
}
