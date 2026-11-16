import SwiftUI
import TideIslandCore

struct SessionListView: View {
    @ObservedObject var model: SessionModel
    @State private var showsIgnored = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("潮汐岛", systemImage: "water.waves")
                    .font(.title2.bold())
                Spacer()
                Button("演示") { model.loadDemo() }
            }

            HStack {
                Text("未读 \(model.snapshot?.unreadCount ?? 0) · 待处理 \(model.snapshot?.waitingCount ?? 0)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.snapshot?.preferredSessionID != nil {
                    Button("自动选择") { model.clearSelection() }
                }
            }

            if let selected = model.snapshot?.selectedSession {
                Text("已选择：\(selected.session.projectName)").font(.caption)
            } else if model.snapshot?.preferredSessionID != nil {
                Text("选择的会话暂不可用，已按优先级回退。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let highlighted = model.snapshot?.activitySession,
               let reason = model.snapshot?.activitySelectionReason {
                Text("岛上优先：\(highlighted.session.projectName) · \(reason.title)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !model.ignoredSessions.isEmpty {
                Toggle("显示已忽略（\(model.ignoredSessions.count)）", isOn: $showsIgnored)
                    .toggleStyle(.checkbox)
            }

            if model.sessions.isEmpty && model.ignoredSessions.isEmpty {
                ContentUnavailableView(
                    "等待开发会话", systemImage: "terminal",
                    description: Text("会话开始后，在这里查看状态并返回 Wave。")
                )
            } else {
                List {
                    if model.sessions.isEmpty {
                        Text("当前状态均已忽略，可展开已忽略列表恢复。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.sessions) { session in
                        sessionRow(session)
                    }
                    if showsIgnored && !model.ignoredSessions.isEmpty {
                        Section("已忽略") {
                            ForEach(model.ignoredSessions) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
            }

            HStack {
                if model.channelNeedsRecovery {
                    Button("重新连接") { model.reloadInbox() }
                }
                Button("预览历史清理") { model.previewCleanup() }
                if let plan = model.cleanupPlan {
                    Button("清理已预览历史") { model.applyCleanup() }
                        .disabled(plan.removals.isEmpty)
                }
            }
            if let plan = model.cleanupPlan {
                Text("可清理 \(plan.removals.count) 个历史文件，保留 \(plan.protectedFiles) 个受保护事件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let plan = model.cleanupPlan, !plan.targetsMetAfterCleanup {
                Text("受保护或无法识别的记录仍超出容量目标，本次清理会保留它们。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let message = model.statusMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .accessibilityLabel(message)
            }
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 280)
    }

    private func sessionRow(_ session: SessionStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: session.symbolName).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(session.session.projectName).font(.headline)
                Text(session.title).foregroundStyle(.secondary)
                if let detail = session.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if session.hasAttentionItem {
                        Text(session.attention.isUnread ? "未读" : "已读")
                    }
                    if session.attention.isPinned { Label("置顶", systemImage: "pin.fill") }
                    if session.attention.isSelected { Label("已选择", systemImage: "checkmark.circle") }
                }
                .font(.caption)
                Text(session.attentionReason.title).font(.caption).foregroundStyle(.secondary)
                Text(session.session.updatedAt, style: .relative)
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if session.attention.isIgnored {
                        Button("恢复当前状态") { model.perform(.restore, on: session) }
                    } else {
                        Button("选择") { model.perform(.select, on: session) }
                        Button("打开 Wave") { model.openWave(for: session) }
                        Spacer()
                        Menu {
                            if session.hasAttentionItem {
                                Button(session.attention.isUnread ? "标为已读" : "标为未读") {
                                    model.perform(session.attention.isUnread ? .markRead : .markUnread, on: session)
                                }
                            }
                            Button(session.attention.isPinned ? "取消置顶" : "置顶") {
                                model.perform(session.attention.isPinned ? .unpin : .pin, on: session)
                            }
                            Button("忽略当前状态") { model.perform(.ignore, on: session) }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("会话操作")
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
