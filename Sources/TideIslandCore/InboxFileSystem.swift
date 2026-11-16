import CryptoKit
import Darwin
import Foundation

public enum InboxError: Error, Equatable, LocalizedError {
    case unsafeDirectory
    case unmanagedDirectory
    case unsafeFile
    case changedDuringRead
    case limitExceeded
    case busy
    case invalidPolicy
    case stalePlan
    case fileOperation
    case conflictingEventID
    case cleanupIncomplete

    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory: "Inbox directory is unavailable or unsafe."
        case .unmanagedDirectory: "Cleanup requires an inbox prepared by TideIsland."
        case .unsafeFile: "Inbox file is unavailable or unsafe."
        case .changedDuringRead: "Inbox changed during reading; retry without advancing the cursor."
        case .limitExceeded: "Inbox read limits exceeded; no partial batch was accepted."
        case .busy: "Inbox maintenance is busy; retry later."
        case .invalidPolicy: "Invalid inbox policy or clock."
        case .stalePlan: "Inbox cleanup preview is outdated; preview again."
        case .fileOperation: "Inbox file operation failed."
        case .conflictingEventID: "An existing event ID has different contents."
        case .cleanupIncomplete: "Some reviewed inbox files could not be removed; inspect the result."
        }
    }
}

struct InboxFileStamp: Equatable, Encodable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let mode: UInt32
    let owner: UInt32
    let links: UInt64

    init(_ info: stat) {
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = info.st_size
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        mode = UInt32(info.st_mode)
        owner = info.st_uid
        links = UInt64(info.st_nlink)
    }

    var identity: String { "\(device):\(inode)" }
    var publishedAt: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000) }
    var isOwnedRegularFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) && owner == geteuid() && links == 1 && size >= 0 }
}

struct InboxIndexedFile: Sendable {
    let name: String
    let stamp: InboxFileStamp
    let digest: String?
    let event: AgentEvent?
}

/// All child access uses a held directory descriptor. Managed writers and
/// cleanup cooperate through the stable marker lock; previews never create it.
final class InboxDirectory {
    static let markerName = ".tide-island-inbox"
    static let markerData = Data("TideIsland event inbox v1\n".utf8)
    let url: URL
    let descriptor: Int32
    let identity: String
    private var marker: Int32 = -1

