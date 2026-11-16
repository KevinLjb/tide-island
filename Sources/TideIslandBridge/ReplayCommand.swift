import Darwin
import Foundation
import TideIslandCore

enum ReplayCommand {
    static func run(_ arguments: [String]) throws {
        let options = try TideIslandBridge.parseOptions(arguments, allowed: ["--file", "--scenario"])
        guard let path = options["--file"] else { throw CLIError.invalidArguments }
        let report = try EventReplay.run(read(path), scenario: options["--scenario"])
        FileHandle.standardOutput.write(try EventReplay.encode(report) + Data([0x0A]))
        if !report.passed { throw ReplayError.expectationMismatch }
    }

    private static func read(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ReplayError.unreadableFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ReplayError.unreadableFile }
        guard info.st_size >= 0, info.st_size <= EventReplay.maximumInputBytes else { throw ReplayError.limitExceeded }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= EventReplay.maximumInputBytes else { throw ReplayError.limitExceeded }
        }
        return data
    }
}
