import Foundation
import TideIslandCore

enum IntegrationCommand {
    static func run(_ arguments: [String]) throws {
        guard let name = arguments.first, let action = HookConfigurationAction(rawValue: name) else { throw CLIError.invalidArguments }
        let tail = Array(arguments.dropFirst())
        guard tail.filter({ $0 == "--apply" }).count <= 1 else { throw CLIError.invalidArguments }
        let apply = tail.contains("--apply")
        var allowed: Set<String> = ["--codex-directory", "--expect", "--backup-dir", "--inbox"]
        if action == .install { allowed.insert("--app") }
        else { allowed.formUnion(["--data", "--state-directory", "--scan-limit", "--read-budget-bytes"]) }
        let options = try TideIslandBridge.parseOptions(tail.filter { $0 != "--apply" }, allowed: allowed)
        guard let source = options["--codex-directory"], apply || options["--expect"] == nil else { throw CLIError.invalidArguments }
        let directory = try absoluteURL(source).resolvingSymlinksInPath()
        let hooks = try HookConfigurationFile(url: directory.appendingPathComponent("hooks.json"))
        let notify = try NotifyConfigurationFile(url: directory.appendingPathComponent("config.toml"))
        let hooksPlan: HookConfigurationPlan
        if action == .install {
            guard let path = options["--app"] else { throw CLIError.invalidArguments }
            hooksPlan = try hooks.previewBundledInstall(applicationURL: absoluteURL(path), inboxPath: options["--inbox"])
        } else { hooksPlan = try hooks.preview(action: .uninstall) }
        let app = try options["--app"].map(absoluteURL)
        let notifyPlan = try notify.preview(action: action, applicationURL: app, inboxPath: action == .install ? options["--inbox"] : nil)
        guard let dataAction = IntegrationDataAction(rawValue: options["--data"] ?? "keep") else { throw CLIError.invalidArguments }
        var state: SessionStateFile?
        var reset: SessionResetPreview?
        var limits = InboxReadLimits()
        if dataAction == .clearSessionState {
            guard let inboxPath = options["--inbox"] else { throw CLIError.invalidArguments }
            let inbox = EventInbox(directory: try absoluteURL(inboxPath))
            state = SessionStateFile(inbox: inbox, directory: try options["--state-directory"].map(absoluteURL))
            func integer(_ key: String, fallback: Int) throws -> Int {
                guard let text = options[key] else { return fallback }
                guard let number = Int(text), number > 0 else { throw CLIError.invalidArguments }
                return number
            }
            limits = try InboxReadLimits(maximumFiles: integer("--scan-limit", fallback: limits.maximumFiles),
                                         maximumReadBytes: Int64(integer("--read-budget-bytes", fallback: Int(limits.maximumReadBytes))))
            reset = try state?.previewReset(limits: limits)
        } else {
            guard options["--state-directory"] == nil, options["--scan-limit"] == nil, options["--read-budget-bytes"] == nil else { throw CLIError.invalidArguments }
        }
        let plan = try CodexIntegrationPlan(hooks: hooksPlan, notify: notifyPlan, dataAction: dataAction, stateFile: state, resetPreview: reset)
        var report: [String: Any] = ["action": action.rawValue, "mode": "preview", "codex_directory": directory.path,
                                    "plan_fingerprint": plan.fingerprint, "hooks_would_change": hooksPlan.changesFile,
                                    "notify_would_change": notifyPlan.changesFile, "data_action": dataAction.rawValue,
                                    "event_files": "preserved", "display_preferences": "preserved", "codex_trust": "unchanged",
                                    "cross_file_transaction": false]
        if let reset, let state { report["session_reset"] = ["event_files": reset.eventFiles, "state_path": state.fileURL.path] }
        if !apply {
            if let path = options["--backup-dir"] { _ = try absoluteURL(path) }
            try output(report); return
        }
        guard let expected = options["--expect"], expected == plan.fingerprint else { throw IntegrationConfigurationError.stalePlan }
        guard let path = options["--backup-dir"] else { throw CLIError.invalidArguments }
        let backupDirectory = try absoluteURL(path)
        var completed: [String] = []
        var retainedBackups: [String: String] = [:]
        var step = "session-state"
        do {
            // A busy state lease fails before changing either Codex file.
            if let state, let reset { _ = try state.applyReset(reset, expectedFingerprint: reset.fingerprint, limits: limits); completed.append(step) }
            func applyHooks() throws {
                step = "hooks"
                if let backup = try hooks.apply(hooksPlan, expectedFingerprint: hooksPlan.fingerprint, backupDirectory: backupDirectory) {
                    retainedBackups[step] = backup.path
                }
                completed.append(step)
            }
            func applyNotify() throws {
                step = "notify"
                if let backup = try notify.apply(notifyPlan, expectedFingerprint: notifyPlan.fingerprint, backupDirectory: backupDirectory) {
                    retainedBackups[step] = backup.path
                }
                completed.append(step)
            }
            if action == .install { try applyHooks(); try applyNotify() }
            else { try applyNotify(); try applyHooks() }
        } catch {
            report["mode"] = "incomplete"; report["failed_step"] = step
            report["completed_steps"] = completed; report["backups"] = retainedBackups
            report["backup_directory"] = backupDirectory.path; report["failure_code"] = failureCode(error)
            try output(report)
            throw IntegrationConfigurationError.incomplete
        }
        report["mode"] = hooksPlan.changesFile || notifyPlan.changesFile || reset != nil ? "applied" : "unchanged"
        report["completed_steps"] = completed; report["backups"] = retainedBackups
        report["session_state"] = reset == nil ? "preserved" : "cleared"
        try output(report)
    }

    private static func output(_ report: [String: Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) + Data([10]))
    }
    private static func failureCode(_ error: any Error) -> String {
        if let error = error as? NotifyConfigurationError { return "notify-" + error.rawValue }
        if let error = error as? BundledBridgeError { return "bundle-" + error.rawValue }
        if let error = error as? SessionStateError { return "state-" + error.rawValue }
        if let error = error as? InboxError {
            switch error {
            case .receiverAlreadyRunning: return "inbox-receiver-in-use"
            case .busy: return "inbox-busy"
            case .changedDuringRead, .stalePlan: return "inbox-changed"
            case .limitExceeded: return "inbox-limit"
            case .unsafeDirectory, .unmanagedDirectory, .unsafeFile: return "inbox-unavailable"
            case .invalidPolicy, .fileOperation, .conflictingEventID, .cleanupIncomplete, .recoveryRequired: return "inbox-operation"
            }
        }
        if error is HookConfigurationError { return "hook-configuration" }
        return "file-operation"
    }
    private static func absoluteURL(_ value: String) throws -> URL {
        guard value.hasPrefix("/"), value.utf8.count <= 4096, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.split(separator: "/").contains("."), !value.split(separator: "/").contains("..") else { throw CLIError.invalidArguments }
        return URL(fileURLWithPath: value)
    }
}
