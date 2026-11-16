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
    @Published private(set) var preferences = AppPreferences()
    @Published private(set) var preferencesMessage: String?
    @Published private(set) var notificationBusy = false
    @Published private(set) var loginBusy = false
    @Published private(set) var loginItemState = LoginItemState.disabled
    @Published private(set) var systemStatusBusy = false
    @Published private var activityAvailability = NativeActivityAvailability.unknown
    @Published private var notificationAuthorization: SessionReminderAuthorization?
    @Published private var activityProblem: IslandActivityError?
    @Published private var reminderProblem: SessionReminderProblem?

    var sessions: [SessionStatus] { snapshot?.sessions ?? [] }
    var ignoredSessions: [SessionStatus] { snapshot?.ignoredSessions ?? [] }

    private let activities = NativeActivityController()
    private let reminders = NativeReminderController()
    private let preferenceStore = NativePreferences()
    private let loginItems = NativeLoginItemClient()
    private var notificationTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var notificationRevision: UInt64 = 0
    private var systemStatusTask: Task<Void, Never>?
    private var systemStatusRevision: UInt64 = 0
    private var receiver: InboxReceiver?
    private var frameTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var systemActivityTask: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?
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

    init() {
        preferences = preferenceStore.document.preferences
        if preferenceStore.document.problem != nil {
            preferencesMessage = "设置暂时无法读取，原记录已保留。可恢复显示与提醒默认值后重新设置。"
        }
        loginItemState = loginItems.state()
        reminders.onOpenSession = { [weak self] url in self?.openSession(url: url) }
        let reminderDeliveries = reminders.frames
        reminderTask = Task { [weak self] in
            for await delivery in reminderDeliveries {
                guard !Task.isCancelled, let self else { break }
                reminderProblem = delivery.problem
            }
        }
        let deliveries = activities.frames
        activityTask = Task { [weak self] in
            for await delivery in deliveries {
                guard !Task.isCancelled, let self else { break }
                activityProblem = delivery.problem
            }
        }
        let changes = activities.changes
        systemActivityTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { break }
                refreshSystemStatus()
                reloadInbox()
            }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadInbox(); self?.refreshSystemStatus() }
            }
            .store(in: &subscriptions)
        connectReceiver()
        refreshSystemStatus()
    }

    var preferencesReadOnly: Bool { preferenceStore.document.problem != nil }

    var systemStatus: SystemStatusProjection {
        SystemStatusProjection(activity: activityAvailability, hasConfirmedSource: activityScope == .application,
                               activityProblem: activityProblem, remindersEnabled: preferences.reminders.enabled,
                               notificationAuthorization: notificationAuthorization, reminderProblem: reminderProblem,
                               login: loginItemState)
    }

    /// Query public settings only. The revision rejects results from an older
    /// activation / refresh even when the OS ignores task cancellation.
    func refreshSystemStatus() {
        guard !stopping else { return }
        systemStatusRevision &+= 1
        let revision = systemStatusRevision
        systemStatusTask?.cancel()
        activityAvailability = activities.availability()
        refreshLoginItemState()
        notificationAuthorization = nil
        systemStatusBusy = true
        systemStatusTask = Task { [weak self] in
            guard let self else { return }
            let authorization = await reminders.authorization()
            guard !Task.isCancelled, !stopping, systemStatusRevision == revision else { return }
            notificationAuthorization = authorization
            systemStatusBusy = false; systemStatusTask = nil
        }
    }

    func recheckSystemStatus() {
        refreshSystemStatus()
        // Forced synchronization still goes through the source receiver,
        // ordered scheduler and existing ownership / dismissal safeguards.
        reloadInbox()
    }

    func displayedSessions(at now: Date) -> [SessionStatus] { preferences.visibleStatuses(sessions, at: now) }
    func displayedIgnoredSessions(at now: Date) -> [SessionStatus] { preferences.visibleStatuses(ignoredSessions, at: now) }
    func displayName(for status: SessionStatus) -> String { preferences.projectName(for: status) }

    func browser(projectID: String?, showsIgnored: Bool, at now: Date) -> SessionBrowserProjection {
        let current = snapshot ?? SessionSnapshot.empty
        return SessionBrowserProjection(snapshot: current, preferences: preferences, projectID: projectID,
                                        showsIgnored: showsIgnored, at: now)
    }

    func displayedSession(for reference: SessionReference, at now: Date) -> SessionStatus? {
        (displayedSessions(at: now) + displayedIgnoredSessions(at: now)).first { $0.reference == reference }
    }

    func displayedSession(withID id: String, at now: Date) -> SessionStatus? {
        (displayedSessions(at: now) + displayedIgnoredSessions(at: now)).first { $0.id == id }
    }

    func metadataHistory(for reference: SessionReference) async -> Result<SessionMetadataHistory, SessionMetadataProblem> {
        guard !stopping, let receiver else { return .failure(.sourceUnavailable) }
        let result = await receiver.metadataHistory(for: reference)
        guard !Task.isCancelled, !stopping, activityScope == .application else { return .failure(.sourceUnavailable) }
        guard displayedSession(for: reference, at: Date()) != nil else { return .failure(.staleSelection) }
        return result
    }

    func updatePreferences(_ change: (inout AppPreferences) -> Void) {
        guard !stopping else { return }
        var value = preferences; change(&value)
        do {
            try preferenceStore.save(value)
            preferences = value; preferencesMessage = nil
            submitActivity()
        } catch { preferencesMessage = "设置尚未保存，原记录已保留；请先恢复默认值后重试。" }
        refreshStatusMessage()
    }

    func setRemindersEnabled(_ enabled: Bool) {
        guard !stopping, !notificationBusy, !preferencesReadOnly else { return }
        guard enabled else { updatePreferences { $0.reminders.enabled = false }; return }
        notificationBusy = true
        notificationRevision &+= 1
        let revision = notificationRevision
        notificationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if notificationRevision == revision { notificationBusy = false; notificationTask = nil }
            }
            do {
                let allowed = try await reminders.requestAuthorization()
                guard !Task.isCancelled, !stopping, notificationRevision == revision else { return }
                if allowed { updatePreferences { $0.reminders.enabled = true } }
                else { preferencesMessage = "系统未允许通知，请在系统设置的通知中允许潮汐岛。"; refreshStatusMessage() }
                refreshSystemStatus()
            } catch {
                guard !Task.isCancelled, !stopping, notificationRevision == revision else { return }
                preferencesMessage = "暂时无法请求通知权限，请稍后重试。"; refreshStatusMessage()
                refreshSystemStatus()
            }
        }
    }

    func setQuietHoursEnabled(_ enabled: Bool) {
        do {
            let hours: SessionQuietHours?
            if enabled { hours = try SessionQuietHours(startMinute: 22 * 60, endMinute: 8 * 60) }
            else { hours = nil }
            updatePreferences { $0.reminders.quietHours = hours }
        } catch { preferencesMessage = "安静时段暂时无法设置。"; refreshStatusMessage() }
    }

    func setQuietHoursMinute(_ minute: Int, start: Bool) {
        guard let hours = preferences.reminders.quietHours else { return }
        do {
            let value = try SessionQuietHours(startMinute: start ? minute : hours.startMinute, endMinute: start ? hours.endMinute : minute)
            updatePreferences { $0.reminders.quietHours = value }
        } catch { preferencesMessage = "开始时间和结束时间需要不同。"; refreshStatusMessage() }
    }

    func refreshLoginItemState() { if !stopping { loginItemState = loginItems.state() } }
    func openLoginItemSettings() { loginItems.openSettings() }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !stopping, !loginBusy, !preferencesReadOnly else { return }
        loginBusy = true
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { loginBusy = false; loginTask = nil }
            do {
                let state = try await loginItems.setEnabled(enabled)
                guard !Task.isCancelled, !stopping else { return }
                loginItemState = state
                updatePreferences { $0.launchAtLogin = state.isRequested }
            } catch {
                guard !Task.isCancelled, !stopping else { return }
                refreshLoginItemState()
                preferencesMessage = "登录启动设置未完成，请在系统设置的登录项中检查。"; refreshStatusMessage()
            }
        }
    }

    func resetPreferences() {
        guard !stopping else { return }
        notificationRevision &+= 1; notificationTask?.cancel(); notificationTask = nil; notificationBusy = false
        let value = AppPreferences(launchAtLogin: loginItemState.isRequested)
        do {
            try preferenceStore.reset(value)
            preferences = value; preferencesMessage = nil
            submitActivity()
        } catch { preferencesMessage = "暂时无法恢复设置，请稍后重试。" }
        refreshStatusMessage()
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
        guard !stopping, let receiver else { return }
        Task { await receiver.previewCleanup() }
    }

    func applyCleanup() {
        guard !stopping, let receiver else { return }
        Task { await receiver.applyCleanup() }
    }

    func previewReset() async -> SessionResetPreview? {
        guard !stopping, let receiver else { return nil }
        return await receiver.previewReset()
    }

    func applyReset(expectedFingerprint: String) {
        guard !stopping, let receiver else { return }
        Task { await receiver.applyReset(expectedFingerprint: expectedFingerprint) }
    }

    func loadDemo() {
        guard !stopping, let receiver else { return }
        let event = AgentEvent(sessionID: "tide-island-demo", projectName: "演示 · TideIsland", phase: .working)
        Task { await receiver.submit(event) }
    }

    func openSession(url: URL) {
        guard !stopping else { return }
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
        guard !stopping else { return }
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
        guard !stopping, let receiver else { return }
        Task { await receiver.perform(action, for: session.reference) }
    }

    func clearSelection() {
        guard !stopping, let receiver else { return }
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
        let reminders = self.reminders, settings = preferences.reminders
        Task {
            await activities.submit(snapshot: snapshot, sequence: sequence, scope: scope, force: force,
                                    showsProjectName: settings.showsProjectName)
            await reminders.submit(snapshot: snapshot, sequence: sequence, isPrimary: scope == .application, settings: settings)
        }
    }

    func shutdown() async {
        guard !stopping else { return }
        stopping = true
        subscriptions.removeAll()
        frameTask?.cancel(); systemActivityTask?.cancel(); activityTask?.cancel()
        reminderTask?.cancel()
        systemStatusRevision &+= 1; systemStatusTask?.cancel()
        notificationRevision &+= 1; notificationTask?.cancel(); loginTask?.cancel()
        returnRevision &+= 1; returnTask?.cancel()
        // Keep the receiver lease until activity operations have settled. A
        // secondary process must not adopt while this instance is cleaning up.
        async let activityCleanup = activities.shutdown()
        async let reminderCleanup: Void = reminders.shutdown()
        _ = await (activityCleanup, reminderCleanup)
        await receiver?.stop()
    }

    private func showReturnMessage(_ message: String?, invalidatesPending: Bool = false) {
        if invalidatesPending { returnRevision &+= 1 }
        returnMessage = message
        refreshStatusMessage()
    }

    private func refreshStatusMessage() {
        statusMessage = channelMessage ?? preferencesMessage ?? returnMessage
    }

    deinit {
        frameTask?.cancel()
        activityTask?.cancel()
        systemActivityTask?.cancel()
        reminderTask?.cancel()
        systemStatusTask?.cancel()
        notificationTask?.cancel(); loginTask?.cancel()
        returnTask?.cancel()
        let activities = self.activities, reminders = self.reminders, receiver = self.receiver
        Task {
            async let activityCleanup = activities.shutdown()
            async let reminderCleanup: Void = reminders.shutdown()
            _ = await (activityCleanup, reminderCleanup)
            await receiver?.stop()
        }
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
