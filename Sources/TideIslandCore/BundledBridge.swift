import Darwin
import Foundation

public enum BundledBridgeError: String, Error, LocalizedError, Sendable {
    case invalidApplication, unstablePath, missingComponent, unsafeFile, invalidManifest, unsupportedManifest, integrityMismatch, bundleChanged, fileOperation

    public var errorDescription: String? {
        switch self {
        case .invalidApplication: "Choose an installed TideIsland.app with valid bundle metadata."
        case .unstablePath: "Move TideIsland.app outside .build and DerivedData before installing hooks."
        case .missingComponent: "The application is missing its embedded bridge or delivery metadata; rebuild or reinstall it."
        case .unsafeFile: "The embedded bridge delivery must contain regular files and real directories."
        case .invalidManifest: "The embedded bridge delivery metadata is invalid or exceeds its limits."
        case .unsupportedManifest: "The embedded bridge delivery format is not supported by this version."
        case .integrityMismatch: "The embedded bridge differs from its delivery metadata; rebuild or reinstall the application."
        case .bundleChanged: "The application moved or changed after preview; generate a new preview."
        case .fileOperation: "The embedded bridge could not be inspected."
        }
    }
}

/// Checks delivery integrity, not Apple signing / notarization or CLI behavior.
/// Inspection never runs the helper and never reads or modifies Codex config.
public struct BundledBridge: Equatable, Sendable {
    public static let executableName = "tide-island-bridge"
    public static let manifestName = "bridge-manifest.json"
    public static let maximumExecutableBytes = 64 * 1024 * 1024
    public let applicationURL: URL
    public let executableURL: URL
    public let sha256: String
    public let version: String
    public let build: String

    public static func inspect(applicationURL: URL) throws -> BundledBridge {
        guard applicationURL.isFileURL, applicationURL.query == nil, applicationURL.fragment == nil else {
            throw BundledBridgeError.invalidApplication
        }
        try CodexHookConfiguration.validatePath(applicationURL.path)
        let app = applicationURL.resolvingSymlinksInPath()
        guard app.pathExtension == "app" else { throw BundledBridgeError.invalidApplication }
        guard !app.pathComponents.contains(".build"), !app.pathComponents.contains("DerivedData") else {
            throw BundledBridgeError.unstablePath
        }
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        for directory in [app, contents, helpers] { try requireDirectory(directory) }
        let infoData = try read(contents.appendingPathComponent("Info.plist"), maximum: 64 * 1024)
        let rawInfo = try? PropertyListSerialization.propertyList(from: infoData, format: nil)
        guard let info = rawInfo as? [String: Any],
              info["CFBundleIdentifier"] as? String == "dev.kevinljb.tide-island",
              info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleExecutable"] as? String == "TideIsland",
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              validVersion(version), validVersion(build) else { throw BundledBridgeError.invalidApplication }
        let manifestData = try read(helpers.appendingPathComponent(manifestName), maximum: 16 * 1024)
        let manifest: [String: ConfigurationJSON]
        do {
            guard let fields = try ConfigurationJSON.decode(manifestData).object else { throw BundledBridgeError.invalidManifest }
            manifest = fields
        } catch { throw BundledBridgeError.invalidManifest }
        guard manifest["version"] == .number("1") else { throw BundledBridgeError.unsupportedManifest }
        guard Set(manifest.keys) == ["version", "kind", "executable", "sha256"],
              manifest["kind"] == .string("tide-island-embedded-bridge"),
              manifest["executable"] == .string(executableName),
              let digest = manifest["sha256"]?.string, digest.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw BundledBridgeError.invalidManifest
        }
        let executable = helpers.appendingPathComponent(executableName)
        let bytes = try read(executable, maximum: maximumExecutableBytes, executable: true)
        guard !bytes.isEmpty, CodexHookConfiguration.digest(bytes) == digest else { throw BundledBridgeError.integrityMismatch }
        return BundledBridge(applicationURL: app, executableURL: executable, sha256: digest, version: version, build: build)
    }

    public func verifyCurrent() throws {
        guard try Self.inspect(applicationURL: applicationURL) == self else { throw BundledBridgeError.bundleChanged }
    }

    private static func validVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count <= 3 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
    }

    private static func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw BundledBridgeError.missingComponent }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw BundledBridgeError.unsafeFile }
    }

    private static func read(_ url: URL, maximum: Int, executable: Bool = false) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw errno == ENOENT ? BundledBridgeError.missingComponent : .unsafeFile }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw BundledBridgeError.unsafeFile }
        guard before.st_size >= 0, before.st_size <= maximum else { throw BundledBridgeError.invalidManifest }
        if executable, !FileManager.default.isExecutableFile(atPath: url.path) { throw BundledBridgeError.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        do {
            while let part = try handle.read(upToCount: min(64 * 1024, maximum + 1 - data.count)), !part.isEmpty {
                data.append(part)
                guard data.count <= maximum else { throw BundledBridgeError.invalidManifest }
            }
        } catch let error as BundledBridgeError { throw error }
        catch { throw BundledBridgeError.fileOperation }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw BundledBridgeError.bundleChanged }
        return data
    }
}
