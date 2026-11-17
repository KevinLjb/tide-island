import ActivityKit
import AppKit
import Foundation
import TideIslandCore

#if DEBUG
struct NativeSDKRequestFailure: Sendable {
    let kind: String
    let code: Int?
}
#endif

@MainActor
final class NativeActivityController {
    private let client: NativeActivityKitClient
    private let scheduler: IslandActivityScheduler
    var frames: AsyncStream<IslandActivityDelivery> { scheduler.frames }
    var changes: AsyncStream<Void> { client.changes }

    init() {
        let client = NativeActivityKitClient()
        self.client = client
        scheduler = IslandActivityScheduler(client: client)
        client.startMonitoring()
    }

    func submit(snapshot: SessionSnapshot, sequence: UInt64, scope: IslandActivityScope, force: Bool = false,
                showsProjectName: Bool = true) async {
        await scheduler.submit(snapshot: snapshot, sequence: sequence, scope: scope,
                               forceReconciliation: force, showsProjectName: showsProjectName)
    }

    func shutdown() async -> Bool {
        client.stopMonitoring()
        return await scheduler.shutdown()
    }

    #if DEBUG
    var validationRequestFailure: NativeSDKRequestFailure? { client.validationRequestFailure }

    /// Settle queued work for the explicit SDK smoke mode. This never submits
    /// another snapshot or creates an acknowledgement on its own.
    func validationDelivery() async -> IslandActivityDelivery {
        await scheduler.flush()
        return await scheduler.current()
    }
    #endif

    /// Authorization is not hardware discovery or evidence of visible UI.
    func availability() -> NativeActivityAvailability {
        if #available(macOS 27.3, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled ? .allowed : .disabled
        }
        return .unavailable
    }
}

@MainActor
private final class NativeActivityKitClient: IslandActivityClient {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var owned: [String: Activity<TideIslandAttributes>] = [:]
    private var watchers: [String: Task<Void, Never>] = [:]
    private var authorizationTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var monitoring = false
    #if DEBUG
    private(set) var validationRequestFailure: NativeSDKRequestFailure?
    #endif

