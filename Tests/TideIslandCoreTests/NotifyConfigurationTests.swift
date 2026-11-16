import Foundation
import Testing
@testable import TideIslandCore

@Test func notifyInstallAddsRootBeforeTablesAndUninstallPreservesTheOriginalRegion() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = Data("# original\n[profiles.dev]\nnotify = ['profile-tool']\n".utf8)
    let plan = try notifyPlan(original, bridge: fixture.bridge)
    let proposed = try #require(plan.proposedData)
    #expect(plan.changesFile && !plan.managedBefore && plan.managedAfter && !plan.forwardsExistingCommand)
    #expect(proposed.suffix(original.count) == original)
    let remove = try CodexNotifyConfiguration.plan(action: .uninstall, existing: proposed, configurationPath: fixture.config)
    let removed = try #require(remove.proposedData)
    let parsed = try TOMLNotifyDocument(data: removed)
    #expect(parsed.arguments == nil && removed.suffix(original.count) == original)
}

@Test func notifyInstallForwardsEachOriginalArgumentAndPreservesOtherBytesAndComments() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let prefix = "# header\r\n\"notify\" = ", suffix = " # retained\r\nmodel='gpt-fixture'\r\n[profile.dev]\r\nnotify=['profile']\r\n"
    let original = Data((prefix + "[ 'foreign-notifier', # argv comment\r\n '--literal', '$(touch no) `no`', ]" + suffix).utf8)
    let plan = try notifyPlan(original, bridge: fixture.bridge)
    let data = try #require(plan.proposedData), document = try TOMLNotifyDocument(data: data)
    let words = try #require(document.arguments)
    let configuration = try NotifyDispatchConfiguration.managedCommand(words)
    #expect(configuration?.originalArguments == ["foreign-notifier", "--literal", "$(touch no) `no`"])
    #expect(configuration?.restoresMissing == false && plan.forwardsExistingCommand)
    #expect(data.starts(with: Data(prefix.utf8)) && data.suffix(suffix.utf8.count) == Data(suffix.utf8))
}

@Test func notifyRepeatedInstallIsByteExactAndDoesNotNestDispatchers() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try notifyPlan(Data("notify=['foreign', 'one']\n".utf8), bridge: fixture.bridge)
    let data = try #require(first.proposedData)
    let again = try notifyPlan(data, bridge: fixture.bridge)
    #expect(!again.changesFile && again.proposedData == data && again.managedBefore)
    let document = try TOMLNotifyDocument(data: data)
    let words = try #require(document.arguments)
    let dispatch = try NotifyDispatchConfiguration.managedCommand(words)
    #expect(dispatch?.originalArguments == ["foreign", "one"])
}

@Test func notifyMovedBundleRepairsWrapperAndKeepsOriginalCommand() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let initial = try notifyPlan(Data("notify=['foreign', '--value']\n".utf8), bridge: fixture.bridge)
    let data = try #require(initial.proposedData)
    let moved = fixture.root.appendingPathComponent("Moved.app")
    try FileManager.default.moveItem(at: fixture.bridge.applicationURL, to: moved)
    let bridge = try BundledBridge.inspect(applicationURL: moved)
    let repair = try notifyPlan(data, bridge: bridge)
    let repaired = try #require(repair.proposedData)
    let parsed = try TOMLNotifyDocument(data: repaired), words = try #require(parsed.arguments)
    let configuration = try NotifyDispatchConfiguration.managedCommand(words)
    #expect(words.first == bridge.executableURL.path && configuration?.originalArguments == ["foreign", "--value"])
    #expect(repair.changesFile && repair.fingerprint != initial.fingerprint)
}

@Test func notifyUninstallRestoresOriginalArgumentValuesAndPreservesLaterEdits() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let initial = try notifyPlan(Data("notify=['foreign', ''] # keep\nmodel='fixture'\n".utf8), bridge: fixture.bridge)
    let proposed = try #require(initial.proposedData)
    let data = proposed + Data("[later]\nvalue=7\n".utf8)
    let removed = try CodexNotifyConfiguration.plan(action: .uninstall, existing: data, configurationPath: fixture.config)
    let restored = try #require(removed.proposedData), document = try TOMLNotifyDocument(data: restored)
    #expect(document.arguments == ["foreign", ""] && removed.managedBefore && !removed.managedAfter)
    #expect(String(decoding: restored, as: UTF8.self).contains("# keep\nmodel='fixture'\n[later]\nvalue=7\n"))
}

@Test func notifyUninstallWithoutOwnershipIsByteExactAndMissingStaysMissing() throws {
    let path = "/isolated/config.toml", original = Data("notify = [ 'foreign' ]\n".utf8)
    let existing = try CodexNotifyConfiguration.plan(action: .uninstall, existing: original, configurationPath: path)
    let missing = try CodexNotifyConfiguration.plan(action: .uninstall, existing: nil, configurationPath: path)
    #expect(!existing.changesFile && existing.proposedData == original && !existing.managedBefore)
    #expect(!missing.changesFile && missing.proposedData == nil)
}

