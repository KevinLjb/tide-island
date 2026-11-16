import Foundation

/// The SDK boundary. Implementations use public native APIs, return an opaque
/// owned identifier, honor cancellation and never persist provider content.
public protocol IslandActivityClient: Sendable {
    func isEnabled() async -> Bool
    func request(_ presentation: IslandActivityPresentation) async throws -> String
    func update(_ identifier: String, presentation: IslandActivityPresentation) async throws
    func end(_ identifier: String) async throws
}

/// Basic owned-activity lifecycle shared by tests and the native adapter.
/// Burst coalescing/deduplication and system activity reconciliation are separate
/// follow-up work; callers currently serialize updates and concurrent calls fail.
public actor IslandActivityController {
    private let client: any IslandActivityClient
    private let policy = IslandActivityPresentationPolicy.standard
    private let now: @Sendable () -> Date
    private var identifier: String?
    private var updating = false

    public init(client: any IslandActivityClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    public func update(snapshot: SessionSnapshot) async throws {
        try Task.checkCancellation()
        guard !updating else { throw IslandActivityError.busy }
        updating = true
        defer { updating = false }
        guard try policy.presentation(for: snapshot, at: now()) != nil else { try await endOwnedActivity(); return }
        let enabled = await client.isEnabled()
        try Task.checkCancellation()
        guard enabled else { throw IslandActivityError.disabled }
        // Authorization itself is asynchronous. Never renew an already expired
        // aggregate by sending a content payload computed before that await.
        guard let presentation = try policy.presentation(for: snapshot, at: now()) else { try await endOwnedActivity(); return }
        if let identifier {
            do { try await client.update(identifier, presentation: presentation) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                throw IslandActivityError.updateFailed
            }
        } else {
            let created: String
            do { created = try await client.request(presentation) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                throw IslandActivityError.requestFailed
            }
            guard !created.isEmpty, created.utf8.count <= 1024,
                  !created.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw IslandActivityError.invalidActivityID
            }
            // Remember a successful request before checking cancellation so a
            // subsequent empty snapshot can still end the activity we created.
            identifier = created
        }
        try Task.checkCancellation()
    }

    private func endOwnedActivity() async throws {
        guard let identifier else { return }
        try Task.checkCancellation()
        do { try await client.end(identifier) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw IslandActivityError.endFailed
        }
        self.identifier = nil
        try Task.checkCancellation()
    }
}
