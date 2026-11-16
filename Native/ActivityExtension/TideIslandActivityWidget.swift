import ActivityKit
import SwiftUI
import TideIslandCore
import WidgetKit

@main
struct TideIslandWidgets: WidgetBundle {
    var body: some Widget { TideIslandActivityWidget() }
}

struct TideIslandActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TideIslandAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label(context.state.projectName, systemImage: context.state.phase.symbolName)
                    .font(.headline)
                Text(context.isStale ? "状态待确认" : context.state.phase.title)
                Text(context.isStale ? "会话状态待确认" : "工作中 \(context.state.workingCount) · 待处理 \(context.state.waitingCount)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .widgetURL(SessionLink.url(for: context.state.sessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.projectName, systemImage: "water.waves")
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.isStale ? "状态待确认" : "\(context.state.workingCount) 工作中").monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "状态待确认" : context.state.phase.title)
                }
            } compactLeading: {
                Image(systemName: context.isStale ? "clock" : context.state.phase.symbolName)
            } compactTrailing: {
                Text(context.isStale ? "?" : "\(context.state.workingCount + context.state.waitingCount)").monospacedDigit()
            } minimal: {
                Image(systemName: context.isStale ? "clock" : context.state.phase.symbolName)
            }
            .widgetURL(SessionLink.url(for: context.state.sessionID))
        }
    }
}
