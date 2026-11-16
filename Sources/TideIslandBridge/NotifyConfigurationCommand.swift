import Foundation
import TideIslandCore

enum NotifyConfigurationCommand {
    static func run(_ arguments: [String]) throws {
        guard let name = arguments.first, let action = HookConfigurationAction(rawValue: name) else { throw CLIError.invalidArguments }
        let tail = Array(arguments.dropFirst())
        guard tail.filter({ $0 == "--apply" }).count <= 1 else { throw CLIError.invalidArguments }
        let apply = tail.contains("--apply")
        var allowed: Set<String> = ["--config", "--expect", "--backup-dir"]
        if action == .install { allowed.formUnion(["--app", "--inbox"]) }
        let options = try TideIslandBridge.parseOptions(tail.filter { $0 != "--apply" }, allowed: allowed)
        guard let path = options["--config"], apply || options["--expect"] == nil else { throw CLIError.invalidArguments }
        let file = try NotifyConfigurationFile(url: absoluteURL(path))
        let app = try options["--app"].map(absoluteURL)
        let plan = try file.preview(action: action, applicationURL: app, inboxPath: options["--inbox"])
        var backup: URL?
        if apply {
            guard let expected = options["--expect"], let backupPath = options["--backup-dir"] else { throw CLIError.invalidArguments }
            backup = try file.apply(plan, expectedFingerprint: expected, backupDirectory: absoluteURL(backupPath))
        } else if let backupPath = options["--backup-dir"] { _ = try absoluteURL(backupPath) }
        var report: [String: Any] = ["action": action.rawValue, "mode": apply ? (plan.changesFile ? "applied" : "unchanged") : "preview",
                                    "config_path": file.url.path, "plan_fingerprint": plan.fingerprint, "would_change": plan.changesFile,
                                    "config_written": apply && plan.changesFile, "managed_before": plan.managedBefore,
                                    "managed_after": plan.managedAfter, "forwards_existing_command": plan.forwardsExistingCommand,
                                    "codex_trust": "unchanged", "hooks_json": "unchanged"]
        if let backup { report["backup_path"] = backup.path }
        if let bridge = plan.bundledBridge {
            report["bridge_delivery"] = ["application_path": bridge.applicationURL.path, "sha256": bridge.sha256,
                                         "version": bridge.version, "build": bridge.build]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) + Data([10]))
    }

    private static func absoluteURL(_ value: String) throws -> URL {
        guard value.hasPrefix("/"), value.utf8.count <= 4096, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.split(separator: "/").contains("."), !value.split(separator: "/").contains("..") else { throw NotifyConfigurationError.invalidArguments }
        return URL(fileURLWithPath: value)
    }
}
