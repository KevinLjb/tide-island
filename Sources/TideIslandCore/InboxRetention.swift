import Darwin
import Foundation

public struct InboxRetentionPolicy: Encodable, Sendable {
    public let maximumAge: TimeInterval
    public let maximumFiles: Int
    public let maximumBytes: Int64

    public init() {
        maximumAge = 7 * 24 * 60 * 60
        maximumFiles = 4096
        maximumBytes = 32 * 1024 * 1024
    }

    public init(maximumAge: TimeInterval, maximumFiles: Int, maximumBytes: Int64) throws {
        guard maximumAge.isFinite, maximumAge > 0, maximumAge <= 10 * 365 * 24 * 60 * 60,
              maximumFiles > 0, maximumBytes > 0 else { throw InboxError.invalidPolicy }
        self.maximumAge = maximumAge
        self.maximumFiles = maximumFiles
        self.maximumBytes = maximumBytes
    }
}

public struct InboxRemoval: Encodable, Sendable {
    public enum Reason: String, Encodable, Sendable { case age, capacity }
    public let fileName: String
    public let bytes: Int64
    public let reason: Reason
}

public struct InboxCleanupPlan: Encodable, Sendable {
    public let inboxPath: String
    public let evaluatedAt: Date
    public let policy: InboxRetentionPolicy
    public let fingerprint: String
    public let totalFiles: Int
    public let totalBytes: Int64
    public let protectedFiles: Int
    public let rejectedFiles: Int
    public let skippedFiles: Int
    public let removals: [InboxRemoval]
    public let remainingFiles: Int
    public let remainingBytes: Int64
    public let targetsMetAfterCleanup: Bool
}

public struct InboxCleanupResult: Encodable, Sendable {
    public let removedFiles: Int
    public let removedBytes: Int64
    public let failedFiles: [String]
    public let remainingFiles: Int
    public let remainingBytes: Int64
    public let targetsMet: Bool
}

extension EventInbox {
    /// Read-only: no directory, marker, lock file, backup or configuration is
    /// created. Unknown files and uncertain session histories are never removed.
    public func previewCleanup(policy: InboxRetentionPolicy = InboxRetentionPolicy(), at now: Date,
                               limits: InboxReadLimits = InboxReadLimits()) throws -> InboxCleanupPlan {
        let directory = try InboxDirectory(url: self.directory, create: false, requireMarker: true)
        return try directory.locked(exclusive: false) {
            let inventory = try scan(directory, previous: InboxCursor(), limits: limits)
            return try cleanupPlan(directory, inventory: inventory, policy: policy, at: now)
        }
    }

