import CryptoKit
import Foundation

public enum HookConfigurationAction: String, Sendable {
    case install
    case uninstall
}

public struct HookConfigurationPlan: Sendable {
    public let action: HookConfigurationAction
    public let fingerprint: String
    public let managedHooksBefore: Int
    public let managedHooksAfter: Int
    public let command: String?
    public var changesFile: Bool { originalData != proposedData }

    let originalData: Data?
    let proposedData: Data?
    let bridgePath: String?
    let configurationPath: String?
}

/// Edits only a hooks.json document. config.toml, notify, inline hooks, and
/// Codex's trust state are deliberately outside this editor's write scope.
public enum CodexHookConfiguration {
    public static let maximumBytes = 1024 * 1024
    static let ownerStatus = "TideIsland lifecycle observer v1"
    static let commandPrefix = ": tide-island-observer-v1; "
    static let commandSuffix = " > /dev/null || :"

    public static func plan(
        action: HookConfigurationAction,
        existing: Data?,
        bridgePath: String? = nil,
        inboxPath: String? = nil,
        configurationPath: String? = nil
    ) throws -> HookConfigurationPlan {
        let original: ConfigurationJSON
        if let existing { original = try ConfigurationJSON.decode(existing) }
        else { original = .object([:]) }
        guard var root = original.object else { throw HookConfigurationError.invalidConfiguration }
        var events: [String: ConfigurationJSON] = [:]
        if let configured = root["hooks"] {
            guard let values = configured.object else { throw HookConfigurationError.invalidConfiguration }
            events = values
        }
        let command: String?
        let desired: ConfigurationJSON?
        if action == .install {
            guard let bridgePath else { throw HookConfigurationError.invalidPath }
            try validatePath(bridgePath)
            guard !bridgePath.split(separator: "/").contains(".build"),
                  !bridgePath.split(separator: "/").contains("DerivedData") else {
                throw HookConfigurationError.unstableBridgePath
            }
            if let inboxPath { try validatePath(inboxPath) }
            let words = [bridgePath, "hook"] + (inboxPath.map { ["--inbox", $0] } ?? [])
            command = makeCommand(words)
            desired = .object([
                "type": .string("command"), "command": .string(command!),
                "timeout": .number("3"), "statusMessage": .string(ownerStatus),
            ])
        } else {
            guard bridgePath == nil, inboxPath == nil else { throw HookConfigurationError.invalidPath }
            command = nil
            desired = nil
        }
        var before = 0
        var placed: Set<String> = []
        for name in events.keys.sorted() {
            guard let groups = events[name]?.array else { throw HookConfigurationError.invalidConfiguration }
            var retainedGroups: [ConfigurationJSON] = []
            for group in groups {
                guard var object = group.object else {
                    throw HookConfigurationError.invalidConfiguration
                }
                let handlers: [ConfigurationJSON]
                if let configured = object["hooks"] {
                    guard let values = configured.array else { throw HookConfigurationError.invalidConfiguration }
                    handlers = values
                } else { handlers = [] }
                var retained: [ConfigurationJSON] = []
                for handler in handlers {
                    guard let fields = handler.object else { throw HookConfigurationError.invalidConfiguration }
                    if try isOwned(fields) {
                        guard CodexHookEvent(rawValue: name) != nil else { throw HookConfigurationError.modifiedOwnedHook }
                        before += 1
                        if let desired, !placed.contains(name), Set(object.keys) == ["hooks"] {
                            retained.append(desired)
                            placed.insert(name)
                        }
                    } else { retained.append(handler) }
                }
                // Retain empty groups so later foreign groups keep their index.
                if object["hooks"] != nil || !retained.isEmpty { object["hooks"] = .array(retained) }
                retainedGroups.append(.object(object))
            }
            // Empty event arrays are harmless and may predate our installation.
            events[name] = .array(retainedGroups)
        }

        if let desired {
            for event in CodexHookEvent.allCases {
                if placed.contains(event.rawValue) { continue }
                var groups = events[event.rawValue]?.array ?? []
                if let empty = groups.firstIndex(where: { $0 == .object(["hooks": .array([])]) }) {
                    groups[empty] = .object(["hooks": .array([desired])])
                } else { groups.append(.object(["hooks": .array([desired])])) }
                events[event.rawValue] = .array(groups)
            }
        }
        // No-op uninstall must not create a file or reformat existing content.
        let proposed: Data?
        if action == .uninstall, before == 0 { proposed = existing }
        else {
            root["hooks"] = .object(events)
            let result = ConfigurationJSON.object(root)
            proposed = result == original ? existing : try result.encode()
        }
        let token = try JSONEncoder().encode([action.rawValue, configurationPath ?? "", revision(existing), revision(proposed)])
        return HookConfigurationPlan(
            action: action, fingerprint: digest(token), managedHooksBefore: before,
            managedHooksAfter: action == .install ? CodexHookEvent.allCases.count : 0,
            command: command, originalData: existing,
            proposedData: proposed, bridgePath: bridgePath, configurationPath: configurationPath
        )
    }

