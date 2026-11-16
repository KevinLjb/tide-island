import Foundation

/// The SDK boundary. Implementations use public native APIs, return an opaque
/// owned identifier, honor cancellation and never persist provider content.
public protocol IslandActivityClient: Sendable {
    /// nil means inventory is unsupported, not an authoritative empty list.
    /// Every returned handle is safe for this instance to update/end. The list
    /// is complete for that scope; never silently truncate or omit unknowns.
    func activities(scope: IslandActivityScope) async throws -> [IslandActivityRecord]?
    func isEnabled() async -> Bool
    func request(_ presentation: IslandActivityPresentation) async throws -> String
    func update(_ identifier: String, presentation: IslandActivityPresentation) async throws
    func end(_ identifier: String) async throws
}

public extension IslandActivityClient {
    func activities(scope: IslandActivityScope) async throws -> [IslandActivityRecord]? { nil }
}

/// Owned lifecycle and reconciliation. The scheduler serializes delivery and
/// shutdown; direct concurrent calls are rejected before any SDK operation.
public actor IslandActivityController {
    private let client: any IslandActivityClient
    private let policy = IslandActivityPresentationPolicy.standard
    private let now: @Sendable () -> Date
    private var identifier: String?
    private var managed: Set<String> = []
    private var dismissedContent: IslandActivityContent?
    private var updating = false
    private var stopped = false

    public init(client: any IslandActivityClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    public func update(snapshot: SessionSnapshot, scope: IslandActivityScope = .ownedOnly) async throws {
        _ = try await deliver(snapshot: snapshot, scope: scope)
    }

    /// The scheduler uses the actual post-authorization projection, rather than
    /// caching a payload that may have expired while the client was awaited.
    func deliver(snapshot: SessionSnapshot, scope: IslandActivityScope = .ownedOnly) async throws -> IslandActivityPresentation? {
        try Task.checkCancellation()
        guard !stopped else { throw IslandActivityError.stopped }
        guard !updating else { throw IslandActivityError.busy }
        updating = true
        defer { updating = false }
        let candidate = try policy.presentation(for: snapshot, at: now())
        try await reconcile(scope: scope, candidate: candidate)
        guard candidate != nil else { try await endActivities(managed); return nil }
        let enabled = await client.isEnabled()
        try Task.checkCancellation()
        guard enabled else { try await endActivities(managed); throw IslandActivityError.disabled }
        // Authorization itself is asynchronous. Never renew an already expired
        // aggregate by sending a content payload computed before that await.
        guard let authorized = try policy.presentation(for: snapshot, at: now()) else { try await endActivities(managed); return nil }
        if dismissedContent == authorized.state { try await endActivities(managed); return nil }
        dismissedContent = nil
        // Finish duplicate cleanup before updating/creating. A failed end must
        // not be hidden by a successful new request.
        try await endActivities(managed.subtracting(identifier.map { [$0] } ?? []))
        guard let presentation = try policy.presentation(for: snapshot, at: now()) else { try await endActivities(managed); return nil }
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
            guard IslandActivityRecord.validIdentifier(created) else {
                throw IslandActivityError.invalidActivityID
            }
            // Remember a successful request before checking cancellation so a
            // subsequent empty snapshot can still end the activity we created.
            identifier = created
            managed.insert(created)
        }
        try Task.checkCancellation()
        return presentation
    }

    /// Retryable cleanup; once called, this controller never creates again.
    /// The scheduler invokes it in a fresh task after in-flight work settles.
    public func shutdown(scope: IslandActivityScope = .ownedOnly) async throws {
        guard !updating else { throw IslandActivityError.busy }
        stopped = true; updating = true
        defer { updating = false }
        try await reconcile(scope: scope, candidate: nil)
        try await endActivities(managed)
    }

    private func reconcile(scope: IslandActivityScope, candidate: IslandActivityPresentation?) async throws {
        let records: [IslandActivityRecord]?
        do { records = try await client.activities(scope: scope) }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); throw IslandActivityError.inventoryFailed }
        try Task.checkCancellation()
        guard let records else { return }
        try IslandActivityRecord.validate(records)
        // Validate the whole inventory before changing ownership or ending any
        // record. Unknown future SDK states are not permission to delete them.
        for record in records where record.state == .dismissed {
            if record.identifier == identifier || record.content == candidate?.state {
                dismissedContent = record.content
            }
        }
        managed = Set(records.filter(\.isLive).map(\.identifier))
        if let identifier, managed.contains(identifier) { return }
        identifier = records.filter(\.isLive).sorted {
            let left = $0.content.sessionID == candidate?.state.sessionID
            let right = $1.content.sessionID == candidate?.state.sessionID
            return left != right ? left : $0.identifier < $1.identifier
        }.first?.identifier
    }

    private func endActivities(_ identifiers: Set<String>) async throws {
        var failed = false
        for id in identifiers.sorted() {
            try Task.checkCancellation()
            do {
                try await client.end(id)
                managed.remove(id)
                if identifier == id { identifier = nil }
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); failed = true }
        }
        try Task.checkCancellation()
        if failed { throw IslandActivityError.endFailed }
    }
}
