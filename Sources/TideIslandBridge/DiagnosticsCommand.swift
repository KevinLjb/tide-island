import Foundation
import TideIslandCore

enum DiagnosticsCommand {
    static func run(_ arguments: [String]) throws {
        let options = try TideIslandBridge.parseOptions(arguments, allowed: ["--inbox", "--output", "--scan-limit", "--read-budget-bytes"])
        guard options.values.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }),
              options["--inbox"].map({ $0.hasPrefix("/") }) != false,
              options["--output"].map({ $0.hasPrefix("/") }) != false,
              options["--inbox"] != nil || (options["--scan-limit"] == nil && options["--read-budget-bytes"] == nil)
        else { throw CLIError.invalidArguments }
        let defaults = InboxReadLimits()
        func number(_ key: String, fallback: Int64) throws -> Int64 {
            guard let value = options[key] else { return fallback }
            guard let count = Int64(value), String(count) == value else { throw CLIError.invalidArguments }
            return count
        }
        let count = try number("--scan-limit", fallback: Int64(defaults.maximumFiles))
        let budget = try number("--read-budget-bytes", fallback: defaults.maximumReadBytes)
        guard count > 0, count <= 65_536 else { throw CLIError.invalidArguments }
        let limits = try InboxReadLimits(maximumFiles: Int(count), maximumReadBytes: budget)
        let inbox = options["--inbox"].map { EventInbox(directory: URL(fileURLWithPath: $0, isDirectory: true)) }
        let report = try DiagnosticReport.offline(inbox: inbox, limits: limits)
        if let path = options["--output"] {
            let defaultData = try EventInbox.applicationDefault().directory.deletingLastPathComponent()
            let protected = [defaultData] + (inbox.map { [$0.directory, SessionStateFile(inbox: $0).directory] } ?? [])
            try DiagnosticExport.write(report, to: URL(fileURLWithPath: path), excluding: protected)
            FileHandle.standardOutput.write(Data("{\"exported\":true,\"schema_version\":1}\n".utf8))
        } else { FileHandle.standardOutput.write(try report.encoded()) }
    }
}
