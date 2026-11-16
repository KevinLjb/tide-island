import ActivityKit
import Foundation
import TideIslandCore

@MainActor
final class NativeActivityController {
    private var activity: Activity<TideIslandAttributes>?

    func update(snapshot: SessionSnapshot) async throws {
        try Task.checkCancellation()
        guard let highlighted = snapshot.activitySession,
              let staleAt = snapshot.activityStaleAt, staleAt > Date() else {
            await activity?.end(nil, dismissalPolicy: .immediate)
            activity = nil
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ActivityError.disabled
        }
        let state = TideIslandAttributes.ContentState(
            sessionID: highlighted.id,
            projectName: highlighted.session.projectName,
            phase: highlighted.session.phase,
            workingCount: snapshot.workingCount,
            waitingCount: snapshot.waitingCount,
            updatedAt: highlighted.session.updatedAt
        )
        let content = ActivityContent(state: state, staleDate: staleAt)
        if let activity {
            await activity.update(content)
        } else {
            activity = try Activity.request(attributes: TideIslandAttributes(), content: content, pushType: nil)
        }
    }

    private enum ActivityError: Error { case disabled }
}
