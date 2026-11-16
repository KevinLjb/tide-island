import Foundation
import TideIslandCore

@main
struct TideIslandBridge {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let isHook = arguments.first == "hook"
        do {
            try run(arguments)
        } catch {
            // A hook observes only: never emit decisions/context on stdout or
            // use exit code 2, which Codex interprets as a blocking decision.
            let message = isHook ? "Hook observation skipped." : error.localizedDescription
            FileHandle.standardError.write(Data("tide-island-bridge: \(message)\n".utf8))
            if !isHook { exit(1) }
        }
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first, command != "--help", command != "help" else {
            print(help)
            return
        }
        let rest = Array(arguments.dropFirst())
        if command == "replay" {
            try ReplayCommand.run(rest)
            return
        }
        if command == "hooks" {
            try HookConfigurationCommand.run(rest)
            return
        }
        if command == "capabilities" {
            guard rest.isEmpty else { throw CLIError.invalidArguments }
            try printCapabilities()
            return
        }
        let allowed: Set<String>
        switch command {
        case "emit": allowed = ["--session", "--project", "--phase", "--turn", "--wave-block", "--inbox"]
        case "notify": allowed = ["--payload", "--wave-block", "--inbox"]
        case "hook": allowed = ["--wave-block", "--inbox"]
        default: throw CLIError.invalidArguments
        }
        let options = try parseOptions(rest, allowed: allowed)
        let blockID = options["--wave-block"] ?? ProcessInfo.processInfo.environment["WAVETERM_BLOCKID"]
        let event: AgentEvent
        switch command {
        case "emit":
            guard let session = options["--session"], let project = options["--project"],
                  let phaseValue = options["--phase"], let phase = AgentPhase(rawValue: phaseValue)
            else { throw CLIError.invalidArguments }
            let now = Date()
            event = AgentEvent(
                version: AgentEvent.currentVersion,
                sessionID: session, projectName: project, phase: phase,
                occurredAt: now, waveBlockID: blockID,
                context: EventContext(source: .manual, kind: .status, receivedAt: now, turnID: options["--turn"])
            )
        case "notify":
            guard let payload = options["--payload"] else { throw CLIError.invalidArguments }
            do {
                guard payload.utf8.count <= CodexHookAdapter.maximumInputBytes else {
                    throw CLIError.invalidNotification
                }
                let notification = try JSONDecoder().decode(CodexNotification.self, from: Data(payload.utf8))
                event = try notification.event(waveBlockID: blockID)
            } catch {
                throw CLIError.invalidNotification
            }
        case "hook":
            guard let observed = try CodexHookAdapter.event(from: readHookInput(), waveBlockID: blockID) else {
                return
            }
            event = observed
        default:
            throw CLIError.invalidArguments
        }
        let inbox = try options["--inbox"].map {
            EventInbox(directory: URL(fileURLWithPath: $0, isDirectory: true))
        } ?? EventInbox.applicationDefault()
        try inbox.write(event)
        if command != "hook" {
            FileHandle.standardOutput.write(try EventCodec.encode(event) + Data([0x0A]))
        }
    }

    static func parseOptions(_ arguments: [String], allowed: Set<String>) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else { throw CLIError.invalidArguments }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard allowed.contains(key), options[key] == nil else { throw CLIError.invalidArguments }
            options[key] = arguments[index + 1]
        }
        return options
    }

    static func readHookInput() throws -> Data {
        var data = Data()
        let maximum = CodexHookAdapter.maximumInputBytes
        while let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, maximum + 1 - data.count)),
              !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximum else { throw EventError.oversizedHookInput }
        }
        return data
    }

    static func printCapabilities() throws {
        let value: [String: Any] = [
            "event_protocol_versions": [1, AgentEvent.currentVersion],
            "output_protocol_version": AgentEvent.currentVersion,
            "contract_cli_version": CodexHookAdapter.contractCLIVersion,
            "upstream_revision": CodexHookAdapter.upstreamRevision,
            "forwarded_hook_events": CodexHookEvent.allCases.map(\.rawValue),
            "completion_source": "notify:agent-turn-complete",
            "hook_stdout": "empty",
            "question_detection": "not_available_from_this_adapter",
            "automatic_turn_failure_detection": false,
            "subagent_hooks": "ignored_when_agent_context_is_present",
            "maximum_hook_input_bytes": CodexHookAdapter.maximumInputBytes,
            "replay": [
                "schema_version": 1, "scope": "in-memory-adapters-codec-registry",
                "writes_inbox": false, "explicit_ids_and_clocks": true,
                "maximum_input_bytes": EventReplay.maximumInputBytes,
                "maximum_steps": EventReplay.maximumSteps,
            ],
            "hook_configuration": [
                "format": "hooks.json", "default_mode": "preview",
                "preserves_config_toml": true, "manages_codex_trust": false,
            ],
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) + Data([0x0A]))
    }

    static let help = """
    TideIsland event bridge

    emit --session ID --project NAME --phase working|needsInput|completed|failed|interrupted|ended
         [--turn ID] [--wave-block ID] [--inbox DIRECTORY]
    notify --payload CODEX_NOTIFICATION_JSON [--wave-block ID] [--inbox DIRECTORY]
    hook [--wave-block ID] [--inbox DIRECTORY] < CODEX_HOOK_JSON
    replay --file SCENARIOS_JSON [--scenario NAME]
    hooks install --config /PATH/hooks.json --bridge /STABLE/PATH/tide-island-bridge
                  [--inbox /DIRECTORY] [--apply --expect FINGERPRINT --backup-dir /DIRECTORY]
    hooks uninstall --config /PATH/hooks.json
                    [--apply --expect FINGERPRINT --backup-dir /DIRECTORY]
    capabilities

    emit/notify write an event and print JSON. hook reads stdin and keeps stdout
    empty; observation failures return 0 and never decide Codex permissions.
    capabilities describes the pinned contract, not the installed Codex version.
    replay checks explicit fixture expectations in memory and prints a stable
    metadata report. Mismatches return 1; no inbox or Codex config is written.
    hooks defaults to preview; apply requires its exact preview fingerprint and
    a backup directory. It never edits config.toml or Codex hook trust records.
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
