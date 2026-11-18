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
            let appearance = ActivityAppearance(display: display, content: context.state)
            ActivitySummaryView(display: display, appearance: appearance)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(display.sessionURL)
        } dynamicIsland: { context in
            let display = IslandActivityViewState(content: context.state, isStale: context.isStale)
            let appearance = ActivityAppearance(display: display, content: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityStatusView(display: display, appearance: appearance)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityBrandLabel()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityContentView(display: display, appearance: appearance)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: display.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(appearance.accent)
                    .accessibilityLabel(display.statusAccessibilityLabel)
                    .privacySensitive()
            } compactTrailing: {
                Text(display.compactCountText)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel(display.countsText)
            } minimal: {
                Image(systemName: display.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(appearance.accent)
                    .accessibilityLabel(display.accessibilityLabel)
                    .privacySensitive()
            }
            .keylineTint(appearance.accent)
            .widgetURL(display.sessionURL)
        }
    }
}

private struct ActivityAppearance {
    let accent: Color
    let workingCount: Int?
    let waitingCount: Int?

    init(display: IslandActivityViewState, content: IslandActivityContent) {
        if !display.isValid {
            accent = .orange
        } else if display.isStale {
            accent = .gray
        } else {
            accent = content.phase == .needsInput
                ? Color(red: 1, green: 0.72, blue: 0.34)
                : Color(red: 0.38, green: 0.81, blue: 0.95)
        }
        workingCount = display.isValid && !display.isStale ? content.workingCount : nil
        waitingCount = display.isValid && !display.isStale ? content.waitingCount : nil
    }
}

private struct ActivitySummaryView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ActivityStatusView(display: display, appearance: appearance)
                Spacer(minLength: 12)
                ActivityBrandLabel()
            }
            ActivityContentView(display: display, appearance: appearance)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .accessibilityElement(children: .contain)
    }
}

private struct ActivityStatusView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance
    @ScaledMetric(relativeTo: .caption) private var fontSize = 11

    var body: some View {
        Label(display.title, systemImage: display.symbolName)
            .font(.system(size: fontSize, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(appearance.accent)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(display.title)
    }
}

private struct ActivityBrandLabel: View {
    @ScaledMetric(relativeTo: .caption2) private var fontSize = 10

    var body: some View {
        Text("潮汐岛")
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.38))
            .accessibilityHidden(true)
    }
}

private struct ActivityContentView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance
    @ScaledMetric(relativeTo: .headline) private var projectFontSize = 16

    var body: some View {
        // One identity block and one action fit within the native host's height.
        // The project keeps the full bottom-region width, away from the camera.
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(appearance.accent)
                .frame(width: 3, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(display.projectName)
                    .font(.system(size: projectFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .privacySensitive()
                    .frame(maxWidth: .infinity, alignment: .leading)
                ActivityCountsView(display: display, appearance: appearance)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ActivitySessionLink(display: display)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityCountsView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance

    var body: some View {
        Group {
            if let working = display.workingText, let waiting = display.waitingText,
               let workingCount = appearance.workingCount, let waitingCount = appearance.waitingCount {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        if workingCount > 0 { Text(working).foregroundStyle(.white.opacity(0.64)) }
                        if workingCount > 0 && waitingCount > 0 {
                            Circle().fill(.white.opacity(0.25)).frame(width: 3, height: 3)
                                .accessibilityHidden(true)
                        }
                        if waitingCount > 0 { Text(waiting).foregroundStyle(Color.orange) }
                        if workingCount == 0 && waitingCount == 0 { Text(display.countsText) }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 2) {
                        if workingCount > 0 { Text("工作中 \(bounded(workingCount))") }
                        if waitingCount > 0 { Text("待处理 \(bounded(waitingCount))").foregroundStyle(.orange) }
                        if workingCount == 0 && waitingCount == 0 { Text(display.countsText) }
                    }
                    .lineLimit(1)
                }
            } else {
                Text(display.countsText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white.opacity(0.58))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.countsText)
    }

    private func bounded(_ count: Int) -> String { count > 99 ? "99+" : String(count) }
}

private struct ActivitySessionLink: View {
    let display: IslandActivityViewState
    @ScaledMetric(relativeTo: .caption) private var fontSize = 12

    var body: some View {
        if let url = display.sessionURL {
            Link(destination: url) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.07), in: Circle())
                    // The visible button is quiet; its native hit area stays 44pt.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开\(display.projectName)的会话")
            .accessibilityHint("在潮汐岛中查看此会话并请求返回 Wave")
            .privacySensitive()
        }
    }
}
