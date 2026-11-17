import AppKit
import Foundation

@MainActor
enum NativeSDKValidation {
    #if DEBUG
    static let backgroundRequested = ProcessInfo.processInfo.arguments.contains("--native-sdk-smoke-background")
    static let foregroundRequested = ProcessInfo.processInfo.arguments.contains("--native-sdk-smoke")
    static let isRequested = foregroundRequested || backgroundRequested
    static let showsMenuItem = !isRequested || backgroundRequested
    #else
    static let isRequested = false
    static let showsMenuItem = true
    #endif
}

#if DEBUG
import ActivityKit
import TideIslandCore

/// An explicit, in-memory SDK exercise. The normal SessionModel is never
/// constructed in this mode, and reconciliation stays within owned handles.
@MainActor
final class NativeSDKSmoke {
    private let controller = NativeActivityController()
    private let sessionID = "sdk-smoke-" + UUID().uuidString
    private var store = SessionStore()
    private var sequence: UInt64 = 0
    private(set) var finished = false

    func run() async {
        var report = Report(sourceRevision: Bundle.main.object(forInfoDictionaryKey: "TideIslandSourceRevision") as? String ?? "development")
        report.validationMode = NativeSDKValidation.backgroundRequested ? "background" : "foreground"
        do {
            guard !(NativeSDKValidation.foregroundRequested && NativeSDKValidation.backgroundRequested) else {
                throw Failure(code: "conflicting-sdk-smoke-options")
            }
            guard !NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier &&
                    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
            }) else { throw Failure(code: "another-app-instance-running") }
            if NativeSDKValidation.backgroundRequested {
                report.foregroundObserved = NSApplication.shared.isActive
                guard !report.foregroundObserved else { throw Failure(code: "background-precondition-not-met") }
            } else {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await waitUntil("foreground-activation-timeout") { NSApplication.shared.isActive }
                report.foregroundObserved = true
            }
            guard controller.availability() == .allowed else { throw Failure(code: "activities-not-authorized") }

            try await submit(.working)
            try await waitUntil("request-observation-timeout") { self.observation(phase: .working) != nil }
            guard let identifier = observation(phase: .working)?.identifier else { throw Failure(code: "request-observation-missing") }
            report.requestVerified = true

            try await submit(.needsInput)
            try await waitUntil("update-observation-timeout") { self.observation(phase: .needsInput)?.identifier == identifier }
            report.updateVerified = true

            try await submit(.completed)
            try await waitUntil("end-observation-timeout") { !self.hasLiveActivity() }
            report.endVerified = true

            // A second owned request tests shutdown independently of the
            // empty-presentation end path above.
            try await submit(.working)
            try await waitUntil("shutdown-request-timeout") { self.observation(phase: .working) != nil }
            guard await shutdown() else { throw Failure(code: "shutdown-reported-failure") }
            try await waitUntil("shutdown-observation-timeout") { !self.hasLiveActivity() }
            report.shutdownVerified = true
        } catch let failure as Failure {
            report.problem = failure.code
        } catch is CancellationError {
            report.problem = "validation-cancelled"
        } catch {
            report.problem = "validation-input-failed"
        }
        let cleaned = await shutdown()
        report.cleanupVerified = cleaned && !hasLiveActivity()
        if let failure = controller.validationRequestFailure {
            report.sdkRequestFailureKind = failure.kind
            report.sdkRequestFailureCode = failure.code
        }
        report.status = report.problem == nil && report.cleanupVerified && report.requestVerified &&
            report.updateVerified && report.endVerified && report.shutdownVerified ? "passed" : "failed"
        emit(report)
        finished = true
    }

    func shutdown() async -> Bool { await controller.shutdown() }

    private func submit(_ phase: AgentPhase) async throws {
        let event = AgentEvent(sessionID: sessionID, projectName: "SDK 本机验证", phase: phase)
        try store.receive([event])
        sequence += 1
        await controller.submit(snapshot: store.snapshot(at: Date()), sequence: sequence, scope: .ownedOnly, force: true)
        let result = await controller.validationDelivery()
        if let problem = result.problem { throw Failure(code: "delivery-" + problem.rawValue) }
        guard result.phase == .synchronized, result.synchronizedSequence == sequence else {
            throw Failure(code: "delivery-not-synchronized")
        }
    }

    private struct Observation { let identifier: String }

    /// Only copy Sendable values out of operation-local SDK handles. A match
    /// proves the SDK's inventory/content response, not visible island UI.
    private func observation(phase: AgentPhase) -> Observation? {
        let matches = Activity<TideIslandAttributes>.activities.filter { $0.content.state.sessionID == sessionID }
        guard matches.count == 1, let activity = matches.first,
              activity.activityState == .active || activity.activityState == .stale else { return nil }
        let state = activity.content.state
        guard state.phase == phase, state.workingCount == (phase == .working ? 1 : 0),
              state.waitingCount == (phase == .needsInput ? 1 : 0) else { return nil }
        return Observation(identifier: activity.id)
    }

    private func hasLiveActivity() -> Bool {
        Activity<TideIslandAttributes>.activities.contains { activity in
            guard activity.content.state.sessionID == sessionID else { return false }
            switch activity.activityState {
            case .ended, .dismissed: return false
            default: return true
            }
        }
    }

    private func waitUntil(_ code: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
        while !condition() {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Failure(code: code) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private struct Failure: Error { let code: String }

    private struct Report: Encodable {
        let schemaVersion = 1
        let kind = "tide-island-native-sdk-smoke"
        let sourceRevision: String
        var status = "failed"
        var validationMode = "foreground"
        var foregroundObserved = false
        var requestVerified = false
        var updateVerified = false
        var endVerified = false
        var shutdownVerified = false
        var cleanupVerified = false
        var problem: String?
        var sdkRequestFailureKind: String?
        var sdkRequestFailureCode: Int?
        let syntheticSource = true
        let visibleIslandVerified = false
        let realSessionIntegrationVerified = false
    }

    private func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard var data = try? encoder.encode(report) else { return }
        data.append(0x0a)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}
#endif
