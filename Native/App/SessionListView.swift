import SwiftUI
import TideIslandCore

struct SessionListView: View {
    @ObservedObject var model: SessionModel
    @State private var showsIgnored = false
    @State private var projectID: String?
    @State private var inspection: SessionInspection?
    @State private var showsResetConfirmation = false
    @State private var resetFingerprint: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in content(at: context.date) }
            .sheet(item: $inspection) { SessionDetailView(model: model, reference: $0.reference) }
            .confirmationDialog("清除本地会话与偏好？", isPresented: $showsResetConfirmation, titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    guard let resetFingerprint else { return }
                    model.applyReset(expectedFingerprint: resetFingerprint)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会话列表和已读、忽略、置顶、选择会被清除。事件文件保留，已有记录不会立即重新导入。")
            }
    }

    private func content(at now: Date) -> some View {
        let browser = model.browser(projectID: projectID, showsIgnored: showsIgnored, at: now)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("潮汐岛", systemImage: "water.waves").font(.title2.bold())
                Spacer()
                managementMenu
            }
            SystemStatusView(model: model)
            Picker("项目", selection: $projectID) {
                Text("所有项目").tag(nil as String?)
                ForEach(browser.projects) { project in
                    Text("\(project.title)（\(project.sessionCount + (showsIgnored ? project.ignoredCount : 0))）")
                        .tag(Optional(project.id))
                }
                if let projectID, !browser.projectIsAvailable {
                    Text("当前项目已不可用").tag(Optional(projectID))
                }
            }
            Text("未读 \(browser.unreadCount) · 待处理 \(browser.waitingCount)")
                .font(.callout).foregroundStyle(.secondary)
            if let selected = model.displayedSessions(at: now).first(where: { $0.attention.isSelected }) {
                HStack {
                    Text("已选择：\(model.displayName(for: selected))").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("自动选择") { model.clearSelection() }
                }.font(.caption)
            } else if model.snapshot?.preferredSessionID != nil {
                Text("选择的会话暂不可用，已按优先级回退。").font(.caption).foregroundStyle(.secondary)
            }
            if let highlighted = model.snapshot?.activitySession, let reason = model.snapshot?.activitySelectionReason {
                Text("活动候选：\(model.displayName(for: highlighted)) · \(reason.title)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Toggle("显示已忽略（\(browser.ignoredSessions.count)）", isOn: $showsIgnored).toggleStyle(.checkbox)
            if browser.emptyReason == .none {
                List {
                    ForEach(browser.sessions) { sessionRow($0) }
                    if showsIgnored && !browser.ignoredSessions.isEmpty {
                        Section("已忽略") { ForEach(browser.ignoredSessions) { sessionRow($0) } }
                    }
                }
            } else { emptyView(browser.emptyReason) }
            if model.channelNeedsRecovery { Button("重新连接") { model.reloadInbox() } }
            if let message = model.statusMessage {
                Text(message).font(.callout).foregroundStyle(.secondary).accessibilityLabel(message)
            }
            if let message = model.diagnosticMessage {
                Text(message).font(.callout).foregroundStyle(.secondary).accessibilityLabel(message)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 340)
    }

    @ViewBuilder private func emptyView(_ reason: SessionBrowserEmptyReason) -> some View {
        switch reason {
        case .none: EmptyView()
        case .noSessions:
            ContentUnavailableView("等待开发会话", systemImage: "terminal", description: Text("会话开始后，可在这里查看状态并返回 Wave。"))
        case .hiddenHistory:
            ContentUnavailableView("近期暂无可显示状态", systemImage: "clock", description: Text("较早的已结束记录已按显示时间隐藏。"))
            SettingsLink { Text("调整显示设置") }
        case .unavailableProject:
            ContentUnavailableView("这个项目暂无可显示状态", systemImage: "folder", description: Text("可查看全部项目，或等待新的会话状态。"))
            Button("显示全部项目") { projectID = nil }
        case .ignoredOnly:
            ContentUnavailableView("当前状态已忽略", systemImage: "eye.slash", description: Text("展开已忽略列表后，可检查或恢复当前状态。"))
            Button("显示已忽略") { showsIgnored = true }
        case .invalidClock:
            ContentUnavailableView("当前时间无法确认", systemImage: "clock", description: Text("请检查系统时间后重新连接。"))
        }
    }

    private var managementMenu: some View {
        Menu("管理") {
            SettingsLink { Text("设置…") }
            Button("加载演示会话") { model.loadDemo() }
            Button("导出诊断…") { model.exportDiagnostics() }
            Divider()
            Button("预览历史清理") { model.previewCleanup() }
            if let plan = model.cleanupPlan {
                Text("可清理 \(plan.removals.count) 个文件，保留 \(plan.protectedFiles) 个受保护事件。")
                Button("清理已预览历史") { model.applyCleanup() }.disabled(plan.removals.isEmpty)
                if !plan.targetsMetAfterCleanup { Text("受保护记录仍超出容量目标。") }
            }
            Button("清除会话与偏好…") {
                Task {
                    guard let preview = await model.previewReset() else { return }
                    resetFingerprint = preview.fingerprint; showsResetConfirmation = true
                }
            }
        }
    }

    private func sessionRow(_ session: SessionStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: session.symbolName).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.displayName(for: session)).font(.headline).lineLimit(2).truncationMode(.middle)
                Text(SessionBrowserProjection.sessionLabel(for: session.id)).font(.caption).foregroundStyle(.secondary)
                Text(session.title).foregroundStyle(.secondary)
                if let detail = session.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 10) {
                    if session.hasAttentionItem { Text(session.attention.isUnread ? "未读" : "已读") }
                    if session.attention.isPinned { Label("置顶", systemImage: "pin.fill") }
                    if session.attention.isSelected { Label("已选择", systemImage: "checkmark.circle") }
                }.font(.caption)
                Text(session.attentionReason.title).font(.caption).foregroundStyle(.secondary)
                Text(session.session.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("详情") { inspection = SessionInspection(reference: session.reference) }
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
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("会话操作")
                    }
                }
            }
        }.padding(.vertical, 6)
    }
}