    init(url: URL, create: Bool, requireMarker: Bool) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw InboxError.unsafeDirectory }
        let normalized = url.standardizedFileURL
        self.url = normalized
        if create {
            try FileManager.default.createDirectory(at: normalized, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let fd = open(normalized.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw InboxError.unsafeDirectory }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid() else { close(fd); throw InboxError.unsafeDirectory }
        var markerFD: Int32 = -1
        var markerIdentity = "legacy"
        do {
            if create { try Self.prepareMarker(in: fd) }
            markerFD = openat(fd, Self.markerName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if markerFD < 0 {
                guard errno == ENOENT, !requireMarker, !create else { throw InboxError.unmanagedDirectory }
            } else {
                var metadata = stat()
                guard fstat(markerFD, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_uid == geteuid(), metadata.st_size == Int64(Self.markerData.count) else { throw InboxError.unmanagedDirectory }
                let bytes = try FileHandle(fileDescriptor: markerFD, closeOnDealloc: false).read(upToCount: Self.markerData.count + 1)
                guard bytes == Self.markerData else { throw InboxError.unmanagedDirectory }
                markerIdentity = InboxFileStamp(metadata).identity
            }
        } catch {
            if markerFD >= 0 { close(markerFD) }
            close(fd)
            throw error
        }
        descriptor = fd
        identity = InboxFileStamp(info).identity + ":" + markerIdentity
        marker = markerFD
    }

    deinit {
        if marker >= 0 { close(marker) }
        close(descriptor)
    }

    func locked<T>(exclusive: Bool, waitForWriter: Bool = false, _ body: () throws -> T) throws -> T {
        guard marker >= 0 else { return try body() }
        var acquired = false
        for _ in 0..<(waitForWriter ? 500 : 1) {
            if flock(marker, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 { acquired = true; break }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw InboxError.fileOperation }
            if waitForWriter { usleep(10_000) }
        }
        guard acquired else { throw InboxError.busy }
        defer { flock(marker, LOCK_UN) }
        return try body()
    }

    func verifyPath() throws {
        var current = stat()
        guard lstat(url.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              identity.hasPrefix(InboxFileStamp(current).identity + ":") else { throw InboxError.changedDuringRead }
        if marker >= 0 {
            var markerInfo = stat()
            guard fstatat(descriptor, Self.markerName, &markerInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  markerInfo.st_mode & S_IFMT == S_IFREG,
                  identity == InboxFileStamp(current).identity + ":" + InboxFileStamp(markerInfo).identity else {
                throw InboxError.changedDuringRead
            }
        }
    }

    func entries(maximumFiles: Int) throws -> (files: [(String, InboxFileStamp)], skipped: Int) {
        var files: [(String, InboxFileStamp)] = []
        var skipped = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil else { continue }
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw InboxError.changedDuringRead }
            let stamp = InboxFileStamp(metadata)
            guard stamp.isOwnedRegularFile else { skipped += 1; continue }
            files.append((name, stamp))
            guard files.count <= maximumFiles else { throw InboxError.limitExceeded }
        }
        try verifyPath()
        return (files, skipped)
    }

    func read(_ name: String, stamp: InboxFileStamp) throws -> InboxIndexedFile {
        guard stamp.size <= Int64(EventCodec.maximumBytes) else { return InboxIndexedFile(name: name, stamp: stamp, digest: nil, event: nil) }
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw InboxError.unsafeFile }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, InboxFileStamp(before) == stamp else { throw InboxError.changedDuringRead }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: EventCodec.maximumBytes + 1) ?? Data()
        guard fstat(fd, &after) == 0, InboxFileStamp(after) == stamp, Int64(data.count) == stamp.size else { throw InboxError.changedDuringRead }
        let event = try? EventCodec.decode(data)
        let matched = event?.id == UUID(uuidString: String(name.dropLast(5))) ? event : nil
        return InboxIndexedFile(name: name, stamp: stamp, digest: Self.hash(data), event: matched)
    }

    func write(_ data: Data, id: UUID) throws {
        try locked(exclusive: true, waitForWriter: true) {
            let destination = id.uuidString + ".json"
            let staging = ".tide-island-" + UUID().uuidString + ".tmp"
            let fd = openat(descriptor, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw InboxError.fileOperation }
            defer { close(fd); unlinkat(descriptor, staging, 0) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            if linkat(descriptor, staging, descriptor, destination, 0) != 0 {
                guard errno == EEXIST else { throw InboxError.fileOperation }
                var metadata = stat()
                guard fstatat(descriptor, destination, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                      InboxFileStamp(metadata).isOwnedRegularFile else { throw InboxError.unsafeFile }
                let existing = try read(destination, stamp: InboxFileStamp(metadata))
                guard existing.digest == Self.hash(data) else { throw InboxError.conflictingEventID }
            }
            try verifyPath()
        }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func prepareMarker(in directory: Int32) throws {
        var existing = stat()
        if fstatat(directory, markerName, &existing, AT_SYMLINK_NOFOLLOW) == 0 { return }
        guard errno == ENOENT else { throw InboxError.fileOperation }
        let staging = ".tide-island-marker-" + UUID().uuidString + ".tmp"
        let fd = openat(directory, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InboxError.fileOperation }
        defer { close(fd); unlinkat(directory, staging, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: markerData)
        try handle.synchronize()
        guard linkat(directory, staging, directory, markerName, 0) == 0 || errno == EEXIST else { throw InboxError.fileOperation }
    }
}
