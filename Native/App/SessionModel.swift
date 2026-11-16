import AppKit
import Combine
import Darwin
import Dispatch
import Foundation
import TideIslandCore

@MainActor
final class SessionModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var statusMessage: String?

    private var registry = SessionRegistry()
    private let activities = NativeActivityController()
    private var inbox: EventInbox?
    private var monitor: InboxMonitor?
    private var updateTask: Task<Void, Never>?

    init() {
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
        do {
            guard let inbox else { return }
            let batch = try inbox.readRecent()
            var changed = false
            // Startup must not revive old "working" events as a live task.
            let cutoff = Date().addingTimeInterval(-15 * 60)
            for event in batch.events where event.occurredAt >= cutoff {
                if try registry.apply(event) { changed = true }
            }
            if changed { publish() }
            if batch.rejectedFiles > 0 {
                statusMessage = "已忽略 \(batch.rejectedFiles) 个无法识别的事件文件。"
            }
        } catch {
            statusMessage = "读取会话事件失败。"
        }
    }

    func loadDemo() {
        do {
            try registry.apply(AgentEvent(
                sessionID: "tide-island-demo", projectName: "演示 · TideIsland", phase: .working
            ))
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

    func openWave(for session: AgentSession) {
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

    private func publish() {
        sessions = registry.sessions
        let current = sessions
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            do {
                try await self?.activities.update(sessions: current)
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = "原生实时活动暂不可用，请检查系统的实时活动设置。"
            }
        }
    }
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
