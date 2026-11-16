import Darwin
import Dispatch
import Foundation

/// Immutable descriptors; cancellation and event delivery are owned by
/// Dispatch. Receiver generations discard callbacks queued before cancellation.
final class InboxMonitor: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    let identity: String

    init(directory: URL, onChange: @escaping @Sendable (UInt) -> Void) throws {
        let descriptor = open(directory.path, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw InboxError.unsafeDirectory }
        var info = stat(), pathInfo = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              lstat(directory.path, &pathInfo) == 0,
              InboxFileStamp(pathInfo).identity == InboxFileStamp(info).identity else {
            close(descriptor); throw InboxError.unsafeDirectory
        }
        identity = InboxFileStamp(info).identity
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke, .attrib],
            queue: DispatchQueue(label: "dev.tide-island.inbox-watch", qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            onChange(self.source.data.rawValue)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func cancel() { source.cancel() }
    deinit { source.cancel() }
}

/// The lease is outside Events so deleting/rebuilding Events cannot create a
/// second independent consumer. The empty file stays; flock is process-bound.
final class InboxConsumerLease: @unchecked Sendable {
    private let parent: URL
    private let parentDescriptor: Int32
    private let descriptor: Int32
    private let parentIdentity: String
    private let identity: String
    private let name: String

    init(inbox: URL) throws {
        guard inbox.isFileURL, !inbox.path.utf8.contains(0) else { throw InboxError.unsafeDirectory }
        parent = inbox.standardizedFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw InboxError.unsafeDirectory }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_uid == geteuid() else {
            close(parentFD); throw InboxError.unsafeDirectory
        }
        // Case-folding is deliberately conservative on case-sensitive volumes,
        // and also prevents aliases on the usual case-insensitive APFS volume.
        let slot = inbox.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        name = ".tide-island-receiver-" + InboxDirectory.hash(Data(slot.utf8)) + ".lock"
        let fd = openat(parentFD, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { close(parentFD); throw InboxError.unsafeFile }
        var info = stat()
        guard fstat(fd, &info) == 0, InboxFileStamp(info).isOwnedRegularFile, info.st_size == 0 else {
            close(fd); close(parentFD); throw InboxError.unsafeFile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let contention = errno == EWOULDBLOCK || errno == EAGAIN
            close(fd); close(parentFD)
            throw contention ? InboxError.receiverAlreadyRunning : InboxError.fileOperation
        }
        parentDescriptor = parentFD
        descriptor = fd
        parentIdentity = InboxFileStamp(parentInfo).identity
        identity = InboxFileStamp(info).identity
        try verifyPath()
    }

    func verifyPath() throws {
        var currentParent = stat(), currentFile = stat()
        guard lstat(parent.path, &currentParent) == 0,
              InboxFileStamp(currentParent).identity == parentIdentity,
              fstatat(parentDescriptor, name, &currentFile, AT_SYMLINK_NOFOLLOW) == 0,
              InboxFileStamp(currentFile).isOwnedRegularFile, currentFile.st_size == 0,
              InboxFileStamp(currentFile).identity == identity else { throw InboxError.changedDuringRead }
    }

    deinit { close(descriptor); close(parentDescriptor) }
}
