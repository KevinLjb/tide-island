import Darwin
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

@Test func notifyFilePreviewAndUnmanagedUninstallCreateNoConfigurationDirectories() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let parent = fixture.root.appendingPathComponent("missing"), file = try NotifyConfigurationFile(url: parent.appendingPathComponent("config.toml"))
    let install = try file.preview(action: .install, applicationURL: fixture.bridge.applicationURL)
    #expect(install.changesFile && !FileManager.default.fileExists(atPath: parent.path))
    let uninstall = try file.preview(action: .uninstall), backup = fixture.root.appendingPathComponent("backups")
    let result = try file.apply(uninstall, expectedFingerprint: uninstall.fingerprint, backupDirectory: backup)
    #expect(result == nil && !FileManager.default.fileExists(atPath: parent.path) && !FileManager.default.fileExists(atPath: backup.path))
}

@Test func notifyFileBacksUpExactSourceAndPermissionsAndNoOpDoesNotRewrite() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let url = URL(fileURLWithPath: fixture.config), original = Data("# private config\nnotify = [ 'foreign' ]\nmodel='fixture'\n".utf8)
    try original.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
    let file = try NotifyConfigurationFile(url: url), plan = try file.preview(action: .install, applicationURL: fixture.bridge.applicationURL)
    let applied = try file.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: fixture.root.appendingPathComponent("backups"))
    let backup = try #require(applied), bytes = try Data(contentsOf: backup.appendingPathComponent("config.toml.before"))
    let backupMode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
    let configMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(bytes == original && backupMode?.intValue == 0o700 && configMode?.intValue == 0o640)
    let unchanged = try file.preview(action: .install, applicationURL: fixture.bridge.applicationURL)
    let result = try file.apply(unchanged, expectedFingerprint: unchanged.fingerprint, backupDirectory: fixture.root.appendingPathComponent("unexpected"))
    #expect(result == nil && !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("unexpected").path))
}

@Test func notifyFileRejectsEditedSourceAndAnotherTargetBeforeCreatingBackups() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let file = try NotifyConfigurationFile(url: URL(fileURLWithPath: fixture.config))
    let plan = try file.preview(action: .install, applicationURL: fixture.bridge.applicationURL)
    let other = try NotifyConfigurationFile(url: fixture.root.appendingPathComponent("other/config.toml"))
    let backup = fixture.root.appendingPathComponent("backups")
    #expect(throws: NotifyConfigurationError.stalePlan) { try other.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: backup) }
    let edited = Data("notify=['later-tool']\n".utf8)
    try edited.write(to: file.url)
    #expect(throws: NotifyConfigurationError.stalePlan) { try file.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: backup) }
    let current = try Data(contentsOf: file.url)
    #expect(current == edited && !FileManager.default.fileExists(atPath: backup.path))
}

@Test func notifyFileRejectsBusyLockAndFailedBackupWithoutWritingSource() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let file = try NotifyConfigurationFile(url: URL(fileURLWithPath: fixture.config)), original = Data("notify=['foreign']\n".utf8)
    try original.write(to: file.url)
    let plan = try file.preview(action: .install, applicationURL: fixture.bridge.applicationURL)
    let descriptor = open(fixture.root.appendingPathComponent(".tide-island-notify.lock").path, O_RDWR | O_CREAT, 0o600)
    #expect(descriptor >= 0); defer { close(descriptor) }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: NotifyConfigurationError.busy) { try file.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: fixture.root.appendingPathComponent("backups")) }
    _ = flock(descriptor, LOCK_UN)
    let blocked = fixture.root.appendingPathComponent("blocked"); try Data("keep".utf8).write(to: blocked)
    #expect(throws: (any Error).self) { try file.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: blocked) }
    let current = try Data(contentsOf: file.url)
    #expect(current == original)
}