@Test func notifyEmptyArrayRemainsExplicitAfterUninstall() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let install = try notifyPlan(Data("notify=[]\n".utf8), bridge: fixture.bridge)
    let data = try #require(install.proposedData)
    let remove = try CodexNotifyConfiguration.plan(action: .uninstall, existing: data, configurationPath: fixture.config)
    let restored = try #require(remove.proposedData), document = try TOMLNotifyDocument(data: restored)
    #expect(document.arguments == [] && !install.forwardsExistingCommand)
}

@Test func notifyLocatorSkipsMultilineStringsNestedValuesAndProfileSettings() throws {
    let source = #"""
    instructions = """
    notify = ['inside-basic-string']
    [not.a.table]
    """
    literal = '''
    notify=['inside-literal-string']
    '''
    values = [{"nested" = ["notify", "# [ ]", {other="quoted"}]}]
    notify = ["root", "--payload"] # exact root
    [profiles."dev.env"]
    notify=['profile']
    """#
    let document = try TOMLNotifyDocument(data: Data(source.utf8))
    #expect(document.arguments == ["root", "--payload"])
    let changed = try document.replacing(with: ["replacement"])
    #expect(String(decoding: changed, as: UTF8.self).contains("notify=['inside-literal-string']"))
    #expect(String(decoding: changed, as: UTF8.self).contains("notify=['profile']"))
}

@Test func notifyQuotedKeysAndUnicodeEscapesHaveTheSameRootIdentity() throws {
    for key in ["notify", "'notify'", #""\u006eotify""#, #""\U0000006Eotify""#] {
        let source = Data((key + " = [\"caf\\u00e9\", '\\literal', \"\\U0001F30A\"]\n").utf8)
        let document = try TOMLNotifyDocument(data: source)
        #expect(document.arguments == ["café", "\\literal", "🌊"])
    }
}

@Test func notifyDuplicateDottedOrTableDefinitionsAreRejected() {
    for source in ["notify=[]\nnotify=[]", "'notify'=[]\n\"notify\"=[]", "notify.value=[]", "[notify]\nvalue=1", "[[notify]]\nvalue=1"] {
        #expect(throws: NotifyConfigurationError.self) { try TOMLNotifyDocument(data: Data(source.utf8)) }
    }
}

@Test func notifyMalformedAndUnsupportedValuesArePreservedByRejectingTheEdit() {
    for source in ["notify='command'", "notify=[1]", "notify=[\"one\" \"two\"]", "notify=[\"unterminated]", "notify=[\"bad\\x01\"]",
                   "notify=[\"\\uD800\"]", "notify=[\"\\u0000\"]", "notify=[\"\"]", "notify=[\"\"\"multiline\"\"\"]",
                   "value={nested=[1,2}", "instructions=\"\"\"unfinished", "notify=", "\u{FEFF}notify=[]"] {
        #expect(throws: NotifyConfigurationError.self) { try TOMLNotifyDocument(data: Data(source.utf8)) }
    }
}

@Test func notifyRenderingPreservesNonBMPControlEscapesAndArgumentBoundaries() throws {
    let words = ["notify-tool", "🌊", "quote\" slash\\", "line\nnext\tvalue", "\u{01}", "", "--payload", "$(literal) `literal`"]
    let rendered = TOMLNotifyDocument.render(words)
    let parsed = try TOMLNotifyDocument(data: Data(("notify=" + rendered).utf8))
    #expect(parsed.arguments == words)
    #expect(!rendered.contains("\\/"))
}

@Test func notifyConfigurationAndCommandLimitsAreBounded() {
    #expect(throws: NotifyConfigurationError.limitExceeded) { try TOMLNotifyDocument(data: Data(repeating: 32, count: CodexNotifyConfiguration.maximumBytes + 1)) }
    let tooMany = TOMLNotifyDocument.render(Array(repeating: "arg", count: NotifyDispatchConfiguration.maximumArguments + 1))
    #expect(throws: NotifyConfigurationError.limitExceeded) { try TOMLNotifyDocument(data: Data(("notify=" + tooMany).utf8)) }
    #expect(throws: NotifyConfigurationError.limitExceeded) {
        try NotifyDispatchConfiguration(restoresMissing: false, originalArguments: [String(repeating: "x", count: NotifyDispatchConfiguration.maximumArgumentBytes + 1)])
    }
}

@Test func notifyFingerprintBindsTargetInputOptionsAndBundleEvenForNoOp() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = Data("notify=['foreign']\n".utf8), first = try notifyPlan(original, bridge: fixture.bridge)
    let target = try CodexNotifyConfiguration.plan(action: .install, existing: original, configurationPath: "/other/config.toml", bundledBridge: fixture.bridge)
    let option = try CodexNotifyConfiguration.plan(action: .install, existing: original, configurationPath: fixture.config, bundledBridge: fixture.bridge, inboxPath: "/isolated/Events")
    #expect(first.fingerprint != target.fingerprint && first.fingerprint != option.fingerprint)
    let installed = try #require(first.proposedData)
    let unchanged = try notifyPlan(installed, bridge: fixture.bridge)
    let infoURL = fixture.bridge.applicationURL.appendingPathComponent("Contents/Info.plist")
    let rawInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
    var info = try #require(rawInfo as? [String: Any]); info["CFBundleVersion"] = "2"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    let bridge = try BundledBridge.inspect(applicationURL: fixture.bridge.applicationURL)
    let upgraded = try notifyPlan(installed, bridge: bridge)
    #expect(!unchanged.changesFile && !upgraded.changesFile && unchanged.fingerprint != upgraded.fingerprint)
}

@Test func notifyConfigurationRejectsWrongPathsAndInvalidActionOptions() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(throws: NotifyConfigurationError.self) { try CodexNotifyConfiguration.plan(action: .install, existing: nil, configurationPath: fixture.config) }
    #expect(throws: NotifyConfigurationError.self) {
        try CodexNotifyConfiguration.plan(action: .uninstall, existing: nil, configurationPath: fixture.config, bundledBridge: fixture.bridge)
    }
    #expect(throws: NotifyConfigurationError.self) {
        try CodexNotifyConfiguration.plan(action: .install, existing: nil, configurationPath: "/isolated/hooks.json", bundledBridge: fixture.bridge)
    }
}

@Test func notifyDispatcherRecoversOriginalArgumentsWithoutInterpretingPayloadFlags() throws {
    let config = try NotifyDispatchConfiguration(restoresMissing: false, originalArguments: ["foreign", "--payload", "", "$(literal)"], inboxPath: "/isolated/Events")
    let command = try config.command(bridgePath: "/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge")
    let invocation = try NotifyDispatchConfiguration.invocation(Array(command.dropFirst(2)) + ["{\"fixture\":\"body\"}"])
    #expect(invocation.configuration == config && invocation.payload == "{\"fixture\":\"body\"}")
}

@Test func notifyDispatcherPreservesMissingVersusExplicitEmptyArray() throws {
    let missing = try NotifyDispatchConfiguration(restoresMissing: true, originalArguments: [])
    let empty = try NotifyDispatchConfiguration(restoresMissing: false, originalArguments: [])
    let path = "/stable/tide-island-bridge"
    let missingWords = try missing.command(bridgePath: path), emptyWords = try empty.command(bridgePath: path)
    let missingDecoded = try NotifyDispatchConfiguration.managedCommand(missingWords), emptyDecoded = try NotifyDispatchConfiguration.managedCommand(emptyWords)
    #expect(missingDecoded?.restoresMissing == true && emptyDecoded?.restoresMissing == false)
    #expect(missingWords != emptyWords)
}

@Test func notifyDispatcherRejectsModifiedFutureAndNestedOwnership() throws {
    let config = try NotifyDispatchConfiguration(restoresMissing: false, originalArguments: ["foreign"])
    let command = try config.command(bridgePath: "/stable/tide-island-bridge")
    var variants = [command + ["extra"]]
    var future = command; future[2] = "--tide-island-notify-v2"; variants.append(future)
    var count = command; count[5] = "01"; variants.append(count)
    var flag = command; flag[flag.count - 1] = "--other"; variants.append(flag)
    for variant in variants {
        #expect(throws: NotifyConfigurationError.modifiedOwnedCommand) { try NotifyDispatchConfiguration.managedCommand(variant) }
    }
    #expect(throws: NotifyConfigurationError.modifiedOwnedCommand) { try NotifyDispatchConfiguration(restoresMissing: false, originalArguments: command) }
    let foreign = try NotifyDispatchConfiguration.managedCommand(["/tool", "--arg", "plain"])
    #expect(foreign == nil)
}

private func notifyPlan(_ data: Data?, bridge: BundledBridge) throws -> NotifyConfigurationPlan {
    try CodexNotifyConfiguration.plan(action: .install, existing: data, configurationPath: bridge.applicationURL.deletingLastPathComponent().appendingPathComponent("config.toml").path, bundledBridge: bridge)
}

private func notifyFixture() throws -> (root: URL, config: String, bridge: BundledBridge) {
    let base = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    let root = base.appendingPathComponent("tide-island-notify-" + UUID().uuidString), app = root.appendingPathComponent("TideIsland.app")
    let helpers = app.appendingPathComponent("Contents/Helpers")
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": "dev.kevinljb.tide-island", "CFBundlePackageType": "APPL", "CFBundleExecutable": "TideIsland", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let bytes = Data("#!/bin/sh\nexit 0\n".utf8), helper = helpers.appendingPathComponent(BundledBridge.executableName)
    try bytes.write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let manifest: [String: Any] = ["version": 1, "kind": "tide-island-embedded-bridge", "executable": BundledBridge.executableName, "sha256": CodexHookConfiguration.digest(bytes)]
    try JSONSerialization.data(withJSONObject: manifest).write(to: helpers.appendingPathComponent(BundledBridge.manifestName))
    return (root, root.appendingPathComponent("config.toml").path, try BundledBridge.inspect(applicationURL: app))
}