private struct SessionInspection: Identifiable {
    let reference: SessionReference
    var id: UUID { reference.eventID }
}

private struct SessionDetailView: View {
    @ObservedObject var model: SessionModel
    @State private var reference: SessionReference
    @State private var result: Result<SessionMetadataHistory, SessionMetadataProblem>?
    @State private var readRevision: UInt64 = 0
    @Environment(\.dismiss) private var dismiss

    init(model: SessionModel, reference: SessionReference) {
        self.model = model; _reference = State(initialValue: reference)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in content(at: context.date) }
            .task(id: "\(reference.eventID.uuidString):\(model.channelNeedsRecovery)") { await loadHistory() }
            .onDisappear { readRevision &+= 1 }
    }

    private func content(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("会话详情").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let session = model.displayedSession(for: reference, at: now) {
                Text(model.displayName(for: session)).font(.headline).lineLimit(2).truncationMode(.middle)
                Text(SessionBrowserProjection.sessionLabel(for: session.id)).font(.caption).foregroundStyle(.secondary)
                Label(session.title, systemImage: session.symbolName)
                if let detail = session.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                Text(session.session.updatedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if session.attention.isIgnored {
                        Button("恢复当前状态") { model.perform(.restore, on: session) }
                    } else {
                        Button("选择此会话") { model.perform(.select, on: session) }
                        Button("打开 Wave") { model.openWave(for: session) }
                        if session.hasAttentionItem {
                            Button(session.attention.isUnread ? "标为已读" : "标为未读") {
                                model.perform(session.attention.isUnread ? .markRead : .markUnread, on: session)
                            }
                        }
                    }
                }
                Divider()
                metadataContent
                HStack {
                    Button("重新读取观察") { Task { await loadHistory() } }
                    if model.channelNeedsRecovery { Button("重新连接") { model.reloadInbox() } }
                }
            } else {
                ContentUnavailableView("会话状态已变化", systemImage: "arrow.triangle.2.circlepath",
                                       description: Text("请查看当前状态后再进行操作。"))
                if let current = model.displayedSession(withID: reference.sessionID, at: now) {
                    Button("查看当前状态") { reference = current.reference; result = nil }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
    }

    @ViewBuilder private var metadataContent: some View {
        switch result {
        case nil: ProgressView("读取最近观察…")
        case .failure(let problem): Text(problem.message).foregroundStyle(.secondary)
        case .success(let history):
            Text("最近观察（\(history.entries.count) / \(history.availableCount)）").font(.headline)
            Text("来源确认：\(history.confirmedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            List(history.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.kindTitle)
                        if entry.isCurrentObservation { Text("当前状态").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("观察：\(entry.phase.title) · \(entry.sourceTitle)").font(.caption).foregroundStyle(.secondary)
                    Text(entry.occurredAt, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadHistory() async {
        let requested = reference
        readRevision &+= 1
        let revision = readRevision
        result = nil
        let loaded = await model.metadataHistory(for: requested)
        guard !Task.isCancelled, reference == requested, revision == readRevision else { return }
        result = loaded
    }
}
