import Darwin
import Foundation
import Testing
@testable import TideIslandCore

private let existingHookData = Data(#"{"description":"fixture-private-description","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo fixture-private-command","timeout":9}]}],"Stop":[{"hooks":[{"type":"command","command":"echo tide-island-is-just-a-name"}]}]}}"#.utf8)

@Test func hookInstallIsIdempotentAndPreservesForeignDefinitions() throws {
    let original = try ConfigurationJSON.decode(existingHookData)
    let installed = try CodexHookConfiguration.plan(action: .install, existing: existingHookData, bridgePath: "/Applications/TideIsland/bridge")
    let data = try #require(installed.proposedData)
    #expect(installed.managedHooksBefore == 0)
    #expect(installed.managedHooksAfter == 6)
    let root = try #require(ConfigurationJSON.decode(data).object)
    #expect(root["description"] == original.object?["description"])
    #expect(root["hooks"]?.object?["PreToolUse"]?.array?.first == original.object?["hooks"]?.object?["PreToolUse"]?.array?.first)
    #expect(root["hooks"]?.object?["Stop"] == original.object?["hooks"]?.object?["Stop"])
    let again = try CodexHookConfiguration.plan(action: .install, existing: data, bridgePath: "/Applications/TideIsland/bridge")
    #expect(!again.changesFile)
    #expect(again.proposedData == data)

    let removed = try CodexHookConfiguration.plan(action: .uninstall, existing: data)
    let after = try ConfigurationJSON.decode(#require(removed.proposedData))
    #expect(after.object?["description"] == original.object?["description"])
    #expect(after.object?["hooks"]?.object?["PreToolUse"]?.array?.first == original.object?["hooks"]?.object?["PreToolUse"]?.array?.first)
    #expect(after.object?["hooks"]?.object?["Stop"] == original.object?["hooks"]?.object?["Stop"])
    #expect(removed.managedHooksBefore == 6)
    #expect(removed.managedHooksAfter == 0)
    let noOp = try CodexHookConfiguration.plan(action: .uninstall, existing: removed.proposedData)
    #expect(!noOp.changesFile)
}

@Test func hookUpgradeAndUninstallKeepLaterForeignGroupIndexes() throws {
    let install = try CodexHookConfiguration.plan(action: .install, existing: nil, bridgePath: "/stable/old")
    var root = try #require(ConfigurationJSON.decode(#require(install.proposedData)).object)
    var events = try #require(root["hooks"]?.object)
    let foreign: ConfigurationJSON = .object(["hooks": .array([.object(["type": .string("command"), "command": .string("echo later")])])])
    var groups = try #require(events["PreToolUse"]?.array)
    groups.append(foreign)
    events["PreToolUse"] = .array(groups)
    root["hooks"] = .object(events)
    let before = try ConfigurationJSON.object(root).encode()
    let upgrade = try CodexHookConfiguration.plan(action: .install, existing: before, bridgePath: "/stable/new")
    let upgraded = try ConfigurationJSON.decode(#require(upgrade.proposedData))
    #expect(upgraded.object?["hooks"]?.object?["PreToolUse"]?.array?[1] == foreign)
    #expect(upgrade.managedHooksBefore == 6)
    #expect(upgrade.managedHooksAfter == 6)
    let uninstall = try CodexHookConfiguration.plan(action: .uninstall, existing: upgrade.proposedData)
    let uninstalled = try ConfigurationJSON.decode(#require(uninstall.proposedData))
    #expect(uninstalled.object?["hooks"]?.object?["PreToolUse"]?.array?[0] == .object(["hooks": .array([])]))
    #expect(uninstalled.object?["hooks"]?.object?["PreToolUse"]?.array?[1] == foreign)
    let reinstall = try CodexHookConfiguration.plan(action: .install, existing: uninstall.proposedData, bridgePath: "/stable/new")
    #expect(reinstall.proposedData == upgrade.proposedData)
}

@Test func codexDefaultEmptyGroupsRemainValidAndForeignNoOpKeepsOriginalBytes() throws {
    let input = Data(#"{ "description": "keep layout", "hooks": {"Stop":[{}, {"matcher":"Bash"}],"PreToolUse":[{"matcher":"Bash"}]}}"#.utf8)
    let noOp = try CodexHookConfiguration.plan(action: .uninstall, existing: input)
    #expect(noOp.proposedData == input)
    #expect(!noOp.changesFile)
    let install = try CodexHookConfiguration.plan(action: .install, existing: input, bridgePath: "/stable/bridge")
    let after = try ConfigurationJSON.decode(#require(install.proposedData))
    let original = try ConfigurationJSON.decode(input)
    #expect(after.object?["hooks"]?.object?["Stop"] == original.object?["hooks"]?.object?["Stop"])
    #expect(after.object?["hooks"]?.object?["PreToolUse"]?.array?.first == .object(["matcher": .string("Bash")]))
}

@Test func removingAnOwnedHandlerKeepsItsForeignNeighbors() throws {
    let install = try CodexHookConfiguration.plan(action: .install, existing: nil, bridgePath: "/stable/bridge")
    var root = try #require(ConfigurationJSON.decode(#require(install.proposedData)).object)
    var events = try #require(root["hooks"]?.object)
    let own = try #require(events["PreToolUse"]?.array?.first?.object?["hooks"]?.array?.first)
    let foreign: ConfigurationJSON = .object(["type": .string("command"), "command": .string("echo neighbor")])
    events["PreToolUse"] = .array([.object(["matcher": .string("Bash"), "hooks": .array([foreign, own, foreign])])])
    root["hooks"] = .object(events)
    let remove = try CodexHookConfiguration.plan(action: .uninstall, existing: ConfigurationJSON.object(root).encode())
    let parsed = try ConfigurationJSON.decode(#require(remove.proposedData))
    #expect(parsed.object?["hooks"]?.object?["PreToolUse"]?.array?.first == .object([
        "matcher": .string("Bash"), "hooks": .array([foreign, foreign]),
    ]))
}

@Test func modifiedOwnershipMarkersCauseAConflictRatherThanDeletingCommands() throws {
    let install = try CodexHookConfiguration.plan(action: .install, existing: nil, bridgePath: "/stable/bridge")
    let data = try #require(install.proposedData)
    let modified = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: #""timeout": 3"#, with: #""timeout": 4"#).utf8)
    for action in [HookConfigurationAction.install, .uninstall] {
        #expect(throws: HookConfigurationError.self) {
            try CodexHookConfiguration.plan(action: action, existing: modified, bridgePath: action == .install ? "/stable/bridge" : nil)
        }
    }
}

@Test func configurationJSONPreservesUnknownValuesAndExactNumberTokens() throws {
    let input = Data(#"{"future":{"integer":1234567890123456789012345678901234567890,"fraction":0.123456789012345678901234567890,"exponent":1e9999,"array":[true,false,null,"\u4f60\u597d"]},"hooks":{}}"#.utf8)
    let install = try CodexHookConfiguration.plan(action: .install, existing: input, bridgePath: "/stable/bridge")
    let parsed = try ConfigurationJSON.decode(#require(install.proposedData))
    let original = try ConfigurationJSON.decode(input)
    #expect(parsed.object?["future"] == original.object?["future"])
    let output = String(decoding: try #require(install.proposedData), as: UTF8.self)
    #expect(output.contains("1234567890123456789012345678901234567890"))
    #expect(output.contains("0.123456789012345678901234567890"))
    #expect(output.contains("1e9999"))
}

@Test func malformedDuplicateAndDeepConfigurationCannotBeRewritten() {
    for input in [
        "", "[]", "null", #"{"hooks":[]}"#, #"{"hooks":{"PreToolUse":[{"hooks":42}]}}"#,
        #"{"hooks":{},"\u0068ooks":{}}"#, #"{"hooks":{"Stop":[],"Stop":[]}}"#,
        #"{"hooks":{},}"#, #"{"hooks":{},"number":01}"#, #"{"hooks":{},"number":1.}"#,
        #"{"hooks":{},"string":"\x12"}"#, "{\"deep\":" + String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65) + "}",
    ] {
        #expect(throws: HookConfigurationError.self) {
            try CodexHookConfiguration.plan(action: .install, existing: Data(input.utf8), bridgePath: "/stable/bridge")
        }
    }
    #expect(throws: HookConfigurationError.self) {
        try CodexHookConfiguration.plan(action: .uninstall, existing: Data(repeating: 0x20, count: CodexHookConfiguration.maximumBytes + 1))
    }
}

@Test func observerCommandsCanRoundTripQuotedPathsAndRejectUnstablePaths() throws {
    let path = "/stable/it's a bridge $(literal)`literal`"
    let install = try CodexHookConfiguration.plan(action: .install, existing: nil, bridgePath: path, inboxPath: "/events/it's literal")
    let again = try CodexHookConfiguration.plan(action: .install, existing: install.proposedData, bridgePath: path, inboxPath: "/events/it's literal")
    #expect(!again.changesFile)
    for invalid in ["relative", "/stable/../bridge", "/stable/./bridge", "/stable/bridge\n", "/repo/.build/release/bridge", "/cache/DerivedData/bridge"] {
        #expect(throws: HookConfigurationError.self) {
            try CodexHookConfiguration.plan(action: .install, existing: nil, bridgePath: invalid)
        }
    }
}

@Test func previewAndNoOpUninstallHaveNoFilesystemSideEffects() throws {
    let root = try hookTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("missing/.codex/hooks.json")
    let file = try HookConfigurationFile(url: config)
    let preview = try file.preview(action: .install, bridgePath: "/bin/true")
    #expect(preview.changesFile)
    let noOp = try file.preview(action: .uninstall)
    #expect(!noOp.changesFile)
    #expect(try file.apply(noOp, expectedFingerprint: noOp.fingerprint, backupDirectory: root.appendingPathComponent("backups")) == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
}

@Test func applyBacksUpOriginalBytesAndRetainsConfigurationPermissions() throws {
    let root = try hookTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("hooks.json")
    try existingHookData.write(to: config)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: config.path)
    let file = try HookConfigurationFile(url: config)
    let plan = try file.preview(action: .install, bridgePath: "/bin/true")
    let backup = try #require(file.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: root.appendingPathComponent("backups")))
    #expect(try Data(contentsOf: backup.appendingPathComponent("hooks.json.before")) == existingHookData)
    #expect(try permissions(config) == 0o640)
    #expect(try permissions(backup) == 0o700)
    #expect(try permissions(backup.appendingPathComponent("hooks.json.before")) == 0o600)
    let after = try Data(contentsOf: config)
    let noOp = try file.preview(action: .install, bridgePath: "/bin/true")
    #expect(!noOp.changesFile)
    #expect(try file.apply(noOp, expectedFingerprint: noOp.fingerprint, backupDirectory: root.appendingPathComponent("other-backups")) == nil)
    #expect(try Data(contentsOf: config) == after)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("other-backups").path))
}

@Test func oldPreviewsCannotOverwriteEditedFilesOrOtherTargets() throws {
    let root = try hookTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("hooks.json")
    try existingHookData.write(to: config)
    let file = try HookConfigurationFile(url: config)
    let plan = try file.preview(action: .install, bridgePath: "/bin/true")
    let changed = Data(#"{"description":"edited","hooks":{}}"#.utf8)
    try changed.write(to: config)
    #expect(throws: HookConfigurationError.self) {
        try file.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: root.appendingPathComponent("backups"))
    }
    #expect(try Data(contentsOf: config) == changed)
    let other = try HookConfigurationFile(url: root.appendingPathComponent("other/hooks.json"))
    #expect(throws: HookConfigurationError.self) {
        try other.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: root.appendingPathComponent("backups"))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
}