@Test func notifyFileRejectsLinkedAndSpecialTargetsWithoutBlocking() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = fixture.root.appendingPathComponent("original.toml"); try Data("notify=[]\n".utf8).write(to: original)
    let url = URL(fileURLWithPath: fixture.config)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
    let file = try NotifyConfigurationFile(url: url)
    #expect(throws: NotifyConfigurationError.unsafeFile) { try file.preview(action: .uninstall) }
    try FileManager.default.removeItem(at: url)
    #expect(mkfifo(url.path, 0o600) == 0)
    #expect(throws: NotifyConfigurationError.unsafeFile) { try file.preview(action: .uninstall) }
}

@Test func notifyFileRevalidatesBundleEvenWhenNotifyCommandIsUnchanged() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let file = try NotifyConfigurationFile(url: URL(fileURLWithPath: fixture.config))
    let first = try file.preview(action: .install, applicationURL: fixture.bridge.applicationURL)
    _ = try file.apply(first, expectedFingerprint: first.fingerprint, backupDirectory: fixture.root.appendingPathComponent("backups"))
    let unchanged = try file.preview(action: .install, applicationURL: fixture.bridge.applicationURL)
    #expect(!unchanged.changesFile)
    try Data("changed helper".utf8).write(to: fixture.bridge.executableURL)
    #expect(throws: BundledBridgeError.integrityMismatch) {
        try file.apply(unchanged, expectedFingerprint: unchanged.fingerprint, backupDirectory: fixture.root.appendingPathComponent("unexpected"))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("unexpected").path))
}

@Test func integrationFingerprintBindsBothConfigurationDocuments() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try integrationPlans(fixture.root, bridge: fixture.bridge)
    let hookEdit = try integrationPlans(fixture.root, bridge: fixture.bridge, hooks: Data("{\"future\":7}".utf8))
    let notifyEdit = try integrationPlans(fixture.root, bridge: fixture.bridge, notify: Data("notify=['foreign']\n".utf8))
    let plan = try CodexIntegrationPlan(hooks: first.hooks, notify: first.notify)
    let changedHook = try CodexIntegrationPlan(hooks: hookEdit.hooks, notify: first.notify)
    let changedNotify = try CodexIntegrationPlan(hooks: first.hooks, notify: notifyEdit.notify)
    #expect(plan.fingerprint != changedHook.fingerprint && plan.fingerprint != changedNotify.fingerprint)
    #expect(plan.dataAction == .keep && plan.stateFile == nil && plan.resetPreview == nil)
}

@Test func integrationRejectsDifferentDirectoriesAndMismatchedActions() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let current = try integrationPlans(fixture.root, bridge: fixture.bridge)
    let other = try integrationPlans(fixture.root.appendingPathComponent("other"), bridge: fixture.bridge)
    let uninstall = try integrationPlans(fixture.root, bridge: nil, action: .uninstall)
    #expect(throws: IntegrationConfigurationError.inconsistentPlans) { try CodexIntegrationPlan(hooks: current.hooks, notify: other.notify) }
    #expect(throws: IntegrationConfigurationError.inconsistentPlans) { try CodexIntegrationPlan(hooks: current.hooks, notify: uninstall.notify) }
}

@Test func integrationRejectsMixedBundleEvidenceAndDifferentInboxOptions() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try integrationPlans(fixture.root, bridge: fixture.bridge)
    let option = try integrationPlans(fixture.root, bridge: fixture.bridge, inbox: "/different/Events")
    #expect(throws: IntegrationConfigurationError.inconsistentPlans) { try CodexIntegrationPlan(hooks: original.hooks, notify: option.notify) }
    let infoURL = fixture.bridge.applicationURL.appendingPathComponent("Contents/Info.plist")
    let raw = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
    var info = try #require(raw as? [String: Any]); info["CFBundleVersion"] = "2"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    let bridge = try BundledBridge.inspect(applicationURL: fixture.bridge.applicationURL)
    let updated = try integrationPlans(fixture.root, bridge: bridge)
    #expect(throws: IntegrationConfigurationError.inconsistentPlans) { try CodexIntegrationPlan(hooks: original.hooks, notify: updated.notify) }
}

