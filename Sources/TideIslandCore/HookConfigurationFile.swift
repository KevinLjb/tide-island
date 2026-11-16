import Darwin
import Foundation

/// File operations are explicit; constructing a preview creates no directories,
/// lock files, backups, trust records, or Codex configuration.
public struct HookConfigurationFile: Sendable {
    public let url: URL

    public init(url: URL) throws {
        try CodexHookConfiguration.validatePath(url.path)
        guard url.isFileURL, url.lastPathComponent == "hooks.json" else { throw HookConfigurationError.invalidPath }
        self.url = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent("hooks.json")
    }

    public func preview(
        action: HookConfigurationAction,
        bridgePath: String? = nil,
        inboxPath: String? = nil
    ) throws -> HookConfigurationPlan {
        try CodexHookConfiguration.plan(
            action: action, existing: read()?.data, bridgePath: bridgePath, inboxPath: inboxPath,
            configurationPath: url.path
        )
    }

    /// A fingerprint binds both the reviewed source bytes and proposed options.
    /// Our writers share a lock. Uncoordinated editors must not write during
    /// apply: POSIX rename cannot compare-and-swap an existing file's content.
    @discardableResult
    public func apply(
        _ plan: HookConfigurationPlan,
        expectedFingerprint: String,
        backupDirectory: URL
    ) throws -> URL? {
        guard plan.configurationPath == url.path, expectedFingerprint == plan.fingerprint,
              try read()?.data == plan.originalData else {
            throw HookConfigurationError.stalePlan
        }
        guard plan.changesFile else { return nil }
        if let bridge = plan.bridgePath {
            let resolved = URL(fileURLWithPath: bridge).resolvingSymlinksInPath()
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true, FileManager.default.isExecutableFile(atPath: resolved.path) else {
                throw HookConfigurationError.bridgeUnavailable
            }
            guard !resolved.pathComponents.contains(".build"), !resolved.pathComponents.contains("DerivedData") else {
                throw HookConfigurationError.unstableBridgePath
            }
        }
        try CodexHookConfiguration.validatePath(backupDirectory.path)
        guard backupDirectory.isFileURL, let proposed = plan.proposedData else {
            throw HookConfigurationError.invalidPath
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent(".tide-island-hooks.lock")
        let lock = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw HookConfigurationError.unsafeFile }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == geteuid() else { throw HookConfigurationError.unsafeFile }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw HookConfigurationError.busy }
        defer { flock(lock, LOCK_UN) }
        let snapshot = try read()
        guard snapshot?.data == plan.originalData else { throw HookConfigurationError.stalePlan }
        if let snapshot, snapshot.owner != geteuid() { throw HookConfigurationError.unsafeFile }

        let backup = backupDirectory.appendingPathComponent("tide-island-hooks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        if let snapshot {
            try writeNew(snapshot.data, to: backup.appendingPathComponent("hooks.json.before"), mode: 0o600)
        }
        var receipt: [String: Any] = [
            "version": 1, "kind": "before-change-backup", "config_path": url.path,
            "original_existed": snapshot != nil, "operation": plan.action.rawValue,
            "plan_fingerprint": plan.fingerprint,
        ]
        if let snapshot { receipt["original_permissions"] = Int(snapshot.mode) }
        else { receipt["original_permissions"] = NSNull() }
        try writeNew(try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]),
                     to: backup.appendingPathComponent("receipt.json"), mode: 0o600)

        // A sibling staging file keeps publication atomic on the same filesystem.
        let staging = directory.appendingPathComponent(".tide-island-hooks-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        try writeNew(proposed, to: staging, mode: snapshot?.mode ?? 0o600)
        let latest = try read()
        guard latest?.data == snapshot?.data, latest?.mode == snapshot?.mode,
              latest?.identity == snapshot?.identity else { throw HookConfigurationError.stalePlan }
        if snapshot == nil {
            // link publishes a new file without replacing an intervening writer.
            guard link(staging.path, url.path) == 0 else {
                throw errno == EEXIST ? HookConfigurationError.stalePlan : HookConfigurationError.fileOperation
            }
        } else if rename(staging.path, url.path) != 0 { throw HookConfigurationError.fileOperation }
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
            throw HookConfigurationError.unsafeFile
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw HookConfigurationError.unsafeFile
        }
        guard info.st_size >= 0, info.st_size <= CodexHookConfiguration.maximumBytes else {
            throw HookConfigurationError.invalidConfiguration
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while let part = try handle.read(upToCount: 64 * 1024), !part.isEmpty {
            data.append(part)
            guard data.count <= CodexHookConfiguration.maximumBytes else { throw HookConfigurationError.invalidConfiguration }
        }
        return Snapshot(data: data, mode: info.st_mode & 0o777, owner: info.st_uid,
                        identity: "\(info.st_dev):\(info.st_ino)")
    }

    private func writeNew(_ data: Data, to destination: URL, mode: mode_t) throws {
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HookConfigurationError.fileOperation }
        defer { close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard fchmod(descriptor, mode) == 0 else { throw HookConfigurationError.fileOperation }
    }
}
