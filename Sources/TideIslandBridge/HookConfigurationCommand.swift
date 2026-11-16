import Foundation
import TideIslandCore

enum HookConfigurationCommand {
    static func run(_ arguments: [String]) throws {
        guard let value = arguments.first, let action = HookConfigurationAction(rawValue: value) else {
            throw CLIError.invalidArguments
        }
        let tail = Array(arguments.dropFirst())
        guard tail.filter({ $0 == "--apply" }).count <= 1 else { throw CLIError.invalidArguments }
        let apply = tail.contains("--apply")
        var allowed: Set<String> = ["--config", "--expect", "--backup-dir"]
        if action == .install { allowed.formUnion(["--bridge", "--app", "--inbox"]) }
        let options = try TideIslandBridge.parseOptions(tail.filter { $0 != "--apply" }, allowed: allowed)
        guard let path = options["--config"] else { throw CLIError.invalidArguments }
        if !apply, options["--expect"] != nil { throw CLIError.invalidArguments }
        let file = try HookConfigurationFile(url: absoluteURL(path))
        let plan: HookConfigurationPlan
        if let app = options["--app"] {
            guard options["--bridge"] == nil else { throw CLIError.invalidArguments }
            plan = try file.previewBundledInstall(applicationURL: absoluteURL(app), inboxPath: options["--inbox"])
        } else {
            plan = try file.preview(action: action, bridgePath: options["--bridge"], inboxPath: options["--inbox"])
        }
        var backup: URL?
        if apply {
            guard let expected = options["--expect"], let backupPath = options["--backup-dir"] else {
                throw CLIError.invalidArguments
            }
            backup = try file.apply(plan, expectedFingerprint: expected, backupDirectory: absoluteURL(backupPath))
        } else if let backupPath = options["--backup-dir"] { _ = try absoluteURL(backupPath) }
        var result: [String: Any] = [
            "action": action.rawValue, "mode": apply ? (plan.changesFile ? "applied" : "unchanged") : "preview",
            "config_path": file.url.path, "plan_fingerprint": plan.fingerprint,
            "would_change": plan.changesFile, "config_written": apply && plan.changesFile,
            "owned_hooks_before": plan.managedHooksBefore, "owned_hooks_after": plan.managedHooksAfter,
            "config_toml": "unchanged", "codex_trust": "unchanged",
        ]
        if let command = plan.command {
            result["observer_command"] = command
            result["events"] = CodexHookEvent.allCases.map(\.rawValue)
        }
        if let backup { result["backup_path"] = backup.path }
        if let bridge = plan.bundledBridge {
            result["bridge_delivery"] = ["application_path": bridge.applicationURL.path, "executable_path": bridge.executableURL.path,
                                         "sha256": bridge.sha256, "version": bridge.version, "build": bridge.build]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) + Data([0x0A]))
    }

    private static func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/").contains("."), !path.split(separator: "/").contains("..") else {
            throw HookConfigurationError.invalidPath
        }
        return URL(fileURLWithPath: path)
    }
}
