import Foundation
import TideIslandCore

enum StateCommand {
    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first, ["inspect", "clear"].contains(command) else { throw CLIError.invalidArguments }
        let tail = Array(arguments.dropFirst())
        guard tail.filter({ $0 == "--apply" }).count <= 1 else { throw CLIError.invalidArguments }
        let apply = tail.contains("--apply")
        let allowed: Set<String> = command == "inspect" ? ["--inbox", "--state-directory"] : [
            "--inbox", "--state-directory", "--scan-limit", "--read-budget-bytes", "--expect",
        ]
        let options = try TideIslandBridge.parseOptions(tail.filter { $0 != "--apply" }, allowed: allowed)
        guard command == "clear" || !apply else { throw CLIError.invalidArguments }
        guard apply == (options["--expect"] != nil) else { throw CLIError.invalidArguments }
        func path(_ value: String) throws -> URL {
            guard value.hasPrefix("/"), value.utf8.count <= 4096,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !value.split(separator: "/").contains("..") else { throw CLIError.invalidArguments }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let inbox = try options["--inbox"].map { EventInbox(directory: try path($0)) } ?? EventInbox.applicationDefault()
        let state = try SessionStateFile(inbox: inbox, directory: options["--state-directory"].map(path))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if command == "inspect" {
            FileHandle.standardOutput.write(try encoder.encode(state.inspect()) + Data([0x0A]))
            return
        }
        func integer(_ name: String, fallback: Int) throws -> Int {
            guard let text = options[name] else { return fallback }
            guard let value = Int(text), value > 0 else { throw CLIError.invalidArguments }
            return value
        }
        let defaults = InboxReadLimits()
        let limits = try InboxReadLimits(maximumFiles: integer("--scan-limit", fallback: defaults.maximumFiles),
                                         maximumReadBytes: Int64(integer("--read-budget-bytes", fallback: Int(defaults.maximumReadBytes))))
        let preview = try state.previewReset(limits: limits)
        let result: SessionStateInspection?
        if apply {
            guard let expected = options["--expect"] else { throw CLIError.invalidArguments }
            result = try state.applyReset(preview, expectedFingerprint: expected, limits: limits)
        } else { result = nil }
        struct Output: Encodable {
            let mode: String
            let preview: SessionResetPreview
            let result: SessionStateInspection?
        }
        FileHandle.standardOutput.write(try encoder.encode(Output(mode: apply ? "cleared" : "preview", preview: preview, result: result)) + Data([0x0A]))
    }
}
