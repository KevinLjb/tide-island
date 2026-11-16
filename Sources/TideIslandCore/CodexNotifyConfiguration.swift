import Foundation

public struct NotifyConfigurationPlan: Sendable {
    public let action: HookConfigurationAction
    public let fingerprint: String
    public let managedBefore: Bool
    public let managedAfter: Bool
    public let forwardsExistingCommand: Bool
    public let bundledBridge: BundledBridge?
    public var changesFile: Bool { originalData != proposedData }
    let configurationPath: String
    let originalData: Data?
    let proposedData: Data?
    let inboxPath: String?
}

public enum CodexNotifyConfiguration {
    public static let maximumBytes = 1024 * 1024

    public static func plan(action: HookConfigurationAction, existing: Data?, configurationPath: String,
                            bundledBridge: BundledBridge? = nil, inboxPath: String? = nil) throws -> NotifyConfigurationPlan {
        try CodexHookConfiguration.validatePath(configurationPath)
        guard URL(fileURLWithPath: configurationPath).lastPathComponent == "config.toml" else { throw NotifyConfigurationError.invalidArguments }
        let document = try TOMLNotifyDocument(data: existing ?? Data())
        let managed = try document.arguments.flatMap { try NotifyDispatchConfiguration.managedCommand($0) }
        let proposed: Data?
        let originalArguments = managed?.originalArguments ?? document.arguments ?? []
        if action == .install {
            guard let bundledBridge else { throw NotifyConfigurationError.invalidArguments }
            let dispatcher = try NotifyDispatchConfiguration(restoresMissing: managed?.restoresMissing ?? (document.arguments == nil),
                                                              originalArguments: originalArguments, inboxPath: inboxPath)
            let desired = try dispatcher.command(bridgePath: bundledBridge.executableURL.path)
            if document.arguments == desired { proposed = existing }
            else { proposed = try document.replacing(with: desired) }
        } else {
            guard bundledBridge == nil, inboxPath == nil else { throw NotifyConfigurationError.invalidArguments }
            if let managed {
                if managed.restoresMissing { proposed = document.removing() }
                else { proposed = try document.replacing(with: managed.originalArguments) }
            } else { proposed = existing }
        }
        let evidence = bundledBridge.map { [$0.sha256, $0.version, $0.build] } ?? []
        let token = ["tide-island-notify-plan-v1", action.rawValue, configurationPath,
                     existing.map(CodexHookConfiguration.digest) ?? "missing", proposed.map(CodexHookConfiguration.digest) ?? "missing"] + evidence
        return NotifyConfigurationPlan(action: action, fingerprint: CodexHookConfiguration.digest(try JSONEncoder().encode(token)),
                                       managedBefore: managed != nil, managedAfter: action == .install,
                                       forwardsExistingCommand: !originalArguments.isEmpty, bundledBridge: bundledBridge,
                                       configurationPath: configurationPath, originalData: existing, proposedData: proposed, inboxPath: inboxPath)
    }
}
