import ActivityKit
import Foundation
import TideIslandCore

@MainActor
final class NativeActivityController {
    private let scheduler: IslandActivityScheduler
    var frames: AsyncStream<IslandActivityDelivery> { scheduler.frames }

    init() {
        scheduler = IslandActivityScheduler(client: NativeActivityKitClient())
    }

    func submit(snapshot: SessionSnapshot, sequence: UInt64) async {
        await scheduler.submit(snapshot: snapshot, sequence: sequence)
    }
}

@MainActor
private final class NativeActivityKitClient: IslandActivityClient {
    private var owned: [String: Activity<TideIslandAttributes>] = [:]

    func isEnabled() async -> Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func request(_ presentation: IslandActivityPresentation) async throws -> String {
        try Task.checkCancellation()
        let content = ActivityContent(state: presentation.state, staleDate: presentation.staleAt)
        let activity = try Activity.request(attributes: TideIslandAttributes(), content: content, pushType: nil)
        owned[activity.id] = activity
        return activity.id
    }

    func update(_ identifier: String, presentation: IslandActivityPresentation) async throws {
        try Task.checkCancellation()
        guard let activity = owned[identifier] else { throw ClientError.activityMissing }
        await activity.update(ActivityContent(state: presentation.state, staleDate: presentation.staleAt))
    }

    func end(_ identifier: String) async throws {
        try Task.checkCancellation()
        guard let activity = owned[identifier] else { throw ClientError.activityMissing }
        await activity.end(nil, dismissalPolicy: .immediate)
        owned.removeValue(forKey: identifier)
    }

    private enum ClientError: Error { case activityMissing }
}
