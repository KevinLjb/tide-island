import SwiftUI

@main
struct TideIslandApp: App {
    @StateObject private var model = SessionModel()

    var body: some Scene {
        Window("TideIsland · 潮汐岛", id: "sessions") {
            SessionListView(model: model)
                .onOpenURL { model.openSession(url: $0) }
        }
        .defaultSize(width: 480, height: 420)

        MenuBarExtra("TideIsland", systemImage: "water.waves") {
            MenuContent(model: model)
        }
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
        Divider()
        Button("退出 TideIsland") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
