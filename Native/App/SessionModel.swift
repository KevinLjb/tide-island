import AppKit
import Combine
import Foundation
import TideIslandCore

@MainActor
final class SessionModel: ObservableObject {
    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var statusMessage: String?
    @Published private(set) var cleanupPlan: InboxCleanupPlan?
    @Published private(set) var channelNeedsRecovery = false

    var sessions: [SessionStatus] { snapshot?.sessions ?? [] }
    var ignoredSessions: [SessionStatus] { snapshot?.ignoredSessions ?? [] }

    private let activities = NativeActivityController()
    private var receiver: InboxReceiver?
    private var frameTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var systemActivityTask: Task<Void, Never>?
    private var activitySequence: UInt64 = 0
    private var activityScope: IslandActivityScope = .ownedOnly
    private var requiresActivityReconciliation = false
    private var stopping = false
    private var subscriptions: Set<AnyCancellable> = []
    private var waveReturn: WaveReturnCoordinator?
    private var returnTask: Task<Void, Never>?
    private var returnRevision: UInt64 = 0
    private var returnMessage: String?
    private var channelMessage: String?
    private var activityMessage: String?

    init() {
        let deliveries = activities.frames
        activityTask = Task { [weak self] in
            for await delivery in deliveries {
                guard !Task.isCancelled, let self else { break }
                activityMessage = delivery.problem == nil ? nil : "原生实时活动暂不可用，请检查系统的实时活动设置。"
                refreshStatusMessage()
            }
        }
        let changes = activities.changes
        systemActivityTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { break }
                reloadInbox()
            }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadInbox() }
            }
            .store(in: &subscriptions)
        connectReceiver()
    }

    private func connectReceiver() {
        guard !stopping else { return }
        do {
            let inbox = try EventInbox.applicationDefault()
            let receiver = InboxReceiver(inbox: inbox, persistence: SessionStateFile(inbox: inbox))
            self.receiver = receiver
            let currentSnapshot: @Sendable () async -> SessionSnapshot = { await receiver.current().snapshot }
            waveReturn = WaveReturnCoordinator(driver: NativeWaveApplicationDriver(), snapshot: currentSnapshot)
            frameTask = Task { [weak self, receiver] in
                await receiver.start()
                for await frame in receiver.frames {
                    guard !Task.isCancelled else { break }
                    self?.publish(frame)
                }
            }
        } catch {
            channelMessage = "无法定位本地事件目录。"
            refreshStatusMessage()
            channelNeedsRecovery = true
        }
    }

    func reloadInbox() {
        guard !stopping else { return }
        requiresActivityReconciliation = true
        guard let receiver else { connectReceiver(); return }
        Task { await receiver.reconnect() }
    }

    func previewCleanup() {
        guard let receiver else { return }
        Task { await receiver.previewCleanup() }
    }

    func applyCleanup() {
        guard let receiver else { return }
        Task { await receiver.applyCleanup() }
    }

    func previewReset() async -> SessionResetPreview? {
        guard let receiver else { return nil }
        return await receiver.previewReset()
    }

    func applyReset(expectedFingerprint: String) {
        guard let receiver else { return }
        Task { await receiver.applyReset(expectedFingerprint: expectedFingerprint) }
    }

    func loadDemo() {
        guard let receiver else { return }
        let event = AgentEvent(sessionID: "tide-island-demo", projectName: "演示 · TideIsland", phase: .working)
        Task { await receiver.submit(event) }
    }

    func openSession(url: URL) {
        guard let snapshot else {
            showReturnMessage("会话列表尚未准备好，请稍后重试。", invalidatesPending: true)
            return
        }
        switch SessionLink.resolve(url, in: snapshot, at: Date()) {
        case .success(let reference): openWave(for: reference)
        case .failure(let error): showReturnMessage(error.message, invalidatesPending: true)
        }
    }

    func openWave(for session: SessionStatus) {
        openWave(for: session.reference)
    }

    private func openWave(for reference: SessionReference) {
        guard let receiver, let waveReturn else {
            showReturnMessage("事件通道尚未准备好，请稍后重试。", invalidatesPending: true)
            return
        }
        guard returnTask == nil else { showReturnMessage("正在返回 Wave，请稍候。"); return }
        returnRevision &+= 1
        let revision = returnRevision
        showReturnMessage("正在返回 Wave…")
        returnTask = Task { [weak self] in
            guard let self else { return }
            defer { returnTask = nil }
            guard await receiver.perform(.select, for: reference) else {
                if returnRevision == revision { showReturnMessage("会话记录已变化，请选择当前会话重试。") }
                return
            }
            let result = await waveReturn.returnToWave(for: reference)
            guard !Task.isCancelled, returnRevision == revision else { return }
            let current = await receiver.current()
            guard !Task.isCancelled, returnRevision == revision else { return }
            guard current.snapshot.sessions.contains(where: { $0.reference == reference }) else {
                showReturnMessage("会话记录已变化，请选择当前会话重试。")
                return
            }
            showReturnMessage(result.message)
        }
    }

    func perform(_ action: SessionAction, on session: SessionStatus) {
        guard let receiver else { return }
        Task { await receiver.perform(action, for: session.reference) }
    }

    func clearSelection() {
        guard let receiver else { return }
        Task { await receiver.clearSelection() }
    }

    private func publish(_ frame: InboxFrame) {
        guard !stopping else { return }
        channelMessage = frame.persistence.message ?? frame.health.message ?? frame.notice
        refreshStatusMessage()
        channelNeedsRecovery = frame.health.state != .healthy || frame.persistence.phase == .unavailable
        cleanupPlan = frame.cleanupPlan
        let scope: IslandActivityScope = frame.health.state == .healthy ? .application : .ownedOnly
        guard frame.snapshot != snapshot || scope != activityScope || requiresActivityReconciliation else { return }
        snapshot = frame.snapshot
        activityScope = scope
        let force = requiresActivityReconciliation
        requiresActivityReconciliation = false
        submitActivity(force: force)
    }

    private func submitActivity(force: Bool = false) {
        guard !stopping, let snapshot else { return }
        activitySequence &+= 1
        let sequence = activitySequence
        let activities = self.activities, scope = activityScope
        Task { await activities.submit(snapshot: snapshot, sequence: sequence, scope: scope, force: force) }
    }

    func shutdown() async {
        guard !stopping else { return }
        stopping = true
        subscriptions.removeAll()
        frameTask?.cancel(); systemActivityTask?.cancel(); activityTask?.cancel()
        returnRevision &+= 1; returnTask?.cancel()
        // Keep the receiver lease until activity operations have settled. A
        // secondary process must not adopt while this instance is cleaning up.
        _ = await activities.shutdown()
        await receiver?.stop()
    }

    private func showReturnMessage(_ message: String?, invalidatesPending: Bool = false) {
        if invalidatesPending { returnRevision &+= 1 }
        returnMessage = message
        refreshStatusMessage()
    }

    private func refreshStatusMessage() {
        statusMessage = channelMessage ?? activityMessage ?? returnMessage
    }

    deinit {
        frameTask?.cancel()
        activityTask?.cancel()
        systemActivityTask?.cancel()
        returnTask?.cancel()
        let activities = self.activities, receiver = self.receiver
        Task { _ = await activities.shutdown(); await receiver?.stop() }
    }
}

/// Uses only the public application lookup/open route. The shared coordinator
/// remains testable without AppKit; native compilation and behavior await V005.
@MainActor
private struct NativeWaveApplicationDriver: WaveApplicationDriver {
    func state() async throws -> WaveApplicationState {
        try Task.checkCancellation()
        let identifier = WaveReturnCoordinator.bundleIdentifier
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil else { return .notInstalled }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == identifier && !$0.isTerminated }
            ? .running : .notRunning
    }

    func open() async throws -> WaveApplicationResponse {
        try Task.checkCancellation()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WaveReturnCoordinator.bundleIdentifier) else {
            return .unavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                continuation.resume(returning: error == nil && application != nil ? .accepted : .failed)
            }
        }
    }
}
