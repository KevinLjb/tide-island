import Darwin
import Foundation

public enum DiagnosticExport {
    /// Creates one private file in an existing user-selected directory. Never
    /// overwrites a destination or places diagnostics in the supplied data roots.
    /// Errors are fixed codes; no path or rejected bytes leave this boundary.
    public static func write(_ report: DiagnosticReport, to destination: URL, excluding protectedDirectories: [URL]) throws {
        let data = try report.encoded()
        guard destination.isFileURL, !destination.path.utf8.contains(0),
              !["", ".", ".."].contains(destination.lastPathComponent) else { throw DiagnosticError.invalidDestination }
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolved = parent.appendingPathComponent(destination.lastPathComponent).path
        for directory in protectedDirectories {
            let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved != path, !resolved.hasPrefix(path.hasSuffix("/") ? path : path + "/") else {
                throw DiagnosticError.invalidDestination
            }
        }
        let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DiagnosticError.invalidDestination }
        defer { close(descriptor) }
        let name = destination.lastPathComponent
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DiagnosticError.exportFailed }
        defer { close(fd) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            unlinkat(descriptor, name, 0)
            throw DiagnosticError.exportFailed
        }
    }
}
