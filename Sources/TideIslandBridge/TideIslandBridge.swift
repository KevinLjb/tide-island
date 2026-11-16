import Foundation
import TideIslandCore

@main
struct TideIslandBridge {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            // Do not echo the input: notify payloads may contain private messages.
            FileHandle.standardError.write(Data("tide-island-bridge: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first, command != "--help", command != "help" else {
            print(help)
            return
        }
        let options = try parseOptions(Array(arguments.dropFirst()))
        let blockID = options["--wave-block"] ?? ProcessInfo.processInfo.environment["WAVETERM_BLOCKID"]
        let event: AgentEvent
        switch command {
        case "emit":
            guard let session = options["--session"], let project = options["--project"],
                  let phaseValue = options["--phase"], let phase = AgentPhase(rawValue: phaseValue)
            else { throw CLIError.invalidArguments }
            event = AgentEvent(sessionID: session, projectName: project, phase: phase, waveBlockID: blockID)
        case "notify":
            guard let payload = options["--payload"] else { throw CLIError.invalidArguments }
            do {
                let notification = try JSONDecoder().decode(CodexNotification.self, from: Data(payload.utf8))
                event = try notification.event(waveBlockID: blockID)
            } catch {
                throw CLIError.invalidNotification
            }
        default:
            throw CLIError.invalidArguments
        }
        let inbox = try options["--inbox"].map {
            EventInbox(directory: URL(fileURLWithPath: $0, isDirectory: true))
        } ?? EventInbox.applicationDefault()
        try inbox.write(event)
        FileHandle.standardOutput.write(try EventCodec.encode(event) + Data([0x0A]))
    }

    static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        let allowed: Set<String> = ["--session", "--project", "--phase", "--wave-block", "--inbox", "--payload"]
        guard arguments.count.isMultiple(of: 2) else { throw CLIError.invalidArguments }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard allowed.contains(key), options[key] == nil else { throw CLIError.invalidArguments }
            options[key] = arguments[index + 1]
        }
        return options
    }

    static let help = """
    TideIsland event bridge

    emit --session ID --project NAME --phase working|needsInput|completed|failed
         [--wave-block ID] [--inbox DIRECTORY]
    notify --payload CODEX_NOTIFICATION_JSON [--inbox DIRECTORY]

    Writes one metadata-only event to the local inbox and prints its JSON.
    Default inbox: ~/Library/Application Support/TideIsland/Events
    """
}

enum CLIError: Error, LocalizedError {
    case invalidArguments
    case invalidNotification

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid arguments. Run with --help for usage."
        case .invalidNotification: "Invalid or unsupported Codex notification; payload was not logged."
        }
    }
}
