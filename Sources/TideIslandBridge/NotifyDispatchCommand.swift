import Darwin
import Foundation
import TideIslandCore

enum NotifyDispatchCommand {
    static func run(_ arguments: [String]) throws {
        let invocation = try NotifyDispatchConfiguration.invocation(arguments)
        var incomplete = false
        do {
            let payload = invocation.payload
            guard payload.utf8.count <= CodexHookAdapter.maximumInputBytes else { throw CLIError.invalidNotification }
            let now = Date(), wave = try TideIslandBridge.captureWaveLocation([:], at: now)
            let notification = try JSONDecoder().decode(CodexNotification.self, from: Data(payload.utf8))
            let event = try notification.event(at: now, waveBlockID: wave.waveBlockID, waveLocation: wave.location)
            let inbox = try invocation.configuration.inboxPath.map { EventInbox(directory: URL(fileURLWithPath: $0)) } ?? EventInbox.applicationDefault()
            try inbox.write(event)
        } catch { incomplete = true }
        // A failed observation never suppresses the already configured notifier.
        // Do not use the untrusted payload cwd as the process working directory.
        let original = invocation.configuration.originalArguments
        if let command = original.first {
            do {
                let process = Process()
                process.executableURL = try executable(command)
                process.arguments = Array(original.dropFirst()) + [invocation.payload]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                if process.terminationReason != .exit || process.terminationStatus != 0 { incomplete = true }
            } catch { incomplete = true }
        }
        if incomplete { throw DispatchError.incomplete }
    }

    private static func executable(_ name: String) throws -> URL {
        if name.contains("/") { return URL(fileURLWithPath: name) }
        // Read PATH only, without copying or recording the environment.
        let path = getenv("PATH").map { String(cString: $0) } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        guard path.utf8.count <= 64 * 1024 else { throw DispatchError.incomplete }
        let directories = path.split(separator: ":", omittingEmptySubsequences: false)
        guard directories.count <= 1024 else { throw DispatchError.incomplete }
        for directory in directories {
            let url = URL(fileURLWithPath: directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory), isDirectory: true)
                .appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw DispatchError.incomplete
    }

    private enum DispatchError: Error { case incomplete }
}
