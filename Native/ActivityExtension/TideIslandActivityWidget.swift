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
            let appearance = ActivityAppearance(display: display, phase: context.state.phase)
            ActivitySummaryView(display: display, appearance: appearance)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(display.sessionURL)
        } dynamicIsland: { context in
            let display = IslandActivityViewState(content: context.state, isStale: context.isStale)
            let appearance = ActivityAppearance(display: display, phase: context.state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityStatusView(display: display, appearance: appearance)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityBrandLabel()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityContentView(display: display, appearance: appearance)
                        .padding(.top, 6)
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
    let waitingAccent: Color

    init(display: IslandActivityViewState, phase: AgentPhase) {
        if !display.isValid {
            accent = .orange
        } else if display.isStale {
            accent = .gray
        } else {
            accent = phase == .needsInput ? .orange : .cyan
        }
        waitingAccent = display.isValid && !display.isStale && phase == .needsInput
            ? .orange : .white.opacity(0.58)
    }
}

private struct ActivitySummaryView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
    @ScaledMetric(relativeTo: .caption) private var fontSize = 12

    var body: some View {
        Label(display.title, systemImage: display.symbolName)
            .font(.system(size: fontSize, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(appearance.accent)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(display.title)
    }
}

private struct ActivityBrandLabel: View {
    @ScaledMetric(relativeTo: .caption2) private var fontSize = 11

    var body: some View {
        Text("潮汐岛")
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
            .accessibilityHidden(true)
    }
}

private struct ActivityContentView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance
    @ScaledMetric(relativeTo: .headline) private var projectFontSize = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(display.projectName)
                .font(.system(size: projectFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .privacySensitive()
            ActivityFooterView(display: display, appearance: appearance)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityFooterView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ActivityCountsView(display: display, appearance: appearance)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                ActivitySessionLink(display: display)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                ActivityCountsView(display: display, appearance: appearance)
                HStack {
                    Spacer(minLength: 0)
                    ActivitySessionLink(display: display)
                }
            }
        }
    }
}

private struct ActivityCountsView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance

    var body: some View {
        Group {
            if let working = display.workingText, let waiting = display.waitingText {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ActivityMetric(text: working, foreground: .white.opacity(0.88))
                        ActivityMetric(text: waiting, foreground: appearance.waitingAccent)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) {
                        ActivityMetric(text: working, foreground: .white.opacity(0.88))
                        ActivityMetric(text: waiting, foreground: appearance.waitingAccent)
                    }
                }
            } else {
                Text(display.countsText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.countsText)
    }
}

private struct ActivityMetric: View {
    let text: String
    let foreground: Color
    @ScaledMetric(relativeTo: .caption) private var fontSize = 12

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(foreground)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ActivitySessionLink: View {
    let display: IslandActivityViewState
    @ScaledMetric(relativeTo: .caption) private var fontSize = 12

    var body: some View {
        if let url = display.sessionURL {
            Link(destination: url) {
                HStack(spacing: 5) {
                    Text("打开会话")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.09), in: Capsule())
                // The visual capsule stays light; the native Link still has
                // a 44-point target for touch and keyboard interaction.
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
