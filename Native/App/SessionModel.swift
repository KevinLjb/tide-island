import AppKit
import Combine
import Darwin
import Dispatch
import Foundation
import TideIslandCore

@MainActor
final class SessionModel: ObservableObject {
    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var statusMessage: String?
    @Published private(set) var cleanupPlan: InboxCleanupPlan?

    var sessions: [SessionStatus] { snapshot?.sessions ?? [] }
    var ignoredSessions: [SessionStatus] { snapshot?.ignoredSessions ?? [] }

    private var store = SessionStore()
    private let activities = NativeActivityController()
    private var inbox: EventInbox?
    private var cursor = InboxCursor()
    private var monitor: InboxMonitor?
    private var updateTask: Task<Void, Never>?
    private var pendingSnapshot: SessionSnapshot?
    private var refreshTask: Task<Void, Never>?
    private var inboxRetryTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadInbox() }
            }
            .store(in: &subscriptions)
        do {
            let inbox = try EventInbox.applicationDefault()
            try inbox.prepare()
            self.inbox = inbox
            monitor = try InboxMonitor(directory: inbox.directory) { [weak self] in
                Task { @MainActor [weak self] in self?.reloadInbox() }
            }
            reloadInbox()
        } catch {
            statusMessage = "无法读取会话事件，请检查本地数据目录的访问权限。"
        }
    }

    func reloadInbox() {
        // Time still advances when the inbox is temporarily unavailable.
        defer { publish() }
        do {
            guard let inbox else { return }
            var nextCursor = cursor
            let batch = try inbox.readIncrementally(using: &nextCursor)
            try store.receive(batch.events)
            cursor = nextCursor
            inboxRetryTask?.cancel()
            inboxRetryTask = nil
            if batch.changedFiles > 0 || batch.removedFiles > 0 || batch.directoryChanged { cleanupPlan = nil }
            if batch.rejectedFiles > 0 {
                statusMessage = "已忽略 \(batch.rejectedFiles) 个无法识别的事件文件。"
            } else if batch.scannedFiles > InboxRetentionPolicy().maximumFiles || batch.totalBytes > InboxRetentionPolicy().maximumBytes {
                statusMessage = "事件历史超过容量目标，可预览历史清理。"
            }
        } catch InboxError.busy {
            inboxRetryTask?.cancel()
            inboxRetryTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                self?.reloadInbox()
            }
        } catch InboxError.limitExceeded {
            statusMessage = "事件历史超过读取上限，暂未加载新状态；请通过命令行提高扫描上限后预览清理。"
        } catch {
            statusMessage = "读取会话事件失败。"
        }
    }

    func previewCleanup() {
        do {
            guard let inbox else { return }
            cleanupPlan = try inbox.previewCleanup(at: Date())
        } catch {
            cleanupPlan = nil
            statusMessage = "无法生成清理预览，请检查事件目录后重试。"
        }
    }

    func applyCleanup() {
        guard let inbox, let plan = cleanupPlan else { return }
        cleanupPlan = nil
        do {
            let result = try inbox.applyCleanup(plan, expectedFingerprint: plan.fingerprint)
            reloadInbox()
            statusMessage = result.failedFiles.isEmpty
                ? "已清理 \(result.removedFiles) 个过期事件文件。"
                : "部分事件未能清理，请重新预览。"
            if !result.targetsMet { statusMessage = (statusMessage ?? "") + "受保护或无法识别的历史仍超出容量目标。" }
        } catch {
            statusMessage = "事件历史已变化或暂不可清理，请重新预览。"
        }
    }

    func loadDemo() {
        do {
            try store.receive([AgentEvent(
                sessionID: "tide-island-demo", projectName: "演示 · TideIsland", phase: .working
            )])
            publish()
        } catch {
            statusMessage = "无法加载演示会话。"
        }
    }

    func openSession(url: URL) {
        guard let id = SessionLink.sessionID(from: url),
              let session = sessions.first(where: { $0.id == id }) else { return }
        openWave(for: session)
    }

    func openWave(for session: SessionStatus) {
        guard perform(.select, on: session) else { return }
        // Block metadata is retained for the next adapter. App activation is
        // deliberately not reported as a successful exact block jump.
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

    @discardableResult
    func perform(_ action: SessionAction, on session: SessionStatus) -> Bool {
        let accepted = store.perform(action, for: session.reference, at: Date())
        if !accepted { statusMessage = "状态已变化，请使用当前会话记录重试。" }
        publish()
        return accepted
    }

    func clearSelection() {
        store.clearSelection()
        publish()
    }

    private func publish() {
        let now = Date()
        let snapshot = store.snapshot(at: now)
        scheduleRefresh(at: snapshot.nextTransitionAt, now: now)
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        pendingSnapshot = snapshot
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            // Activity IPC can suspend. Use one consumer so an older completion
            // never ends an activity while a newer working update is in flight.
            // Bursts coalesce into the latest pending session snapshot.
            while let current = pendingSnapshot {
                pendingSnapshot = nil
                do {
                    try await activities.update(snapshot: current)
                } catch {
                    statusMessage = "原生实时活动暂不可用，请检查系统的实时活动设置。"
                }
            }
            updateTask = nil
        }
    }

    private func scheduleRefresh(at deadline: Date?, now: Date) {
        refreshTask?.cancel()
        refreshTask = nil
        guard let deadline else { return }
        let delay = max(0.1, deadline.timeIntervalSince(now))
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            self?.publish()
        }
    }

    deinit { refreshTask?.cancel(); inboxRetryTask?.cancel() }
}

/// File events wake the app only when the inbox changes, without a polling loop.
private final class InboxMonitor {
    private let source: DispatchSourceFileSystemObject

    init(directory: URL, onChange: @escaping @Sendable () -> Void) throws {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write], queue: .main
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
