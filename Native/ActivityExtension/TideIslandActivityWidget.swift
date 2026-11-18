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
            ActivityPanelView(display: display, appearance: appearance, codexQuota: context.state.codexQuota)
                .padding(ActivityPanelView.inset)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(display.sessionURL)
        } dynamicIsland: { context in
            let display = IslandActivityViewState(content: context.state, isStale: context.isStale)
            let appearance = ActivityAppearance(display: display, content: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityPanelView(display: display, appearance: appearance, codexQuota: context.state.codexQuota)
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
    static let working = Color(red: 0.43, green: 0.79, blue: 0.96)
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
            accent = content.phase == .needsInput ? Self.waiting : Self.working
        }
        workingCount = display.isValid && !display.isStale ? content.workingCount : nil
        waitingCount = display.isValid && !display.isStale ? content.waitingCount : nil
    }
}

private struct ActivityPanelView: View {
    static let inset: Double = 16

    let display: IslandActivityViewState
    let appearance: ActivityAppearance
    var codexQuota: CodexQuotaSnapshot? = nil

    var body: some View {
        Group {
            if display.isValid, !display.isStale, let codexQuota {
                TimelineView(.explicit([.now] + codexQuota.displayBoundaries)) { context in
                    panel(windows: codexQuota.windows(at: context.date))
                }
            } else {
                panel(windows: [])
            }
        }
        .frame(idealWidth: 268, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func panel(windows: [CodexQuotaWindow]) -> some View {
        ViewThatFits(in: .vertical) {
            if !windows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ActivityIdentityView(display: display, appearance: appearance)
                    ActivityCodexQuotaView(windows: windows)
                    footer(windows: [])
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                ActivityIdentityView(display: display, appearance: appearance)
                footer(windows: windows)
            }
            .fixedSize(horizontal: false, vertical: true)

            // The host can offer less vertical space than the expanded layout needs.
            HStack(spacing: 8) {
                ActivityIdentityView(display: display, appearance: appearance, condensed: true,
                                     codexQuota: windows.first)
                ActivitySessionLink(display: display, iconOnly: true)
                    .fixedSize()
            }
        }
    }

    private func footer(windows: [CodexQuotaWindow]) -> some View {
        HStack(spacing: 8) {
            if windows.isEmpty {
                ActivityCountsView(display: display, appearance: appearance)
            } else {
                ActivityCodexQuotaView(windows: windows, condensed: true)
            }
            Spacer(minLength: 0)
            ActivitySessionLink(display: display)
        }
        .frame(minHeight: 44, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct ActivityCodexQuotaView: View {
    let windows: [CodexQuotaWindow]
    var condensed = false

    var body: some View {
        if condensed {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { ForEach(windows) { shortValue($0) } }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 3) { ForEach(windows) { shortValue($0) } }
            }
            .foregroundStyle(.white.opacity(0.82))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Codex 额度")
            .privacySensitive()
        } else {
            HStack(alignment: .top, spacing: 12) {
                ForEach(windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Codex \(window.title)")
                                .font(.caption2).foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("余 \(window.remainingPercent)%")
                                .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
                                .foregroundStyle(.white.opacity(0.9))
                                .layoutPriority(1)
                        }
                        quotaBar(window.remainingPercent)
                        if let reset = window.resetsAt {
                            Text("\(reset, format: .dateTime.month().day().hour().minute()) 重置")
                                .font(.caption2).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText(window))
                }
            }
            .privacySensitive()
        }
    }

    private func quotaBar(_ percent: Int) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(percent <= 20 ? ActivityAppearance.waiting : ActivityAppearance.working)
                    .frame(width: geometry.size.width * Double(percent) / 100)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private func shortValue(_ window: CodexQuotaWindow) -> some View {
        Text("\(window.title)余 \(window.remainingPercent)%")
            .font(.caption2.weight(.medium)).monospacedDigit().lineLimit(1)
            .accessibilityLabel(accessibilityText(window))
    }

    private func accessibilityText(_ window: CodexQuotaWindow) -> String {
        let value = "Codex \(window.title)额度剩余 \(window.remainingPercent)%"
        guard let reset = window.resetsAt else { return value }
        return "\(value)，\(reset.formatted(.dateTime.month().day().hour().minute())) 重置"
    }
}

private struct ActivityIdentityView: View {
    let display: IslandActivityViewState
    let appearance: ActivityAppearance
    var condensed = false
    var codexQuota: CodexQuotaWindow? = nil
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
                        if let codexQuota {
                            HStack(spacing: 5) {
                                status
                                Text("余 \(codexQuota.remainingPercent)%")
                                    .font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.76))
                            }.fixedSize(horizontal: true, vertical: false)
                        }
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
        .accessibilityLabel(identityAccessibilityLabel)
        .privacySensitive()
    }

    private var identityAccessibilityLabel: String {
        guard condensed else { return display.statusAccessibilityLabel }
        guard let codexQuota else { return display.accessibilityLabel }
        return "\(display.accessibilityLabel)，Codex \(codexQuota.title)额度剩余 \(codexQuota.remainingPercent)%"
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
