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
            let display = IslandActivityViewState(content: context.state, isStale: context.isStale)
            ActivitySummaryView(display: display)
                .widgetURL(display.sessionURL)
        } dynamicIsland: { context in
            let display = IslandActivityViewState(content: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(display.projectName)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .privacySensitive()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label(display.title, systemImage: display.symbolName)
                        .font(.caption)
                        .lineLimit(2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(display.title)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        ActivityCountsView(display: display)
                        ActivitySessionLink(display: display)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: display.symbolName)
                    .accessibilityLabel(display.statusAccessibilityLabel)
                    .privacySensitive()
            } compactTrailing: {
                Text(display.compactCountText)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel(display.countsText)
            } minimal: {
                Image(systemName: display.symbolName)
                    .accessibilityLabel(display.accessibilityLabel)
                    .privacySensitive()
            }
            .widgetURL(display.sessionURL)
        }
    }
}

private struct ActivitySummaryView: View {
    let display: IslandActivityViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(display.projectName)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .privacySensitive()
            Label(display.title, systemImage: display.symbolName)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(display.title)
            ActivityCountsView(display: display)
            ActivitySessionLink(display: display)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .accessibilityElement(children: .contain)
    }
}

private struct ActivityCountsView: View {
    let display: IslandActivityViewState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(display.countsText).fixedSize(horizontal: true, vertical: false)
            if let working = display.workingText, let waiting = display.waitingText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(working)
                    Text(waiting)
                }
            } else {
                Text(display.countsText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.countsText)
    }
}

private struct ActivitySessionLink: View {
    let display: IslandActivityViewState

    var body: some View {
        if let url = display.sessionURL {
            Link(destination: url) {
                Label("打开会话", systemImage: "arrow.up.forward.app")
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("打开\(display.projectName)的会话")
            .accessibilityHint("在潮汐岛中查看此会话并请求返回 Wave")
            .privacySensitive()
        }
    }
}
