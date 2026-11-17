import Foundation
import Testing
@testable import TideIslandCore

@Test func bundledBridgeInspectionUsesFixedHelperAndDoesNotRunItOrWriteConfig() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try deliveryTestApp(in: root, name: "潮汐岛 '$(literal).app")
    let bridge = try BundledBridge.inspect(applicationURL: app)
    #expect(bridge.executableURL == app.appendingPathComponent("Contents/Helpers/tide-island-bridge"))
    #expect(bridge.version == "0.1.0" && bridge.build == "1" && bridge.sha256.count == 64)
    let file = try HookConfigurationFile(url: root.appendingPathComponent("missing/hooks.json"))
    let plan = try file.previewBundledInstall(applicationURL: app)
    #expect(plan.bundledBridge == bridge && plan.managedHooksAfter == 6)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("helper-was-run").path))
}

@Test func bundledBridgeRejectsForeignApplicationAndInvalidVersions() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try deliveryTestApp(in: root)
    for (key, value) in [("CFBundleIdentifier", "foreign.application"), ("CFBundleShortVersionString", "unknown"), ("CFBundleVersion", "1\n2"), ("CFBundleVersion", "1\n")] {
        try deliveryInfo(app, replacing: [key: value])
        #expect(throws: BundledBridgeError.invalidApplication) { try BundledBridge.inspect(applicationURL: app) }
        try deliveryInfo(app)
    }
}

@Test func bundledBridgeRejectsDuplicateFutureOversizedAndUnexpectedManifestFields() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try deliveryTestApp(in: root), manifest = app.appendingPathComponent("Contents/Resources/bridge-manifest.json")
    let original = try Data(contentsOf: manifest)
    for text in ["[]", "{\"version\":1,\"version\":1}", "{\"version\":2}", String(repeating: " ", count: 16385)] {
        try Data(text.utf8).write(to: manifest)
        #expect(throws: BundledBridgeError.self) { try BundledBridge.inspect(applicationURL: app) }
    }
    let rawFields = try JSONSerialization.jsonObject(with: original)
    var fields = try #require(rawFields as? [String: Any])
    fields["path"] = "/unrelated/helper"
    try JSONSerialization.data(withJSONObject: fields).write(to: manifest)
    #expect(throws: BundledBridgeError.invalidManifest) { try BundledBridge.inspect(applicationURL: app) }
}

@Test func bundledBridgeRejectsMismatchedEmptyAndNonExecutableHelper() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try deliveryTestApp(in: root), helper = app.appendingPathComponent("Contents/Helpers/tide-island-bridge")
    try Data("changed".utf8).write(to: helper)
    #expect(throws: BundledBridgeError.integrityMismatch) { try BundledBridge.inspect(applicationURL: app) }
    try Data().write(to: helper); try deliveryManifest(app)
    #expect(throws: BundledBridgeError.integrityMismatch) { try BundledBridge.inspect(applicationURL: app) }
    try Data("regular".utf8).write(to: helper); try deliveryManifest(app)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helper.path)
    #expect(throws: BundledBridgeError.unsafeFile) { try BundledBridge.inspect(applicationURL: app) }
}

@Test func bundledBridgeRejectsOversizedHelperBeforeReadingItsContents() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try deliveryTestApp(in: root), helper = app.appendingPathComponent("Contents/Helpers/tide-island-bridge")
    let handle = try FileHandle(forWritingTo: helper)
    try handle.truncate(atOffset: UInt64(BundledBridge.maximumExecutableBytes + 1)); try handle.close()
    #expect(throws: BundledBridgeError.invalidManifest) { try BundledBridge.inspect(applicationURL: app) }
}

@Test func bundledBridgeRejectsLinkedHelperAndLinkedHelpersDirectory() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try deliveryTestApp(in: root), helpers = app.appendingPathComponent("Contents/Helpers")
    let helper = helpers.appendingPathComponent("tide-island-bridge"), outside = root.appendingPathComponent("outside")
    try FileManager.default.copyItem(at: helper, to: outside)
    try FileManager.default.removeItem(at: helper)
    try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: outside)
    #expect(throws: BundledBridgeError.unsafeFile) { try BundledBridge.inspect(applicationURL: app) }
    let moved = root.appendingPathComponent("moved-helpers")
    try FileManager.default.moveItem(at: helpers, to: moved)
    try FileManager.default.createSymbolicLink(at: helpers, withDestinationURL: moved)
    #expect(throws: BundledBridgeError.unsafeFile) { try BundledBridge.inspect(applicationURL: app) }
}

@Test func bundledBridgeRejectsBuildProductsEvenThroughApplicationAliases() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let build = root.appendingPathComponent(".build")
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    let app = try deliveryTestApp(in: build), alias = root.appendingPathComponent("Stable.app")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
    #expect(throws: BundledBridgeError.unstablePath) { try BundledBridge.inspect(applicationURL: alias) }
}

@Test func bundledBridgeRejectsLinkedResourceManifestAndDirectory() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try deliveryTestApp(in: root), resources = app.appendingPathComponent("Contents/Resources")
    let manifest = resources.appendingPathComponent(BundledBridge.manifestName), outside = root.appendingPathComponent("manifest.json")
    try FileManager.default.moveItem(at: manifest, to: outside)
    try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
    #expect(throws: BundledBridgeError.unsafeFile) { try BundledBridge.inspect(applicationURL: app) }
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.moveItem(at: outside, to: manifest)
    let moved = root.appendingPathComponent("moved-resources")
    try FileManager.default.moveItem(at: resources, to: moved)
    try FileManager.default.createSymbolicLink(at: resources, withDestinationURL: moved)
    #expect(throws: BundledBridgeError.unsafeFile) { try BundledBridge.inspect(applicationURL: app) }
}