    /// The reviewed inventory and proposals must still match. Our writers use
    /// the same marker lock. Uncoordinated editors must not alter files during
    /// apply; POSIX unlink cannot compare-and-swap an external editor's content.
    public func applyCleanup(_ plan: InboxCleanupPlan, expectedFingerprint: String,
                             limits: InboxReadLimits = InboxReadLimits()) throws -> InboxCleanupResult {
        guard plan.inboxPath == self.directory.standardizedFileURL.path,
              expectedFingerprint == plan.fingerprint else { throw InboxError.stalePlan }
        let directory = try InboxDirectory(url: self.directory, create: false, requireMarker: true)
        return try directory.locked(exclusive: true) {
            let inventory = try scan(directory, previous: InboxCursor(), limits: limits)
            let current = try cleanupPlan(directory, inventory: inventory, policy: plan.policy, at: plan.evaluatedAt)
            guard current.fingerprint == plan.fingerprint else { throw InboxError.stalePlan }
            for removal in current.removals {
                var info = stat()
                guard let expected = inventory.cursor.files[removal.fileName],
                      fstatat(directory.descriptor, removal.fileName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      InboxFileStamp(info) == expected.stamp else { throw InboxError.stalePlan }
            }
            try directory.verifyPath()
            var removed = 0
            var bytes: Int64 = 0
            var failed: [String] = []
            for removal in current.removals {
                if unlinkat(directory.descriptor, removal.fileName, 0) == 0 {
                    removed += 1
                    bytes += removal.bytes
                } else { failed.append(removal.fileName) }
            }
            let remainingFiles = current.totalFiles - removed
            let remainingBytes = current.totalBytes - bytes
            return InboxCleanupResult(removedFiles: removed, removedBytes: bytes, failedFiles: failed,
                                      remainingFiles: remainingFiles, remainingBytes: remainingBytes,
                                      targetsMet: remainingFiles <= plan.policy.maximumFiles && remainingBytes <= plan.policy.maximumBytes)
        }
    }

    private func cleanupPlan(_ directory: InboxDirectory, inventory: (cursor: InboxCursor, update: InboxUpdate),
                             policy: InboxRetentionPolicy, at now: Date) throws -> InboxCleanupPlan {
        guard now.timeIntervalSince1970.isFinite else { throw InboxError.invalidPolicy }
        let ordered = Self.ordered(Array(inventory.cursor.files.values))
        var registry = SessionRegistry()
        var uncertain: Set<String> = []
        var groups: [String: [InboxIndexedFile]] = [:]
        for file in ordered {
            guard let event = file.event else { continue }
            groups[event.sessionID, default: []].append(file)
            let decision = try registry.applyResult(event)
            if decision == .unknownTurn || ((decision == .sessionEnded || decision == .missingTurn)
                && (event.phase == .working || event.phase == .needsInput)) {
                uncertain.insert(event.sessionID)
            }
        }
        struct Group {
            let id: String
            let latest: Date
            let files: [InboxIndexedFile]
        }
        var eligible: [Group] = []
        var protected = 0
        let statusPolicy = SessionStatusPolicy.standard
        for session in registry.sessions {
            let files = groups[session.id]!
            let latest = files.compactMap { $0.event?.occurredAt }.max()!
            let age = now.timeIntervalSince(latest)
            // Keep the entire chain, including parallel tools, retired turns
            // and unbound evidence, whenever recovery could still need it.
            if uncertain.contains(session.id) || !age.isFinite || age < statusPolicy.idleRetention
                || statusPolicy.status(for: session, at: now).freshness != .expired {
                protected += files.count
            } else { eligible.append(Group(id: session.id, latest: latest, files: files)) }
        }
        eligible.sort { $0.latest == $1.latest ? $0.id < $1.id : $0.latest < $1.latest }
        var remainingFiles = inventory.update.scannedFiles
        var remainingBytes = inventory.update.totalBytes
        var removals: [InboxRemoval] = []
        for group in eligible {
            let expiredByAge = now.timeIntervalSince(group.latest) >= policy.maximumAge
            guard expiredByAge || remainingFiles > policy.maximumFiles || remainingBytes > policy.maximumBytes else { continue }
            for file in group.files {
                removals.append(InboxRemoval(fileName: file.name, bytes: file.stamp.size, reason: expiredByAge ? .age : .capacity))
                remainingFiles -= 1
                remainingBytes -= file.stamp.size
            }
        }
        removals.sort { $0.fileName < $1.fileName }
        struct FileFingerprint: Encodable {
            let name: String
            let stamp: InboxFileStamp
            let digest: String?
        }
        struct Fingerprint: Encodable {
            let path: String
            let identity: String
            let policy: InboxRetentionPolicy
            let files: [FileFingerprint]
            let removals: [InboxRemoval]
        }
        let source = Fingerprint(path: directory.url.path, identity: directory.identity, policy: policy,
                                 files: inventory.cursor.files.values.sorted { $0.name < $1.name }.map {
                                     FileFingerprint(name: $0.name, stamp: $0.stamp, digest: $0.digest)
                                 }, removals: removals)
        let fingerprint = InboxDirectory.hash(try EventCodec.jsonEncoder().encode(source))
        return InboxCleanupPlan(inboxPath: directory.url.path, evaluatedAt: now, policy: policy, fingerprint: fingerprint,
                                totalFiles: inventory.update.scannedFiles, totalBytes: inventory.update.totalBytes,
                                protectedFiles: protected, rejectedFiles: inventory.update.rejectedFiles,
                                skippedFiles: inventory.update.skippedFiles, removals: removals,
                                remainingFiles: remainingFiles, remainingBytes: remainingBytes,
                                targetsMetAfterCleanup: remainingFiles <= policy.maximumFiles && remainingBytes <= policy.maximumBytes)
    }
}
