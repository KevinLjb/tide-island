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
    private var updateTask: Task<Void, Never>?
    private var pendingSnapshot: SessionSnapshot?
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadInbox() }
            }
            .store(in: &subscriptions)
        connectReceiver()
    }

    private func connectReceiver() {
        do {
            let receiver = InboxReceiver(inbox: try EventInbox.applicationDefault())
            self.receiver = receiver
            frameTask = Task { [weak self, receiver] in
                await receiver.start()
                for await frame in receiver.frames {
                    guard !Task.isCancelled else { break }
                    self?.publish(frame)
                }
            }
        } catch {
            statusMessage = "无法定位本地事件目录。"
            channelNeedsRecovery = true
        }
    }

    func reloadInbox() {
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

    func loadDemo() {
        guard let receiver else { return }
        let event = AgentEvent(sessionID: "tide-island-demo", projectName: "演示 · TideIsland", phase: .working)
        Task { await receiver.submit(event) }
    }

    func openSession(url: URL) {
        guard let id = SessionLink.sessionID(from: url),
              let session = sessions.first(where: { $0.id == id }) else { return }
        openWave(for: session)
    }

    func openWave(for session: SessionStatus) {
        guard let receiver else { return }
        Task { [weak self] in
            guard await receiver.perform(.select, for: session.reference), let self else { return }
            // App activation is not proof of an exact Wave block jump.
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.commandline.waveterm") else {
                statusMessage = "未找到 Wave Terminal。"
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
                Task { @MainActor [weak self] in
                    if error != nil { self?.statusMessage = "无法打开 Wave Terminal。" }
                }
            }
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
        statusMessage = frame.health.message ?? frame.notice
        channelNeedsRecovery = frame.health.state != .healthy
        cleanupPlan = frame.cleanupPlan
        guard frame.snapshot != snapshot else { return }
        snapshot = frame.snapshot
        pendingSnapshot = frame.snapshot
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            // Keep Activity IPC serialized and coalesce bursts to the newest
            // snapshot, including an immediate loss of source confirmation.
            while let current = pendingSnapshot {
                pendingSnapshot = nil
                do { try await activities.update(snapshot: current) }
                catch { statusMessage = "原生实时活动暂不可用，请检查系统的实时活动设置。" }
            }
            updateTask = nil
        }
    }

    deinit {
        frameTask?.cancel()
        if let receiver { Task { await receiver.stop() } }
    }
}
