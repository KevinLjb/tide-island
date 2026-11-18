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
            ActivityPanelView(display: display, appearance: appearance)
                .padding(ActivityPanelView.inset)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(display.sessionURL)
        } dynamicIsland: { context in
            let display = IslandActivityViewState(content: context.state, isStale: context.isStale)
            let appearance = ActivityAppearance(display: display, content: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityPanelView(display: display, appearance: appearance)
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
            .contentMargins(.all, ActivityPanelView.inset, for: .expanded)
            .keylineTint(appearance.accent)
            .widgetURL(display.sessionURL)
        }
    }
}

private struct ActivityAppearance {
    static let waiting = Color(red: 1, green: 0.72, blue: 0.34)

    let accent: Color
    let workingCount: Int?
    let waitingCount: Int?

    init(display: IslandActivityViewState, content: IslandActivityContent) {
        if !display.isValid {
            accent = Self.waiting
        } else if display.isStale {
            accent = .gray
        } else {
            accent = content.phase == .needsInput
                ? Self.waiting : Color(red: 0.43, green: 0.79, blue: 0.96)
        }
        workingCount = display.isValid && !display.isStale ? content.workingCount : nil
        waitingCount = display.isValid && !display.isStale ? content.waitingCount : nil
    }
}

private struct ActivityPanelView: View {
    static let inset: Double = 16

    let display: IslandActivityViewState
    let appearance: ActivityAppearance

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 10) {
                ActivityIdentityView(display: display, appearance: appearance)
                HStack(spacing: 8) {
                    ActivityCountsView(display: display, appearance: appearance)
                    Spacer(minLength: 0)
                    ActivitySessionLink(display: display)
                }
                .frame(minHeight: 44, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            // The host can offer less vertical space than the expanded layout needs.
            HStack(spacing: 8) {
                ActivityIdentityView(display: display, appearance: appearance, condensed: true)
                ActivitySessionLink(display: display, iconOnly: true)
                    .fixedSize()
            }
        }
        .frame(idealWidth: 268, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct ActivityIdentityView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance
    var condensed = false
    @ScaledMetric(relativeTo: .headline) private var projectFontSize = 17

    var body: some View {
        HStack(spacing: condensed ? 8 : 12) {
            Image(systemName: display.symbolName)
                .font(.system(size: condensed ? 14 : 21, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(appearance.accent)
                .frame(width: condensed ? 26 : 46, height: condensed ? 26 : 46)
                .background {
                    RoundedRectangle(cornerRadius: condensed ? 8 : 13, style: .continuous)
                        .fill(LinearGradient(colors: [appearance.accent.opacity(0.24), appearance.accent.opacity(0.09)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(display.projectName)
                    .font(.system(size: projectFontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .privacySensitive()

                if condensed && display.isValid && !display.isStale {
                    ViewThatFits(in: .horizontal) {
                        ActivityCountsView(display: display, appearance: appearance, singleLine: true)
                            .fixedSize(horizontal: true, vertical: false)
                        status
                    }
                } else {
                    status
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(condensed ? display.accessibilityLabel : display.statusAccessibilityLabel)
        .privacySensitive()
    }

    private var status: some View {
        Text(display.title)
            .font(.caption.weight(.medium))
            .foregroundStyle(appearance.accent)
            .lineLimit(1)
    }
}

private struct ActivityCountsView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance
    var singleLine = false

    var body: some View {
        Group {
            if let working = display.workingText, let waiting = display.waitingText,
               let workingCount = appearance.workingCount, let waitingCount = appearance.waitingCount {
                if singleLine {
                    inlineCounts(workingCount, waitingCount, working: working, waiting: waiting)
                } else {
                    ViewThatFits(in: .horizontal) {
                        inlineCounts(workingCount, waitingCount, working: working, waiting: waiting)
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 2) {
                            if workingCount > 0 { Text("工作中 \(bounded(workingCount))") }
                            if waitingCount > 0 {
                                Text("待处理 \(bounded(waitingCount))").foregroundStyle(ActivityAppearance.waiting)
                            }
                            if workingCount == 0 && waitingCount == 0 { Text(display.countsText) }
                        }
                    }
                }
            } else {
                Text(display.countsText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(.white.opacity(0.66))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.countsText)
    }

    private func inlineCounts(_ workingCount: Int, _ waitingCount: Int, working: String, waiting: String) -> some View {
        HStack(spacing: 7) {
            if workingCount > 0 { Text(working) }
            if workingCount > 0 && waitingCount > 0 {
                Circle().fill(.white.opacity(0.28)).frame(width: 3, height: 3)
                    .accessibilityHidden(true)
            }
            if waitingCount > 0 { Text(waiting).foregroundStyle(ActivityAppearance.waiting) }
            if workingCount == 0 && waitingCount == 0 { Text(display.countsText) }
        }
    }

    private func bounded(_ count: Int) -> String { count > 99 ? "99+" : String(count) }
}

private struct ActivitySessionLink: View {
    let display: IslandActivityViewState
    var iconOnly = false

    var body: some View {
        if let url = display.sessionURL {
            Link(destination: url) {
                ViewThatFits(in: .horizontal) {
                    if !iconOnly {
                        HStack(spacing: 5) {
                            Text("打开会话")
                            arrow
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.085), in: Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    arrow
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.085), in: Circle())
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开\(display.projectName)的会话")
            .accessibilityHint("在潮汐岛中查看此会话并请求返回 Wave")
            .privacySensitive()
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.up.right")
            .accessibilityHidden(true)
    }
}
