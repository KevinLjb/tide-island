import Foundation

public enum NotifyConfigurationError: String, Error, LocalizedError, Sendable {
    case invalidDocument, unsupportedNotify, modifiedOwnedCommand, invalidArguments, limitExceeded
    case stalePlan, unsafeFile, busy, fileOperation

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "Cannot safely locate the top-level notify setting; the original TOML was preserved."
        case .unsupportedNotify: "The top-level notify must be a bounded array of single-line TOML strings."
        case .modifiedOwnedCommand: "The TideIsland notify command was modified; review it before changing configuration."
        case .invalidArguments: "Invalid notify dispatcher arguments."
        case .limitExceeded: "The notify configuration exceeds its bounded limits."
        case .stalePlan: "The notify configuration or application changed; generate a new preview."
        case .unsafeFile: "The notify configuration must be a regular file, not a symlink or special file."
        case .busy: "Another TideIsland notify configuration operation is running."
        case .fileOperation: "The notify configuration operation failed; inspect retained backups before retrying."
        }
    }
}

/// An argv envelope stored in the original notify setting, not in another
/// data store. Original arguments are forwarded as individual arguments, never
/// as shell text. A payload exists only for the current invocation.
public struct NotifyDispatchConfiguration: Equatable, Sendable {
    public static let marker = "--tide-island-notify-v1"
    public static let maximumArguments = 64
    public static let maximumArgumentBytes = 64 * 1024
    public let restoresMissing: Bool
    public let originalArguments: [String]
    public let inboxPath: String?

    public init(restoresMissing: Bool, originalArguments: [String], inboxPath: String? = nil) throws {
        guard originalArguments.count <= Self.maximumArguments,
              originalArguments.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumArgumentBytes else { throw NotifyConfigurationError.limitExceeded }
        guard !restoresMissing || originalArguments.isEmpty,
              originalArguments.first.map({ !$0.isEmpty }) != false,
              originalArguments.allSatisfy({ !$0.utf8.contains(0) }) else { throw NotifyConfigurationError.invalidArguments }
        if let inboxPath { try CodexHookConfiguration.validatePath(inboxPath) }
        // Generated ownership cannot be nested into its own forwarding route.
        guard !Self.claimsOwnership(originalArguments) else { throw NotifyConfigurationError.modifiedOwnedCommand }
        self.restoresMissing = restoresMissing; self.originalArguments = originalArguments; self.inboxPath = inboxPath
    }

    public func command(bridgePath: String) throws -> [String] {
        try CodexHookConfiguration.validatePath(bridgePath)
        guard URL(fileURLWithPath: bridgePath).lastPathComponent == BundledBridge.executableName,
              !bridgePath.split(separator: "/").contains(".build"), !bridgePath.split(separator: "/").contains("DerivedData") else {
            throw NotifyConfigurationError.invalidArguments
        }
        return [bridgePath, "notify-dispatch", Self.marker, restoresMissing ? "missing" : "array", inboxPath ?? "", String(originalArguments.count)]
            + originalArguments + ["--payload"]
    }

    public static func managedCommand(_ command: [String]) throws -> NotifyDispatchConfiguration? {
        guard claimsOwnership(command) else { return nil }
        guard command.count >= 7, command[1] == "notify-dispatch" else { throw NotifyConfigurationError.modifiedOwnedCommand }
        let configuration: NotifyDispatchConfiguration
        do { configuration = try decode(Array(command.dropFirst(2))) }
        catch { throw NotifyConfigurationError.modifiedOwnedCommand }
        guard try configuration.command(bridgePath: command[0]) == command else { throw NotifyConfigurationError.modifiedOwnedCommand }
        return configuration
    }

    public static func invocation(_ arguments: [String]) throws -> (configuration: NotifyDispatchConfiguration, payload: String) {
        guard arguments.count >= 6, let payload = arguments.last else { throw NotifyConfigurationError.invalidArguments }
        let configuration = try decode(Array(arguments.dropLast()))
        return (configuration, payload)
    }

    private static func decode(_ words: [String]) throws -> NotifyDispatchConfiguration {
        guard words.count >= 5, words[0] == marker, ["missing", "array"].contains(words[1]),
              let count = Int(words[3]), (0...maximumArguments).contains(count), words[3] == String(count),
              words.count == count + 5, words.last == "--payload" else { throw NotifyConfigurationError.invalidArguments }
        return try .init(restoresMissing: words[1] == "missing", originalArguments: Array(words[4..<(4 + count)]),
                         inboxPath: words[2].isEmpty ? nil : words[2])
    }

    private static func claimsOwnership(_ words: [String]) -> Bool {
        (words.count > 2 && words[2].hasPrefix("--tide-island-notify-")) ||
            (words.count > 1 && words[1] == "notify-dispatch" && URL(fileURLWithPath: words[0]).lastPathComponent == BundledBridge.executableName)
    }
}
