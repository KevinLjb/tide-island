import CryptoKit
import Darwin
import Foundation
import TideIslandCore

enum NativeCodexQuotaProblem: Error, Sendable {
    case serviceUnavailable, timeout, invalidMessage
}

enum NativeCodexQuotaState: Equatable {
    case off, checking, available(CodexQuotaSnapshot), unavailable

    var snapshot: CodexQuotaSnapshot? {
        if case .available(let snapshot) = self { snapshot } else { nil }
    }

    var message: String {
        switch self {
        case .off: "开启后读取本机 Codex 当前账号的额度。"
        case .checking: "正在读取 Codex 额度…"
        case .available: "额度来自本机 Codex 当前账号。"
        case .unavailable: "暂时无法读取额度。请检查本机 Codex 服务及登录状态。"
        }
    }
}

struct NativeCodexQuotaReader: Sendable {
    let socketPath: String

    init(socketPath: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let codexHome = environment.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        self.socketPath = socketPath ?? codexHome.appendingPathComponent("app-server-control/app-server-control.sock").path
    }

    func read() async throws -> CodexQuotaSnapshot {
        let worker = Task.detached(priority: .utility) {
            try self.readFromSocket()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func readFromSocket() throws -> CodexQuotaSnapshot {
        try Task.checkCancellation()
        let connection = try LocalQuotaSocket(path: socketPath)
        try connection.upgrade()
        try connection.sendText(#"{"method":"initialize","id":1,"params":{"clientInfo":{"name":"tide_island","title":"TideIsland","version":"\#(TideIslandVersion.version)"}}}"#)
        let initialized = try connection.response(id: 1)
        guard let object = try JSONSerialization.jsonObject(with: initialized) as? [String: Any],
              object["result"] is [String: Any] else { throw NativeCodexQuotaProblem.invalidMessage }
        try connection.sendText(#"{"method":"initialized"}"#)
        try connection.sendText(#"{"method":"account/rateLimits/read","id":2,"params":{"excludeResetCreditDetails":true}}"#)
        let data = try connection.response(id: 2)
        // Best-effort protocol close. This only closes our client connection.
        try? connection.sendFrame(Data([0x03, 0xE8]), opcode: 8)
        return try CodexQuotaSnapshot.decodeResponse(data, requestID: 2, checkedAt: Date())
    }
}

/// A short-lived WebSocket client over the daemon's Unix control socket.
/// The synchronous I/O runs on a detached task with one deadline and byte budget.
private final class LocalQuotaSocket {
    private let fd: Int32
    private let deadline = ContinuousClock.now.advanced(by: .seconds(12))
    private var buffer = Data()
    private var received = 0

    init(path: String) throws {
        var info = stat()
        // Codex can publish a stable symlink to a short Unix socket path.
        guard path.hasPrefix("/"), !path.utf8.contains(0), stat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
            throw NativeCodexQuotaProblem.serviceUnavailable
        }
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NativeCodexQuotaProblem.serviceUnavailable
        }
        let length = MemoryLayout<sockaddr_un>.size
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NativeCodexQuotaProblem.serviceUnavailable }
        fd = descriptor
        var noSignal: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw NativeCodexQuotaProblem.serviceUnavailable
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(length)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw NativeCodexQuotaProblem.serviceUnavailable }
            try wait(for: Int16(POLLOUT))
            var status: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &size) == 0, status == 0 else {
                throw NativeCodexQuotaProblem.serviceUnavailable
            }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            throw NativeCodexQuotaProblem.serviceUnavailable
        }
    }

    deinit { Darwin.close(fd) }

    func upgrade() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n" +
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n"
        try write(Data(request.utf8))
        let separator = Data([13, 10, 13, 10])
        while buffer.range(of: separator) == nil {
            guard buffer.count < 8192 else { throw NativeCodexQuotaProblem.invalidMessage }
            try readMore()
        }
        guard let end = buffer.range(of: separator)?.upperBound, end <= 8192,
              let header = String(data: buffer.prefix(upTo: end), encoding: .utf8) else {
            throw NativeCodexQuotaProblem.invalidMessage
        }
        buffer = Data(buffer.suffix(from: end))
        let lines = header.components(separatedBy: "\r\n")
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let accepted = lines.dropFirst().contains { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept" &&
                parts[1].trimmingCharacters(in: .whitespaces) == expected
        }
        guard lines.first?.split(separator: " ").dropFirst().first == "101", accepted else {
            throw NativeCodexQuotaProblem.invalidMessage
        }
    }

    func sendText(_ value: String) throws { try sendFrame(Data(value.utf8), opcode: 1) }

    func sendFrame(_ payload: Data, opcode: UInt8) throws {
        let count = payload.count
        guard count <= Int(UInt16.max) else { throw NativeCodexQuotaProblem.invalidMessage }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        var data = Data([0x80 | opcode])
        if count < 126 { data.append(0x80 | UInt8(count)) }
        else { data.append(contentsOf: [0xFE, UInt8(count >> 8), UInt8(count & 255)]) }
        data.append(contentsOf: mask)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(data)
    }

    func response(id: Int) throws -> Data {
        var partial: Data?
        for _ in 0..<64 {
            let header = [UInt8](try take(2))
            let final = header[0] & 0x80 != 0
            let opcode = header[0] & 0x0F
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw NativeCodexQuotaProblem.invalidMessage }
            let lengthCode = Int(header[1] & 0x7F)
            var length = UInt64(lengthCode)
            if lengthCode >= 126 { length = try take(lengthCode == 126 ? 2 : 8).reduce(0) { ($0 << 8) | UInt64($1) } }
            guard length <= CodexQuotaSnapshot.maximumResponseBytes,
                  opcode < 8 || (final && length <= 125) else { throw NativeCodexQuotaProblem.invalidMessage }
            let payload = try take(Int(length))
            let message: Data
            switch opcode {
            case 8: throw NativeCodexQuotaProblem.serviceUnavailable
            case 9: try sendFrame(payload, opcode: 10); continue
            case 10: continue
            case 1:
                guard partial == nil else { throw NativeCodexQuotaProblem.invalidMessage }
                if !final { partial = payload; continue }
                message = payload
            case 0:
                guard var current = partial, current.count + payload.count <= CodexQuotaSnapshot.maximumResponseBytes else {
                    throw NativeCodexQuotaProblem.invalidMessage
                }
                current.append(payload)
                if !final { partial = current; continue }
                partial = nil
                message = current
            default: throw NativeCodexQuotaProblem.invalidMessage
            }
            struct Envelope: Decodable { let id: Int?; let method: String? }
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: message),
               envelope.id == id, envelope.method == nil { return message }
        }
        throw NativeCodexQuotaProblem.invalidMessage
    }

    private func take(_ count: Int) throws -> Data {
        while buffer.count < count { try readMore() }
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    private func readMore() throws {
        try wait(for: Int16(POLLIN))
        var scratch = [UInt8](repeating: 0, count: 4096)
        let count = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { throw NativeCodexQuotaProblem.serviceUnavailable }
        received += count
        guard received <= 4 * CodexQuotaSnapshot.maximumResponseBytes else { throw NativeCodexQuotaProblem.invalidMessage }
        buffer.append(contentsOf: scratch.prefix(count))
    }

    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try wait(for: Int16(POLLOUT))
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress?.advanced(by: offset), $0.count - offset) }
            if n < 0, errno == EAGAIN || errno == EINTR { continue }
            guard n > 0 else { throw NativeCodexQuotaProblem.serviceUnavailable }
            offset += n
        }
    }

    private func wait(for events: Int16) throws {
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result > 0 {
                guard descriptor.revents & events != 0 else { throw NativeCodexQuotaProblem.serviceUnavailable }
                return
            }
            if result < 0, errno != EINTR { throw NativeCodexQuotaProblem.serviceUnavailable }
        }
        throw NativeCodexQuotaProblem.timeout
    }
}
