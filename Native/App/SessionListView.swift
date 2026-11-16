import SwiftUI
import TideIslandCore

struct SessionListView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("潮汐岛", systemImage: "water.waves")
                    .font(.title2.bold())
                Spacer()
                Button("演示") { model.loadDemo() }
            }

            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "等待开发会话", systemImage: "terminal",
                    description: Text("会话开始后，在这里查看状态并返回 Wave。")
                )
            } else {
                List(model.sessions) { session in
                    HStack(spacing: 12) {
                        Image(systemName: session.symbolName)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.session.projectName).font(.headline)
                            Text(session.title).foregroundStyle(.secondary)
                            if let detail = session.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(session.session.updatedAt, style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("打开 Wave") { model.openWave(for: session) }
                    }
                    .padding(.vertical, 6)
                }
            }

            if let message = model.statusMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .accessibilityLabel(message)
            }
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 280)
    }
}
