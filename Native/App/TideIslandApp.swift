import SwiftUI

@main
struct TideIslandApp: App {
    @NSApplicationDelegateAdaptor(TideIslandApplicationDelegate.self) private var delegate

    var body: some Scene {
        Window("TideIsland · 潮汐岛", id: "sessions") {
            if NativeSDKValidation.isRequested {
                Text("正在验证本机原生 SDK…\n结果将写入本次测试日志。")
                    .padding()
            } else {
                SessionListView(model: delegate.model)
                    .onOpenURL { delegate.model.openSession(url: $0) }
            }
        }
        .defaultSize(width: 480, height: 560)

        Settings {
            if !NativeSDKValidation.isRequested { PreferencesView(model: delegate.model) }
        }

        MenuBarExtra("TideIsland", systemImage: "water.waves", isInserted: .constant(NativeSDKValidation.showsMenuItem)) {
            if NativeSDKValidation.isRequested { Text("正在验证本机原生 SDK…") }
            else { MenuContent(model: delegate.model) }
        }
    }
}

@MainActor
private final class TideIslandApplicationDelegate: NSObject, NSApplicationDelegate {
    lazy var model = SessionModel()
    #if DEBUG
    private var sdkSmoke: NativeSDKSmoke?
    #endif
    private var terminating = false
    private var replied = false
    private var timeout: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        guard NativeSDKValidation.isRequested else { return }
        let smoke = NativeSDKSmoke()
        sdkSmoke = smoke
        Task {
            await smoke.run()
            // Cleanup has completed before returning to AppKit. The delegate
            // can finish this explicit test without another async quit cycle.
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if NativeSDKValidation.isRequested, sdkSmoke?.finished == true { return .terminateNow }
        #endif
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            #if DEBUG
            if NativeSDKValidation.isRequested { _ = await sdkSmoke?.shutdown() }
            else { await model.shutdown() }
            #else
            await model.shutdown()
            #endif
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
    // Menu entries stay fixed while AppKit is tracking an open menu. Actions
    // still use the live model; detailed status belongs in the session window.
    let model: SessionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("潮汐岛")
        Button("打开会话") {
            openWindow(id: "sessions")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("加载演示会话") { model.loadDemo() }
        SettingsLink { Label("设置…", systemImage: "gearshape") }
            .keyboardShortcut(",")
        Button("重新检查系统状态") { model.recheckSystemStatus() }
        Divider()
        Button("退出 TideIsland") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