    init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = stream.stream; continuation = stream.continuation
    }

    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        authorizationTask = Task { [weak self] in
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard !Task.isCancelled else { break }
                self?.continuation.yield(())
            }
        }
        discoveryTask = Task { [weak self] in
            for await _ in Activity<TideIslandAttributes>.activityUpdates {
                guard !Task.isCancelled else { break }
                // Discovery is a signal only; adoption requires ordered source
                // authority plus a fresh running-instance check in activities.
                self?.continuation.yield(())
            }
        }
    }

    func stopMonitoring() {
        monitoring = false
        authorizationTask?.cancel(); authorizationTask = nil
        discoveryTask?.cancel(); discoveryTask = nil
        watchers.values.forEach { $0.cancel() }; watchers.removeAll()
        continuation.finish()
    }

    func activities(scope: IslandActivityScope) async throws -> [IslandActivityRecord]? {
        try Task.checkCancellation()
        var available = owned
        let bundleID = Bundle.main.bundleIdentifier
        let anotherInstance = bundleID == nil || NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }
        if scope == .application, !anotherInstance {
            for activity in Activity<TideIslandAttributes>.activities where activity.attributes.name == "TideIsland" {
                available[activity.id] = activity
            }
        }
        let records = available.values.map { activity in
            IslandActivityRecord(identifier: activity.id, state: sharedState(activity.activityState),
                                 content: activity.content.state, staleAt: activity.content.staleDate)
        }
        // Keep terminal records in this response, then release their handles.
        // The shared controller remembers dismissal; SDK state is not a new
        // observation and never refreshes session timestamps.
        owned = available.filter { _, activity in
            switch activity.activityState {
            case .ended, .dismissed: return false
            default: return true
            }
        }
        for id in watchers.keys.filter({ owned[$0] == nil }) { watchers.removeValue(forKey: id)?.cancel() }
        if monitoring { for activity in owned.values { watch(activity) } }
        return records
    }

    func isEnabled() async -> Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func request(_ presentation: IslandActivityPresentation) async throws -> String {
        try Task.checkCancellation()
        let content = ActivityContent(state: presentation.state, staleDate: presentation.staleAt)
        let activity: Activity<TideIslandAttributes>
        do {
            activity = try Activity.request(attributes: TideIslandAttributes(), content: content, pushType: nil)
        } catch {
            #if DEBUG
            validationRequestFailure = requestFailure(error)
            #endif
            if let authorization = error as? ActivityAuthorizationError, authorization == .visibility {
                throw IslandActivityError.foregroundRequired
            }
            throw error
        }
        owned[activity.id] = activity
        if monitoring { watch(activity) }
        return activity.id
    }

    func update(_ identifier: String, presentation: IslandActivityPresentation) async throws {
        try Task.checkCancellation()
        guard let activity = owned[identifier], sharedState(activity.activityState) == .active || sharedState(activity.activityState) == .stale else {
            throw ClientError.activityMissing
        }
        try await Self.updateActivity(identifier, presentation: presentation)
    }

    func end(_ identifier: String) async throws {
        try Task.checkCancellation()
        guard let activity = owned[identifier] else { throw ClientError.activityMissing }
        guard sharedState(activity.activityState) != .unknown else { throw ClientError.activityMissing }
        try await Self.endActivity(identifier)
        owned.removeValue(forKey: identifier)
        watchers.removeValue(forKey: identifier)?.cancel()
    }

    // Activity is not Sendable in the 27.3 SDK. Pass only the Sendable ID and
    // presentation across this boundary, then obtain an operation-local SDK
    // handle. Actor-owned inventory / watcher handles are never sent to the
    // SDK's concurrent update and end methods. The shared scheduler continues
    // to serialize these operations and own cancellation / reconciliation.
    nonisolated private static func updateActivity(_ identifier: String, presentation: IslandActivityPresentation) async throws {
        try Task.checkCancellation()
        guard let activity = Activity<TideIslandAttributes>.activities.first(where: { $0.id == identifier }),
              activity.activityState == .active || activity.activityState == .stale else { throw ClientError.activityMissing }
        await activity.update(ActivityContent(state: presentation.state, staleDate: presentation.staleAt))
    }

    nonisolated private static func endActivity(_ identifier: String) async throws {
        try Task.checkCancellation()
        guard let activity = Activity<TideIslandAttributes>.activities.first(where: { $0.id == identifier }) else { throw ClientError.activityMissing }
        switch activity.activityState {
        case .active, .stale, .ended, .dismissed: break
        case .pending: throw ClientError.activityMissing
        @unknown default: throw ClientError.activityMissing
        }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private func watch(_ activity: Activity<TideIslandAttributes>) {
        guard watchers[activity.id] == nil,
              activity.activityState == .pending || activity.activityState == .active || activity.activityState == .stale else { return }
        watchers[activity.id] = Task { [weak self] in
            for await _ in activity.activityStateUpdates {
                guard !Task.isCancelled else { break }
                self?.continuation.yield(())
            }
        }
    }

    private func sharedState(_ state: ActivityState) -> IslandActivityState {
        switch state {
        case .active: .active
        case .stale: .stale
        case .ended: .ended
        case .dismissed: .dismissed
        case .pending: .unknown
        @unknown default: .unknown
        }
    }

    #if DEBUG
    /// SDK enum cases and its numeric code only; never localized error text,
    /// userInfo, activity identifiers, or arbitrary error domains.
    private func requestFailure(_ error: any Error) -> NativeSDKRequestFailure {
        guard let error = error as? ActivityAuthorizationError else { return .init(kind: "other", code: nil) }
        let kind: String
        switch error {
        case .attributesTooLarge: kind = "attributes-too-large"
        case .unsupported: kind = "unsupported"
        case .denied: kind = "denied"
        case .globalMaximumExceeded: kind = "global-maximum-exceeded"
        case .targetMaximumExceeded: kind = "target-maximum-exceeded"
        case .unsupportedTarget: kind = "unsupported-target"
        case .visibility: kind = "visibility"
        case .persistenceFailure: kind = "persistence-failure"
        case .missingProcessIdentifier: kind = "missing-process-identifier"
        case .unentitled: kind = "unentitled"
        case .malformedActivityIdentifier: kind = "malformed-activity-identifier"
        case .reconnectNotPermitted: kind = "reconnect-not-permitted"
        @unknown default: kind = "unknown-authorization-error"
        }
        return .init(kind: kind, code: error.errorCode)
    }
    #endif

    deinit {
        authorizationTask?.cancel(); discoveryTask?.cancel()
        watchers.values.forEach { $0.cancel() }
        continuation.finish()
    }

    private enum ClientError: Error { case activityMissing }
}
