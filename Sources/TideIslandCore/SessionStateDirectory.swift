import Darwin
import Foundation

struct SessionStateBytes {
    let data: Data
    let stamp: InboxFileStamp
}

/// State writers cooperate on a stable lock rather than the atomically
/// replaced destination. Reads are side-effect free and verify held identities.
final class SessionStateDirectory {
    let url: URL
    let descriptor: Int32
    private let identity: String
    static let lockName = ".tide-island-state.lock"

    init(url: URL, create: Bool) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw SessionStateError.unsafePath }
        self.url = url.standardizedFileURL
        if create {
            try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let fd = open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SessionStateError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            close(fd); throw SessionStateError.unsafePath
        }
        descriptor = fd
        identity = InboxFileStamp(info).identity
    }

    func verifyPath() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              InboxFileStamp(info).identity == identity else { throw SessionStateError.conflict }
    }

    func read(_ name: String) throws -> SessionStateBytes? {
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { try verifyPath(); return nil }
            throw SessionStateError.unsafePath
        }
        defer { close(fd) }
        var before = stat(), after = stat(), path = stat()
        guard fstat(fd, &before) == 0, InboxFileStamp(before).isOwnedRegularFile,
              before.st_mode & 0o077 == 0 else { throw SessionStateError.unsafePath }
        guard before.st_size <= SessionCheckpointCodec.maximumBytes else { throw SessionStateError.limitExceeded }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            .read(upToCount: SessionCheckpointCodec.maximumBytes + 1) ?? Data()
        let stamp = InboxFileStamp(before)
        guard fstat(fd, &after) == 0, InboxFileStamp(after) == stamp, data.count == before.st_size,
              fstatat(descriptor, name, &path, AT_SYMLINK_NOFOLLOW) == 0, InboxFileStamp(path) == stamp else {
            throw SessionStateError.conflict
        }
        try verifyPath()
        return SessionStateBytes(data: data, stamp: stamp)
    }

    func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = openat(descriptor, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SessionStateError.unsafePath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, InboxFileStamp(info).isOwnedRegularFile,
              info.st_size == 0, info.st_mode & 0o077 == 0 else { throw SessionStateError.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK || errno == EAGAIN ? SessionStateError.busy : SessionStateError.fileOperation
        }
        defer { flock(fd, LOCK_UN) }
        var current = stat()
        guard fstatat(descriptor, Self.lockName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              InboxFileStamp(current) == InboxFileStamp(info) else { throw SessionStateError.conflict }
        try verifyPath()
        return try body()
    }

    func publish(_ data: Data, name: String) throws {
        let staging = ".tide-island-state-" + UUID().uuidString + ".tmp"
        let fd = openat(descriptor, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SessionStateError.fileOperation }
        defer { close(fd); unlinkat(descriptor, staging, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try verifyPath()
        guard renameat(descriptor, staging, descriptor, name) == 0 else { throw SessionStateError.fileOperation }
        try verifyPath()
    }

    deinit { close(descriptor) }
}
