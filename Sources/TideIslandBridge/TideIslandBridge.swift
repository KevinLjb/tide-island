import Darwin
import Foundation
import TideIslandCore

@main
struct TideIslandBridge {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let isHook = arguments.first == "hook"
        let isNotifyDispatcher = arguments.first == "notify-dispatch"
        do {
            try run(arguments)
        } catch {
            // A hook observes only: never emit decisions/context on stdout or
            // use exit code 2, which Codex interprets as a blocking decision.
            let message = isHook ? "Hook observation skipped." : isNotifyDispatcher ? "Notify callback incomplete." : error.localizedDescription
            FileHandle.standardError.write(Data("tide-island-bridge: \(message)\n".utf8))
            if !isHook && !isNotifyDispatcher { exit(1) }
        }
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first, command != "--help", command != "help" else {
            print(help)
            return
        }
        let rest = Array(arguments.dropFirst())
        if command == "version" || command == "--version" {
            guard rest.isEmpty else { throw CLIError.invalidArguments }
            if command == "--version" { print("tide-island-bridge \(TideIslandVersion.version) (\(TideIslandVersion.build))") }
            else {
                let record = ["version": TideIslandVersion.version, "build": TideIslandVersion.build]
                FileHandle.standardOutput.write(try JSONEncoder().encode(record) + Data([10]))
            }
            return
        }
        if command == "integration" { try IntegrationCommand.run(rest); return }
        if command == "notify-config" { try NotifyConfigurationCommand.run(rest); return }
        if command == "notify-dispatch" { try NotifyDispatchCommand.run(rest); return }
        if command == "state" {
            try StateCommand.run(rest)
            return
        }
        if command == "inbox" {
            try InboxCommand.run(rest)
            return
        }
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
        case "emit": allowed = ["--session", "--project", "--phase", "--turn", "--wave-block", "--wave-tab", "--wave-version", "--inbox"]
        case "notify": allowed = ["--payload", "--wave-block", "--wave-tab", "--wave-version", "--inbox"]
        case "hook": allowed = ["--wave-block", "--wave-tab", "--wave-version", "--inbox"]
        default: throw CLIError.invalidArguments
        }
        let options = try parseOptions(rest, allowed: allowed)
        let now = Date()
        let wave = try captureWaveLocation(options, at: now)
        let event: AgentEvent
        switch command {
        case "emit":
            guard let session = options["--session"], let project = options["--project"],
                  let phaseValue = options["--phase"], let phase = AgentPhase(rawValue: phaseValue)
            else { throw CLIError.invalidArguments }
            event = AgentEvent(
                version: AgentEvent.currentVersion,
                sessionID: session, projectName: project, phase: phase,
                occurredAt: now, waveBlockID: wave.waveBlockID, waveLocation: wave.location,
                context: EventContext(source: .manual, kind: .status, receivedAt: now, turnID: options["--turn"])
            )
        case "notify":
            guard let payload = options["--payload"] else { throw CLIError.invalidArguments }
            do {
                guard payload.utf8.count <= CodexHookAdapter.maximumInputBytes else {
                    throw CLIError.invalidNotification
                }
                let notification = try JSONDecoder().decode(CodexNotification.self, from: Data(payload.utf8))
                event = try notification.event(at: now, waveBlockID: wave.waveBlockID, waveLocation: wave.location)
            } catch {
                throw CLIError.invalidNotification
            }
        case "hook":
            guard let observed = try CodexHookAdapter.event(from: readHookInput(), receivedAt: now,
                                                          waveBlockID: wave.waveBlockID, waveLocation: wave.location) else {
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

    static func captureWaveLocation(_ options: [String: String], at now: Date) throws -> WaveLocationCapture {
        if ["--wave-block", "--wave-tab", "--wave-version"].contains(where: { options[$0] != nil }) {
            return try WaveLocationCapture.explicit(blockID: options["--wave-block"], tabID: options["--wave-tab"],
                                                    waveVersion: options["--wave-version"], observedAt: now)
        }
        var values: [String: String] = [:]
        for key in ["WAVETERM_BLOCKID", "WAVETERM_TABID", "WAVETERM_VERSION"] {
            if let value = getenv(key) { values[key] = String(cString: value) }
        }
        return WaveLocationCapture.environment(values, observedAt: now)
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
            "tide_island_version": ["version": TideIslandVersion.version, "build": TideIslandVersion.build],
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
                "application_bundle_option": "--app", "embedded_bridge_integrity": "sha256-manifest-v1",
                "bundle_signing_verified_by_inspector": false,
            ],
            "notify_configuration": [
                "format": "top-level-config-toml-notify", "default_mode": "preview",
                "preserves_foreign_argv": true, "original_argv_storage": "same-notify-setting",
                "callback_stdout": "empty", "callback_failure_exit_code": 0,
                "callback_uses_shell": false, "manages_codex_trust": false,
            ],
            "integration": [
                "default_mode": "preview", "scope": "explicit-codex-directory",
                "default_data_action": "keep", "optional_data_action": "clear-state",
                "preserves_event_files": true, "preserves_display_preferences": true,
                "cross_file_transaction": false, "reports_completed_steps": true,
            ],
            "inbox_maintenance": [
                "default_mode": "preview", "requires_managed_marker": true,
                "protects_unresolved_session_history": true, "capacity_targets_are_soft": true,
                "recovery_default_mode": "preview", "resumes_approved_cleanup": true,
                "recovers_complete_staged_events": true, "preserves_conflicting_files": true,
                "cleanup_apply_requires_receiver_lease": true, "saves_turn_protection_before_cleanup": true,
            ],
            "session_persistence": [
                "schema_version": 2, "readable_schema_versions": [1, 2],
                "metadata_only": true, "maximum_checkpoint_bytes": 33554432,
                "maximum_sessions": 2048, "maximum_imported_files": 65536,
                "clear_default_mode": "preview", "clear_preserves_inbox_files": true,
                "clear_suppresses_existing_records": true, "validates_source_after_restart": true,
            ],
            "wave_location": [
                "schema_version": WaveLocation.currentVersion, "optional_in_event_v2": true,
                "environment_keys": ["WAVETERM_BLOCKID", "WAVETERM_TABID", "WAVETERM_VERSION"],
                "reviewed_wave_version": WaveLocation.reviewedWaveVersion,
                "valid_for_seconds": WaveLocationPolicy.standard.validFor,
                "metadata_only": true, "runs_wsh": false, "implements_navigation": false,
            ],
            "wave_navigation": [
                "scope": "shared-policy-and-injected-driver", "reviewed_wave_version": WaveLocation.reviewedWaveVersion,
                "candidate_route": "tab-layout-focus", "evidence_valid_for_seconds": WaveNavigationPolicy.standard.evidenceValidFor,
                "default_route": "application-fallback-required", "reports_visible_focus": false,
                "production_driver_installed": false, "runs_wsh": false,
            ],
            "wave_application_return": [
                "scope": "shared-coordinator-and-native-source", "bundle_identifier": WaveReturnCoordinator.bundleIdentifier,
                "resolves_current_session_links": true, "reports_exact_focus": false,
                "launches_app_from_cli": false, "native_runtime_verified": false,
            ],
            "session_reminders": [
                "scope": "shared-policy-and-native-source", "default_enabled": false,
                "types": ["needsInput", "turnEnded"], "ordered_source_sequences": true,
                "primary_receiver_required": true, "startup_history_replayed": false,
                "same_episode_reposted_after_uncertain_failure": false,
                "verified_viewing_driver_installed": false,
                "maximum_tracked_sessions": SessionReminderCoordinator.maximumSessions,
                "quiet_hours_local_calendar": true,
                "native_runtime_verified": false, "posts_notifications_from_cli": false,
            ],
            "island_activity": [
                "scope": "shared-presentation-and-client", "content_fields": 6,
                "shared_json_development_budget_bytes": IslandActivityPresentationPolicy.standard.maximumContentBytes,
                "formal_sdk_limit_verified": false, "native_runtime_verified": false,
                "runs_native_api_from_cli": false,
                "latest_snapshot_scheduler": true, "ordered_source_sequences": true,
                "minimum_ordinary_update_interval_seconds": IslandActivityScheduler.minimumUpdateInterval,
                "delivery_stream": true,
                "scoped_activity_inventory": true, "forced_reconciliation": true,
                "graceful_shutdown": true, "system_dismissal_memory": "process-only",
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
    emit/notify/hook accept [--wave-block ID --wave-tab UUID --wave-version VERSION].
    Explicit Wave arguments never inherit environment IDs; tab/version require
    a full explicit block UUID. A legacy opaque --wave-block alone stays valid.
    replay --file SCENARIOS_JSON [--scenario NAME]
    inbox cleanup [--inbox /DIRECTORY] [--max-files COUNT] [--max-bytes BYTES]
                  [--max-age-days DAYS] [--scan-limit COUNT] [--read-budget-bytes BYTES]
                  [--apply --expect FINGERPRINT]
    inbox recover [--inbox /DIRECTORY] [--scan-limit COUNT] [--read-budget-bytes BYTES] [--apply]
    state inspect [--inbox /DIRECTORY] [--state-directory /DIRECTORY]
    state clear [--inbox /DIRECTORY] [--state-directory /DIRECTORY]
                [--scan-limit COUNT] [--read-budget-bytes BYTES] [--apply --expect FINGERPRINT]
    hooks install --config /PATH/hooks.json (--app /PATH/TideIsland.app | --bridge /STABLE/PATH/tide-island-bridge)
                  [--inbox /DIRECTORY] [--apply --expect FINGERPRINT --backup-dir /DIRECTORY]
    hooks uninstall --config /PATH/hooks.json
                    [--apply --expect FINGERPRINT --backup-dir /DIRECTORY]
    notify-config install --config /PATH/config.toml --app /PATH/TideIsland.app
                          [--inbox /DIRECTORY] [--apply --expect FINGERPRINT --backup-dir /DIRECTORY]
    notify-config uninstall --config /PATH/config.toml
                            [--apply --expect FINGERPRINT --backup-dir /DIRECTORY]
    integration install --codex-directory /DIRECTORY --app /PATH/TideIsland.app
                        [--inbox /DIRECTORY] [--apply --expect FINGERPRINT --backup-dir /DIRECTORY]
    integration uninstall --codex-directory /DIRECTORY [--data keep|clear-state]
                          [--inbox /DIRECTORY] [--state-directory /DIRECTORY]
                          [--scan-limit COUNT] [--read-budget-bytes BYTES]
                          [--apply --expect FINGERPRINT --backup-dir /DIRECTORY]
    capabilities
    version | --version

    emit/notify write an event and print JSON. hook reads stdin and keeps stdout
    empty; observation failures return 0 and never decide Codex permissions.
    capabilities describes the pinned contract, not the installed Codex version.
    replay checks explicit fixture expectations in memory and prints a stable
    metadata report. Mismatches return 1; no inbox or Codex config is written.
    hooks defaults to preview; apply requires its exact preview fingerprint and
    a backup directory. It never edits config.toml or Codex hook trust records.
    --app checks the embedded helper without executing it. Move/upgrade the app,
    then preview again to repair only managed hook paths; old previews expire.
    notify-config edits only the top-level notify setting with a private backup.
    It preserves existing command arguments, restores them on uninstall, and
    never edits hook trust. Its internal callback observes metadata and forwards
    the original payload as one argument without a shell or stdout output.
    integration previews both files with one fingerprint and reports partial
    progress on apply failure; it does not promise a cross-file transaction.
    Uninstall keeps data by default. clear-state requires an explicit inbox and
    a free receiver lease; event files and display settings are preserved.
    inbox cleanup previews expired whole-session history. Apply requires the
    exact fingerprint; active/uncertain histories and unknown files stay intact.
    inbox recover previews interrupted operations. Apply completes only valid
    staged writes and previously approved cleanup, preserving conflicting files.
    state inspect reports metadata counts only. state clear previews a reset of
    saved sessions/preferences; apply requires its fingerprint and a free app
    receiver lease. Existing inbox files stay intact and are not reimported.
    inbox cleanup apply also requires a free receiver lease and checkpoints the
    observed turn state before deletion; use the app's cleanup while it is open.
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
