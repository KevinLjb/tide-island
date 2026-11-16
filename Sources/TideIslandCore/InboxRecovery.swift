import Darwin
import Foundation

public enum InboxRecoveryReason: String, Encodable, Hashable, Sendable {
    case invalidCleanupIntent
    case cleanupConflict
    case unsafeStagingFile
    case invalidStagingEvent
    case conflictingEvent
    case operationFailed
}

public struct InboxRecoveryIssue: Encodable, Sendable {
    public let fileName: String
    public let reason: InboxRecoveryReason
}

/// Diagnostics contain only TideIsland filenames and reason codes, never bytes
/// from a rejected file. Recovery only completes previously started operations.
public struct InboxRecoveryReport: Encodable, Sendable {
    public internal(set) var pendingCleanupFiles = 0
    public internal(set) var resumedCleanupFiles = 0
    public internal(set) var resumedCleanupBytes: Int64 = 0
    public internal(set) var interruptedStages = 0
    public internal(set) var recoveredEvents = 0
    public internal(set) var removedStages = 0
    public internal(set) var issues: [InboxRecoveryIssue] = []
}

struct InboxCleanupIntent: Codable {
    struct Entry: Codable {
        let name: String
        let stamp: InboxFileStamp
        let digest: String
    }
    let version: Int
    let directoryIdentity: String
    let approvedFingerprint: String
    let entries: [Entry]
}

extension EventInbox {
    public func inspectRecovery(limits: InboxReadLimits = InboxReadLimits()) throws -> InboxRecoveryReport {
        try recovery(apply: false, limits: limits)
    }

    /// Completes valid staged writes and an already-approved cleanup intent.
    /// Conflicting, partial, unknown or linked files are preserved for review.
    public func recoverInterruptedOperations(limits: InboxReadLimits = InboxReadLimits()) throws -> InboxRecoveryReport {
        try recovery(apply: true, limits: limits)
    }

    private func recovery(apply: Bool, limits: InboxReadLimits) throws -> InboxRecoveryReport {
        let directory = try InboxDirectory(url: self.directory, create: false, requireMarker: true)
        return try directory.locked(exclusive: apply) {
            var report = try directory.recoverCleanup(apply: apply, maximumBytes: Int(limits.maximumReadBytes))
            // A partial historical chain must not be imported or interleaved
            // with recovered writes until its approved cleanup is resolved.
            guard report.issues.isEmpty else { return report }
            var readBytes: Int64 = 0
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() {
                guard name.hasPrefix(".tide-island-"), name.hasSuffix(".tmp"),
                      UUID(uuidString: String(name.dropFirst(13).dropLast(4))) != nil else { continue }
                report.interruptedStages += 1
                guard report.interruptedStages <= limits.maximumFiles else { throw InboxError.limitExceeded }
                var info = stat()
                guard fstatat(directory.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw InboxError.changedDuringRead
                }
                let stamp = InboxFileStamp(info)
                guard stamp.mode & UInt32(S_IFMT) == UInt32(S_IFREG), stamp.owner == geteuid(),
                      stamp.links == 1 || stamp.links == 2 else {
                    report.issues.append(.init(fileName: name, reason: .unsafeStagingFile)); continue
                }
                guard stamp.size > 0, stamp.size <= EventCodec.maximumBytes else {
                    report.issues.append(.init(fileName: name, reason: .invalidStagingEvent)); continue
                }
                readBytes += stamp.size
                guard readBytes <= limits.maximumReadBytes else { throw InboxError.limitExceeded }
                let data = try directory.readData(name, stamp: stamp, maximumBytes: EventCodec.maximumBytes)
                guard let event = try? EventCodec.decode(data) else {
                    report.issues.append(.init(fileName: name, reason: .invalidStagingEvent)); continue
                }
                let destination = event.id.uuidString + ".json"
                var finalInfo = stat()
                let exists = fstatat(directory.descriptor, destination, &finalInfo, AT_SYMLINK_NOFOLLOW) == 0
                if !exists, errno != ENOENT { throw InboxError.fileOperation }
                if exists {
                    let final = InboxFileStamp(finalInfo)
                    let sameFile = final.identity == stamp.identity && stamp.links == 2
                    guard sameFile || (stamp.links == 1 && final.isOwnedRegularFile),
                          try directory.readData(destination, stamp: final, maximumBytes: EventCodec.maximumBytes) == data else {
                        report.issues.append(.init(fileName: name, reason: .conflictingEvent)); continue
                    }
                } else if stamp.links != 1 {
                    report.issues.append(.init(fileName: name, reason: .unsafeStagingFile)); continue
                }
                guard apply else { continue }
                try directory.verifyPath()
                if !exists {
                    guard linkat(directory.descriptor, name, directory.descriptor, destination, 0) == 0 else {
                        report.issues.append(.init(fileName: name, reason: .operationFailed)); continue
                    }
                    report.recoveredEvents += 1
                }
                if unlinkat(directory.descriptor, name, 0) == 0 { report.removedStages += 1 }
                else { report.issues.append(.init(fileName: name, reason: .operationFailed)) }
            }
            try directory.verifyPath()
            return report
        }
    }
}

extension InboxDirectory {
    static let cleanupIntentName = ".tide-island-cleanup.json"
    private static let maximumIntentBytes = 32 * 1024 * 1024

    func requireNoCleanupIntent() throws {
        var info = stat()
        if fstatat(descriptor, Self.cleanupIntentName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw InboxError.recoveryRequired
        }
        guard errno == ENOENT else { throw InboxError.fileOperation }
    }

