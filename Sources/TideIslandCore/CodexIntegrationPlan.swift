import Foundation

public enum IntegrationDataAction: String, Sendable { case keep, clearSessionState = "clear-state" }

public enum IntegrationConfigurationError: String, Error, LocalizedError, Sendable {
    case inconsistentPlans, stalePlan, incomplete
    public var errorDescription: String? {
        switch self {
        case .inconsistentPlans: "Integration plans must share a directory, action, bundle and inbox; check the data choice."
        case .stalePlan: "The integration configuration, application or selected session data changed; preview again."
        case .incomplete: "Integration was not fully applied; inspect the progress report and retained backups, then preview again."
        }
    }
}

/// Binds review across independent file operations. It does not claim a
/// transaction across hooks, notify and state or automatically roll back files.
public struct CodexIntegrationPlan: Sendable {
    public let fingerprint: String
    public let action: HookConfigurationAction
    public let directory: URL
    public let hooks: HookConfigurationPlan
    public let notify: NotifyConfigurationPlan
    public let dataAction: IntegrationDataAction
    public let stateFile: SessionStateFile?
    public let resetPreview: SessionResetPreview?

    public init(hooks: HookConfigurationPlan, notify: NotifyConfigurationPlan, dataAction: IntegrationDataAction = .keep,
                stateFile: SessionStateFile? = nil, resetPreview: SessionResetPreview? = nil) throws {
        guard let hooksPath = hooks.configurationPath, hooks.action == notify.action, hooks.inboxPath == notify.inboxPath else {
            throw IntegrationConfigurationError.inconsistentPlans
        }
        let directory = URL(fileURLWithPath: hooksPath).deletingLastPathComponent()
        guard directory.appendingPathComponent("hooks.json").path == hooksPath,
              directory.appendingPathComponent("config.toml").path == notify.configurationPath else {
            throw IntegrationConfigurationError.inconsistentPlans
        }
        if hooks.action == .install {
            guard hooks.bundledBridge != nil, hooks.bundledBridge == notify.bundledBridge else { throw IntegrationConfigurationError.inconsistentPlans }
        } else {
            guard hooks.bundledBridge == nil, notify.bundledBridge == nil else { throw IntegrationConfigurationError.inconsistentPlans }
        }
        switch dataAction {
        case .keep:
            guard stateFile == nil, resetPreview == nil else { throw IntegrationConfigurationError.inconsistentPlans }
        case .clearSessionState:
            guard hooks.action == .uninstall, let stateFile, let resetPreview, resetPreview.scope == stateFile.scope else {
                throw IntegrationConfigurationError.inconsistentPlans
            }
        }
        let token = ["tide-island-integration-plan-v1", hooks.action.rawValue, directory.path, hooks.fingerprint, notify.fingerprint,
                     dataAction.rawValue, stateFile?.fileURL.path ?? "", resetPreview?.fingerprint ?? ""]
        fingerprint = CodexHookConfiguration.digest(try JSONEncoder().encode(token))
        action = hooks.action; self.directory = directory; self.hooks = hooks; self.notify = notify
        self.dataAction = dataAction; self.stateFile = stateFile; self.resetPreview = resetPreview
    }
}