    static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".") else {
            throw HookConfigurationError.invalidPath
        }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func revision(_ data: Data?) -> String { data.map(digest) ?? "missing" }

    private static func makeCommand(_ words: [String]) -> String {
        commandPrefix + words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ") + commandSuffix
    }

    private static func isOwned(_ fields: [String: ConfigurationJSON]) throws -> Bool {
        let command = fields["command"]?.string ?? ""
        let claimsOwnership = fields["statusMessage"]?.string == ownerStatus || command.hasPrefix(commandPrefix)
        guard claimsOwnership else { return false }
        guard Set(fields.keys) == ["type", "command", "timeout", "statusMessage"],
              fields["type"] == .string("command"), fields["timeout"] == .number("3"),
              fields["statusMessage"] == .string(ownerStatus),
              command.hasPrefix(commandPrefix), command.hasSuffix(commandSuffix),
              let words = quotedWords(command.dropFirst(commandPrefix.count).dropLast(commandSuffix.count)),
              (words.count == 2 || words.count == 4), words[1] == "hook",
              words.count == 2 || words[2] == "--inbox", makeCommand(words) == command else {
            throw HookConfigurationError.modifiedOwnedHook
        }
        try validatePath(words[0])
        if words.count == 4 { try validatePath(words[3]) }
        return true
    }

    /// Accept only the exact POSIX quoting emitted above; never interpret shell.
    private static func quotedWords(_ value: Substring) -> [String]? {
        var rest = value
        var words: [String] = []
        while !rest.isEmpty {
            guard rest.popFirst() == "'" else { return nil }
            var word = ""
            var closed = false
            while let character = rest.popFirst() {
                if character != "'" { word.append(character); continue }
                if rest.hasPrefix("\\''") {
                    word.append("'")
                    rest = rest.dropFirst(3)
                } else { closed = true; break }
            }
            guard closed else { return nil }
            words.append(word)
            if !rest.isEmpty, rest.popFirst() != " " { return nil }
        }
        return words
    }
}

public enum HookConfigurationError: Error, LocalizedError {
    case invalidConfiguration
    case invalidPath
    case unstableBridgePath
    case modifiedOwnedHook
    case stalePlan
    case unsafeFile
    case busy
    case bridgeUnavailable
    case fileOperation

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Invalid, duplicate-key, oversized, or unsupported hooks JSON; no changes were written."
        case .invalidPath: "Use absolute paths without control characters or dot components."
        case .unstableBridgePath: "Choose a stable bridge path outside .build and DerivedData."
        case .modifiedOwnedHook: "A TideIsland-owned hook was modified; review it before configuration changes."
        case .stalePlan: "Configuration or options changed since preview; generate a new preview."
        case .unsafeFile: "Configuration must be a regular file, not a symlink or special file."
        case .busy: "Another TideIsland configuration operation is running."
        case .bridgeUnavailable: "The bridge at the selected stable path must be executable."
        case .fileOperation: "Configuration file operation failed; inspect the backup before retrying."
        }
    }
}