    func createCleanupIntent(_ plan: InboxCleanupPlan, files: [String: InboxIndexedFile]) throws {
        guard !plan.removals.isEmpty else { return }
        try requireNoCleanupIntent()
        let entries = try plan.removals.map { removal -> InboxCleanupIntent.Entry in
            guard let file = files[removal.fileName], let digest = file.digest, file.event != nil else {
                throw InboxError.stalePlan
            }
            return .init(name: file.name, stamp: file.stamp, digest: digest)
        }
        let intent = InboxCleanupIntent(version: 1, directoryIdentity: identity,
                                        approvedFingerprint: plan.fingerprint, entries: entries)
        let data = try JSONEncoder().encode(intent)
        guard data.count <= Self.maximumIntentBytes else { throw InboxError.limitExceeded }
        let staging = ".tide-island-cleanup-" + UUID().uuidString + ".tmp"
        let fd = openat(descriptor, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InboxError.fileOperation }
        defer { close(fd); unlinkat(descriptor, staging, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try verifyPath()
        guard linkat(descriptor, staging, descriptor, Self.cleanupIntentName, 0) == 0 else { throw InboxError.fileOperation }
    }

    func recoverCleanup(apply: Bool, maximumBytes: Int = 64 * 1024 * 1024) throws -> InboxRecoveryReport {
        var report = InboxRecoveryReport()
        var info = stat()
        guard fstatat(descriptor, Self.cleanupIntentName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard errno == ENOENT else { throw InboxError.fileOperation }
            return report
        }
        let stamp = InboxFileStamp(info)
        // A crash after publishing the intent can leave its staging hard link.
        // Accept two links only when the other is our exact intent draft below.
        let owned = stamp.mode & UInt32(S_IFMT) == UInt32(S_IFREG) && stamp.owner == geteuid()
        guard owned, stamp.links == 1 || stamp.links == 2, stamp.size > 0 else {
            report.issues.append(.init(fileName: Self.cleanupIntentName, reason: .invalidCleanupIntent)); return report
        }
        guard stamp.size <= min(Self.maximumIntentBytes, maximumBytes) else { throw InboxError.limitExceeded }
        let data = try readData(Self.cleanupIntentName, stamp: stamp, maximumBytes: min(Self.maximumIntentBytes, maximumBytes))
        guard let intent = try? JSONDecoder().decode(InboxCleanupIntent.self, from: data),
              intent.version == 1, intent.directoryIdentity == identity,
              !intent.entries.isEmpty, intent.entries.count <= 65_536,
              Set(intent.entries.map(\.name)).count == intent.entries.count,
              intent.approvedFingerprint.count == 64,
              intent.entries.allSatisfy({ entry in
                  entry.name.hasSuffix(".json") && UUID(uuidString: String(entry.name.dropLast(5))) != nil
                      && entry.stamp.isOwnedRegularFile && entry.stamp.size <= EventCodec.maximumBytes
                      && entry.digest.count == 64 && entry.digest.allSatisfy { $0.isHexDigit }
              }) else {
            report.issues.append(.init(fileName: Self.cleanupIntentName, reason: .invalidCleanupIntent)); return report
        }
        var drafts: [String] = []
        if stamp.links == 2 {
            drafts = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { name in
                guard name.hasPrefix(".tide-island-cleanup-"), name.hasSuffix(".tmp"),
                      UUID(uuidString: String(name.dropFirst(21).dropLast(4))) != nil else { return false }
                var draft = stat()
                return fstatat(descriptor, name, &draft, AT_SYMLINK_NOFOLLOW) == 0 && InboxFileStamp(draft).identity == stamp.identity
            }
            guard drafts.count == 1 else {
                report.issues.append(.init(fileName: Self.cleanupIntentName, reason: .invalidCleanupIntent)); return report
            }
        }
        var remaining: [InboxCleanupIntent.Entry] = []
        var readBytes = data.count
        for entry in intent.entries {
            var current = stat()
            if fstatat(descriptor, entry.name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw InboxError.fileOperation
            }
            readBytes += Int(entry.stamp.size)
            guard readBytes <= maximumBytes else { throw InboxError.limitExceeded }
            guard InboxFileStamp(current) == entry.stamp else {
                report.issues.append(.init(fileName: entry.name, reason: .cleanupConflict)); continue
            }
            let bytes = try readData(entry.name, stamp: entry.stamp, maximumBytes: EventCodec.maximumBytes)
            guard Self.hash(bytes) == entry.digest else {
                report.issues.append(.init(fileName: entry.name, reason: .cleanupConflict)); continue
            }
            remaining.append(entry)
        }
        report.pendingCleanupFiles = remaining.count
        guard apply, report.issues.isEmpty else { return report }
        try verifyPath()
        for entry in remaining {
            if unlinkat(descriptor, entry.name, 0) == 0 {
                report.resumedCleanupFiles += 1
                report.resumedCleanupBytes += entry.stamp.size
            }
            else { report.issues.append(.init(fileName: entry.name, reason: .operationFailed)) }
        }
        if report.issues.isEmpty {
            // Remove a leftover intent draft before removing the stable name.
            for draft in drafts {
                guard unlinkat(descriptor, draft, 0) == 0 else { throw InboxError.fileOperation }
            }
            guard unlinkat(descriptor, Self.cleanupIntentName, 0) == 0 else { throw InboxError.fileOperation }
            report.pendingCleanupFiles = 0
        }
        try verifyPath()
        return report
    }
}
