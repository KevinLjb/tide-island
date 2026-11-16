import Darwin
import Foundation

/// Explicit config.toml editing. Preview creates no files, locks or backups.
public struct NotifyConfigurationFile: Sendable {
    public let url: URL

    public init(url: URL) throws {
        try CodexHookConfiguration.validatePath(url.path)
        guard url.isFileURL, url.lastPathComponent == "config.toml" else { throw NotifyConfigurationError.invalidArguments }
        self.url = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent("config.toml")
    }

    public func preview(action: HookConfigurationAction, applicationURL: URL? = nil, inboxPath: String? = nil) throws -> NotifyConfigurationPlan {
        let bridge = try applicationURL.map { try BundledBridge.inspect(applicationURL: $0) }
        return try CodexNotifyConfiguration.plan(action: action, existing: read()?.data, configurationPath: url.path,
                                                 bundledBridge: bridge, inboxPath: inboxPath)
    }

    @discardableResult
    public func apply(_ plan: NotifyConfigurationPlan, expectedFingerprint: String, backupDirectory: URL) throws -> URL? {
        guard plan.configurationPath == url.path, plan.fingerprint == expectedFingerprint, try read()?.data == plan.originalData else {
            throw NotifyConfigurationError.stalePlan
        }
        try plan.bundledBridge?.verifyCurrent()
        guard plan.changesFile else { return nil }
        try CodexHookConfiguration.validatePath(backupDirectory.path)
        guard backupDirectory.isFileURL, let proposed = plan.proposedData else { throw NotifyConfigurationError.invalidArguments }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(directory.appendingPathComponent(".tide-island-notify.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw NotifyConfigurationError.unsafeFile }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == geteuid() else {
            throw NotifyConfigurationError.unsafeFile
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NotifyConfigurationError.busy }
        defer { flock(lock, LOCK_UN) }
        let snapshot = try read()
        guard snapshot?.data == plan.originalData else { throw NotifyConfigurationError.stalePlan }
        if let snapshot, snapshot.owner != geteuid() { throw NotifyConfigurationError.unsafeFile }
        try plan.bundledBridge?.verifyCurrent()
        let backup = backupDirectory.appendingPathComponent("tide-island-notify-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if let snapshot { try writeNew(snapshot.data, to: backup.appendingPathComponent("config.toml.before"), mode: 0o600) }
        var receipt: [String: Any] = ["version": 1, "kind": "before-change-backup", "config_path": url.path,
                                     "original_existed": snapshot != nil, "operation": plan.action.rawValue,
                                     "plan_fingerprint": plan.fingerprint]
        if let snapshot { receipt["original_permissions"] = Int(snapshot.mode) }
        else { receipt["original_permissions"] = NSNull() }
        let record = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
        try writeNew(record, to: backup.appendingPathComponent("receipt.json"), mode: 0o600)
        let staging = directory.appendingPathComponent(".tide-island-notify-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        try writeNew(proposed, to: staging, mode: snapshot?.mode ?? 0o600)
        let latest = try read()
        guard latest?.data == snapshot?.data, latest?.mode == snapshot?.mode, latest?.identity == snapshot?.identity else {
            throw NotifyConfigurationError.stalePlan
        }
        try plan.bundledBridge?.verifyCurrent()
        if snapshot == nil {
            guard link(staging.path, url.path) == 0 else {
                throw errno == EEXIST ? NotifyConfigurationError.stalePlan : .fileOperation
            }
        } else if rename(staging.path, url.path) != 0 { throw NotifyConfigurationError.fileOperation }
        return backup
    }

    private struct Snapshot {
        let data: Data
        let mode: mode_t
        let owner: uid_t
        let identity: String
    }

    private func read() throws -> Snapshot? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw NotifyConfigurationError.unsafeFile
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NotifyConfigurationError.unsafeFile }
        guard info.st_size >= 0, info.st_size <= CodexNotifyConfiguration.maximumBytes else { throw NotifyConfigurationError.limitExceeded }
        var data = Data()
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        while let part = try handle.read(upToCount: 64 * 1024), !part.isEmpty {
            data.append(part)
            guard data.count <= CodexNotifyConfiguration.maximumBytes else { throw NotifyConfigurationError.limitExceeded }
        }
        return .init(data: data, mode: info.st_mode & 0o777, owner: info.st_uid, identity: "\(info.st_dev):\(info.st_ino)")
    }

    private func writeNew(_ data: Data, to destination: URL, mode: mode_t) throws {
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NotifyConfigurationError.fileOperation }
        defer { close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data); try handle.synchronize()
        guard fchmod(descriptor, mode) == 0 else { throw NotifyConfigurationError.fileOperation }
    }
}