@Test func bundledBridgePreviewBindsHelperBytesAndBundleVersionEvenWhenHookCommandIsUnchanged() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try deliveryTestApp(in: root), config = try HookConfigurationFile(url: root.appendingPathComponent("hooks.json"))
    let first = try config.previewBundledInstall(applicationURL: app)
    _ = try config.apply(first, expectedFingerprint: first.fingerprint, backupDirectory: root.appendingPathComponent("backups"))
    let unchanged = try config.previewBundledInstall(applicationURL: app)
    #expect(!unchanged.changesFile)
    try deliveryInfo(app, replacing: ["CFBundleVersion": "2"])
    let upgraded = try config.previewBundledInstall(applicationURL: app)
    #expect(!upgraded.changesFile && upgraded.fingerprint != unchanged.fingerprint)
    #expect(throws: BundledBridgeError.bundleChanged) {
        try config.apply(unchanged, expectedFingerprint: unchanged.fingerprint, backupDirectory: root.appendingPathComponent("unexpected-backups"))
    }
    let helper = app.appendingPathComponent("Contents/Helpers/tide-island-bridge")
    try Data("new helper bytes".utf8).write(to: helper); try deliveryManifest(app)
    let replacement = try config.previewBundledInstall(applicationURL: app)
    #expect(!replacement.changesFile && replacement.fingerprint != upgraded.fingerprint)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-backups").path))
}

@Test func bundledBridgeMovedApplicationRepairsOnlyManagedHookPaths() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try deliveryTestApp(in: root), configURL = root.appendingPathComponent("hooks.json")
    let original = Data(#"{"future":42,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep-other-tool"}]}]}}"#.utf8)
    try original.write(to: configURL)
    let file = try HookConfigurationFile(url: configURL)
    let old = try file.previewBundledInstall(applicationURL: app)
    _ = try file.apply(old, expectedFingerprint: old.fingerprint, backupDirectory: root.appendingPathComponent("backups"))
    let moved = root.appendingPathComponent("Moved TideIsland.app")
    try FileManager.default.moveItem(at: app, to: moved)
    let repair = try file.previewBundledInstall(applicationURL: moved)
    #expect(repair.changesFile && repair.managedHooksBefore == 6 && repair.managedHooksAfter == 6)
    #expect(repair.fingerprint != old.fingerprint && repair.command?.contains(moved.path) == true)
    _ = try file.apply(repair, expectedFingerprint: repair.fingerprint, backupDirectory: root.appendingPathComponent("backups"))
    let data = try Data(contentsOf: configURL), parsed = try ConfigurationJSON.decode(data)
    let before = try ConfigurationJSON.decode(original)
    #expect(parsed.object?["future"] == .number("42"))
    #expect(parsed.object?["hooks"]?.object?["Stop"] == before.object?["hooks"]?.object?["Stop"])
    let repeated = try file.previewBundledInstall(applicationURL: moved)
    #expect(!repeated.changesFile)
}

@Test func bundledBridgeChangedAfterPreviewCannotCreateConfigurationOrBackups() throws {
    let root = try deliveryTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try deliveryTestApp(in: root), file = try HookConfigurationFile(url: root.appendingPathComponent("missing/hooks.json"))
    let plan = try file.previewBundledInstall(applicationURL: app)
    try Data("broken".utf8).write(to: app.appendingPathComponent("Contents/Helpers/tide-island-bridge"))
    #expect(throws: BundledBridgeError.integrityMismatch) {
        try file.apply(plan, expectedFingerprint: plan.fingerprint, backupDirectory: root.appendingPathComponent("backups"))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
}

private func deliveryTestRoot() throws -> URL {
    let base = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    let root = base.appendingPathComponent("tide-island-delivery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func deliveryTestApp(in root: URL, name: String = "TideIsland.app") throws -> URL {
    let app = root.appendingPathComponent(name), helper = app.appendingPathComponent("Contents/Helpers/tide-island-bridge")
    try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try deliveryInfo(app)
    let sentinel = root.appendingPathComponent("helper-was-run").path.replacingOccurrences(of: "'", with: "'\\''")
    try Data("#!/bin/sh\n/usr/bin/touch '\(sentinel)'\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    try deliveryManifest(app)
    return app
}

private func deliveryInfo(_ app: URL, replacing overrides: [String: String] = [:]) throws {
    var info = ["CFBundleIdentifier": "dev.kevinljb.tide-island", "CFBundlePackageType": "APPL", "CFBundleExecutable": "TideIsland",
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]
    info.merge(overrides) { _, new in new }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
}

private func deliveryManifest(_ app: URL) throws {
    let helpers = app.appendingPathComponent("Contents/Helpers"), bytes = try Data(contentsOf: helpers.appendingPathComponent("tide-island-bridge"))
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let record: [String: Any] = ["version": 1, "kind": "tide-island-embedded-bridge", "executable": "tide-island-bridge", "sha256": CodexHookConfiguration.digest(bytes)]
    try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: resources.appendingPathComponent(BundledBridge.manifestName))
}
