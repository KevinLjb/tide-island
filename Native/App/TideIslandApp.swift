import SwiftUI

@main
struct TideIslandApp: App {
    @NSApplicationDelegateAdaptor(TideIslandApplicationDelegate.self) private var delegate

    var body: some Scene {
        Window("TideIsland · 潮汐岛", id: "sessions") {
            SessionListView(model: delegate.model)
                .onOpenURL { delegate.model.openSession(url: $0) }
        }
        .defaultSize(width: 480, height: 420)

        Settings { PreferencesView(model: delegate.model) }

        MenuBarExtra("TideIsland", systemImage: "water.waves") {
            MenuContent(model: delegate.model)
        }
    }
}

@MainActor
private final class TideIslandApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = SessionModel()
    private var terminating = false
    private var replied = false
    private var timeout: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await model.shutdown()
            finishTermination(sender)
        }
        timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            // Best effort only: forced quit/crash and an unresponsive SDK are
            // recovered from public inventory on the next primary startup.
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ application: NSApplication) {
        guard !replied else { return }
        replied = true; timeout?.cancel(); timeout = nil
        application.reply(toApplicationShouldTerminate: true)
    }
}

private struct MenuContent: View {
    @ObservedObject var model: SessionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开会话") {
            openWindow(id: "sessions")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("加载演示会话") { model.loadDemo() }
        SettingsLink { Label("设置…", systemImage: "gearshape") }
            .keyboardShortcut(",")
        Divider()
        Button("退出 TideIsland") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
