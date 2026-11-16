import Foundation
import TideIslandCore

enum InboxCommand {
    static func run(_ arguments: [String]) throws {
        guard arguments.first == "cleanup" else { throw CLIError.invalidArguments }
        let tail = Array(arguments.dropFirst())
        guard tail.filter({ $0 == "--apply" }).count <= 1 else { throw CLIError.invalidArguments }
        let apply = tail.contains("--apply")
        let options = try TideIslandBridge.parseOptions(tail.filter { $0 != "--apply" }, allowed: [
            "--inbox", "--max-files", "--max-bytes", "--max-age-days", "--expect", "--scan-limit", "--read-budget-bytes",
        ])
        guard apply == (options["--expect"] != nil) else { throw CLIError.invalidArguments }
        let inbox: EventInbox
        if let path = options["--inbox"] {
            guard path.hasPrefix("/"), path.utf8.count <= 4096,
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !path.split(separator: "/").contains("..") else { throw CLIError.invalidArguments }
            inbox = EventInbox(directory: URL(fileURLWithPath: path, isDirectory: true))
        } else { inbox = try EventInbox.applicationDefault() }
        let defaults = InboxRetentionPolicy()
        func integer(_ key: String, fallback: Int) throws -> Int {
            guard let text = options[key] else { return fallback }
            guard let value = Int(text), value > 0 else { throw CLIError.invalidArguments }
            return value
        }
        let files = try integer("--max-files", fallback: defaults.maximumFiles)
        let bytes = try integer("--max-bytes", fallback: Int(defaults.maximumBytes))
        let readDefaults = InboxReadLimits()
        let limits = try InboxReadLimits(maximumFiles: integer("--scan-limit", fallback: readDefaults.maximumFiles),
                                         maximumReadBytes: Int64(integer("--read-budget-bytes", fallback: Int(readDefaults.maximumReadBytes))))
        let days: Double
        if let text = options["--max-age-days"] {
            guard let value = Double(text), value.isFinite, value > 0 else { throw CLIError.invalidArguments }
            days = value
        } else { days = defaults.maximumAge / 86400 }
        let policy = try InboxRetentionPolicy(maximumAge: days * 86400, maximumFiles: files, maximumBytes: Int64(bytes))
        let plan = try inbox.previewCleanup(policy: policy, at: Date(), limits: limits)
        let result: InboxCleanupResult?
        if apply {
            guard let expected = options["--expect"] else { throw CLIError.invalidArguments }
            result = try inbox.applyCleanup(plan, expectedFingerprint: expected, limits: limits)
        } else { result = nil }
        struct Output: Encodable {
            let mode: String
            let plan: InboxCleanupPlan
            let result: InboxCleanupResult?
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let mode = result?.failedFiles.isEmpty == false ? "partial" : (apply ? "applied" : "preview")
        FileHandle.standardOutput.write(try encoder.encode(Output(mode: mode, plan: plan, result: result)) + Data([0x0A]))
        if result?.failedFiles.isEmpty == false { throw InboxError.cleanupIncomplete }
    }
}