@Test func integrationClearStateRequiresUninstallAndAConsistentExplicitPreview() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let install = try integrationPlans(fixture.root, bridge: fixture.bridge)
    let uninstall = try integrationPlans(fixture.root, bridge: nil, action: .uninstall)
    #expect(throws: IntegrationConfigurationError.inconsistentPlans) {
        try CodexIntegrationPlan(hooks: uninstall.hooks, notify: uninstall.notify, dataAction: .clearSessionState)
    }
    let inbox = EventInbox(directory: fixture.root.appendingPathComponent("Events"))
    try inbox.write(AgentEvent(sessionID: "integration", projectName: "fixture", phase: .working))
    let state = SessionStateFile(inbox: inbox), reset = try state.previewReset()
    #expect(throws: IntegrationConfigurationError.inconsistentPlans) {
        try CodexIntegrationPlan(hooks: install.hooks, notify: install.notify, dataAction: .clearSessionState, stateFile: state, resetPreview: reset)
    }
    #expect(throws: IntegrationConfigurationError.inconsistentPlans) {
        try CodexIntegrationPlan(hooks: uninstall.hooks, notify: uninstall.notify, stateFile: state, resetPreview: reset)
    }
    let otherState = SessionStateFile(inbox: EventInbox(directory: fixture.root.appendingPathComponent("OtherEvents")))
    #expect(throws: IntegrationConfigurationError.inconsistentPlans) {
        try CodexIntegrationPlan(hooks: uninstall.hooks, notify: uninstall.notify, dataAction: .clearSessionState, stateFile: otherState, resetPreview: reset)
    }
}

@Test func integrationStateChoiceAndChangedEventsInvalidateTheCombinedPreview() throws {
    let fixture = try notifyFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let uninstall = try integrationPlans(fixture.root, bridge: nil, action: .uninstall)
    let keep = try CodexIntegrationPlan(hooks: uninstall.hooks, notify: uninstall.notify)
    let inbox = EventInbox(directory: fixture.root.appendingPathComponent("Events")), state = SessionStateFile(inbox: inbox)
    try inbox.write(AgentEvent(sessionID: "integration-a", projectName: "fixture", phase: .working))
    let firstReset = try state.previewReset()
    let clear = try CodexIntegrationPlan(hooks: uninstall.hooks, notify: uninstall.notify, dataAction: .clearSessionState, stateFile: state, resetPreview: firstReset)
    try inbox.write(AgentEvent(sessionID: "integration-b", projectName: "fixture", phase: .working))
    let nextReset = try state.previewReset()
    let changed = try CodexIntegrationPlan(hooks: uninstall.hooks, notify: uninstall.notify, dataAction: .clearSessionState, stateFile: state, resetPreview: nextReset)
    #expect(keep.fingerprint != clear.fingerprint && clear.fingerprint != changed.fingerprint)
    #expect(firstReset.eventFiles == 1 && nextReset.eventFiles == 2)
}

private func integrationPlans(_ directory: URL, bridge: BundledBridge?, action: HookConfigurationAction = .install,
                              hooks: Data? = nil, notify: Data? = nil, inbox: String? = nil) throws -> (hooks: HookConfigurationPlan, notify: NotifyConfigurationPlan) {
    let hookPlan = try CodexHookConfiguration.plan(action: action, existing: hooks, bridgePath: bridge?.executableURL.path, inboxPath: inbox,
                                                  configurationPath: directory.appendingPathComponent("hooks.json").path, bundledBridge: bridge)
    let notifyPlan = try CodexNotifyConfiguration.plan(action: action, existing: notify, configurationPath: directory.appendingPathComponent("config.toml").path,
                                                      bundledBridge: bridge, inboxPath: inbox)
    return (hookPlan, notifyPlan)
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
