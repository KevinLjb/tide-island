import ActivityKit
import Foundation
import TideIslandCore

@MainActor
final class NativeActivityController {
    private var activity: Activity<TideIslandAttributes>?

    func update(sessions: [AgentSession]) async throws {
        try Task.checkCancellation()
        guard let highlighted = sessions.first else {
            await activity?.end(nil, dismissalPolicy: .immediate)
            activity = nil
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ActivityError.disabled
        }
        let state = TideIslandAttributes.ContentState(
            sessionID: highlighted.id,
            projectName: highlighted.projectName,
            phase: highlighted.phase,
            workingCount: sessions.filter { $0.phase == .working }.count,
            waitingCount: sessions.filter { $0.phase == .needsInput }.count,
            updatedAt: highlighted.updatedAt
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(5 * 60))
        if let activity {
            await activity.update(content)
        } else {
            activity = try Activity.request(attributes: TideIslandAttributes(), content: content, pushType: nil)
        }
        if state.workingCount == 0, state.waitingCount == 0 {
            await activity?.end(content, dismissalPolicy: .after(Date().addingTimeInterval(30)))
            activity = nil
        }
    }

    private enum ActivityError: Error { case disabled }
}