@Test func failedBackupsAndChangedPlanOptionsLeaveOriginalConfigurationIntact() throws {
    let root = try hookTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("hooks.json")
    try existingHookData.write(to: config)
    let file = try HookConfigurationFile(url: config)
    let plan = try file.preview(action: .install, bridgePath: "/bin/true")
    let changed = try file.preview(action: .install, bridgePath: "/bin/echo")
    #expect(throws: HookConfigurationError.self) {
        try file.apply(changed, expectedFingerprint: plan.fingerprint, backupDirectory: root.appendingPathComponent("backups"))
    }
    let blocked = root.appendingPathComponent("not-a-directory")
    try Data("blocked".utf8).write(to: blocked)
    #expect(throws: (any Error).self) {
        try file.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: blocked)
    }
    #expect(try Data(contentsOf: config) == existingHookData)
}

@Test func symlinkAndBusyConfigurationTargetsAreRejected() throws {
    let root = try hookTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("hooks.json")
    let other = root.appendingPathComponent("original.json")
    try existingHookData.write(to: other)
    try FileManager.default.createSymbolicLink(at: config, withDestinationURL: other)
    let file = try HookConfigurationFile(url: config)
    #expect(throws: HookConfigurationError.self) { try file.preview(action: .uninstall) }
    try FileManager.default.removeItem(at: config)
    try existingHookData.write(to: config)
    let plan = try file.preview(action: .install, bridgePath: "/bin/true")
    let descriptor = open(root.appendingPathComponent(".tide-island-hooks.lock").path, O_RDWR | O_CREAT, 0o600)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    defer { flock(descriptor, LOCK_UN) }
    #expect(throws: HookConfigurationError.self) {
        try file.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: root.appendingPathComponent("backups"))
    }
    #expect(try Data(contentsOf: other) == existingHookData)
    #expect(try Data(contentsOf: config) == existingHookData)
}

private func hookTestDirectory() throws -> URL {
    let base = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory
    let root = base.appendingPathComponent("tide-island-hooks-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
