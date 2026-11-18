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
            HStack(spacing: 10) {
                Image(systemName: "water.waves")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.cyan)
                    .frame(width: 36, height: 36)
                    .background(.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("潮汐岛").font(.system(size: 17, weight: .semibold))
                    Text("开发会话").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                managementMenu
            }
            SystemStatusView(model: model)
                .padding(10)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 16) {
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
                .labelsHidden()
                .accessibilityLabel("筛选项目")
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("未读 \(browser.unreadCount)")
                    .monospacedDigit().foregroundStyle(.secondary)
                Text("待处理 \(browser.waitingCount)")
                    .monospacedDigit()
                    .foregroundStyle(browser.waitingCount > 0 ? Color.orange : Color.secondary)
            }
            .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 5) {
                SessionSelectionSummary(
                    selectedName: model.displayedSessions(at: now).first(where: { $0.attention.isSelected })
                        .map { model.displayName(for: $0) },
                    hasPreferredSession: model.snapshot?.preferredSessionID != nil,
                    clearSelection: { model.clearSelection() })
                SessionActivitySummary(
                    projectName: model.snapshot?.activitySession.map { model.displayName(for: $0) },
                    reason: model.snapshot?.activitySelectionReason?.title)
            }
            HStack {
                Text("会话").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle("显示已忽略（\(browser.ignoredSessions.count)）", isOn: $showsIgnored)
                    .toggleStyle(.checkbox).font(.system(size: 10))
            }
            Group {
                if browser.emptyReason == .none {
                    List {
                        ForEach(browser.sessions) { session in sessionRow(session) }
                        if showsIgnored && !browser.ignoredSessions.isEmpty {
                            Section("已忽略") { ForEach(browser.ignoredSessions) { sessionRow($0) } }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                } else { emptyView(browser.emptyReason) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            SessionWindowFooter(statusMessage: model.statusMessage, diagnosticMessage: model.diagnosticMessage,
                                needsRecovery: model.channelNeedsRecovery, reconnect: { model.reloadInbox() })
        }
        .controlSize(.small)
        .padding(16)
        .frame(minWidth: 420, minHeight: 480)
        .background(Color(red: 0.065, green: 0.07, blue: 0.08))
        .preferredColorScheme(.dark)
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
        SessionCardView(session: session, projectName: model.displayName(for: session),
                        open: { model.openWave(for: session) }) {
            Button("详情") { inspection = SessionInspection(reference: session.reference) }
            if session.attention.isIgnored {
                Button("恢复当前状态") { model.perform(.restore, on: session) }
            } else {
                Button("选择此会话") { model.perform(.select, on: session) }
                Divider()
                if session.hasAttentionItem {
                    Button(session.attention.isUnread ? "标为已读" : "标为未读") {
                        model.perform(session.attention.isUnread ? .markRead : .markUnread, on: session)
                    }
                }
                Button(session.attention.isPinned ? "取消置顶" : "置顶") {
                    model.perform(session.attention.isPinned ? .unpin : .pin, on: session)
                }
                Button("忽略当前状态") { model.perform(.ignore, on: session) }
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private struct SessionCardView<Actions: View>: View {
    let session: SessionStatus
    let projectName: String
    let open: () -> Void
    @ViewBuilder var actions: () -> Actions

    private var accent: Color {
        if session.activity == .unknown { return .secondary }
        if session.activity == .needsInput || session.session.phase == .failed { return .orange }
        if session.activity == .working { return .cyan }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 32, height: 32)
                .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(projectName).font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .help(projectName).privacySensitive()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(session.title).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accent).lineLimit(1)
                }
                Text(session.detail ?? session.attentionReason.title)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true)
                    .help(session.detail ?? session.attentionReason.title)
                HStack(spacing: 6) {
                    Text(SessionBrowserProjection.sessionLabel(for: session.id))
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    if session.hasAttentionItem && session.attention.isUnread {
                        Circle().fill(accent).frame(width: 4, height: 4)
                            .accessibilityLabel("未读")
                    }
                    if session.attention.isPinned {
                        Image(systemName: "pin.fill").accessibilityLabel("已置顶")
                    }
                    if session.attention.isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan)
                            .accessibilityLabel("已选择")
                    }
                    Spacer(minLength: 0)
                    Text(session.session.updatedAt, style: .relative).lineLimit(1).monospacedDigit()
                }
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
            if !session.attention.isIgnored {
                Button(action: open) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.05), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("返回 Wave")
                .accessibilityLabel("打开\(projectName)的 Wave 会话")
            }
            Menu(content: actions) {
                Image(systemName: "ellipsis").font(.system(size: 13))
                    .frame(width: 24, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(projectName)的会话操作")
        }
        .padding(12)
        .background(session.attention.isSelected ? Color.cyan.opacity(0.045) : .white.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(session.attention.isSelected ? Color.cyan.opacity(0.23) : .white.opacity(0.055), lineWidth: 1)
        }
    }
}

// Live metadata changes content, not the space reserved around the list.
private struct SessionSelectionSummary: View {
    let selectedName: String?
    let hasPreferredSession: Bool
    let clearSelection: () -> Void

    private var title: String {
        if let selectedName { return "已选择：\(selectedName)" }
        return hasPreferredSession ? "选择的会话暂不可用，已按优先级回退。" : "按优先级自动选择会话"
    }

    var body: some View {
        HStack {
            Text(title).lineLimit(1).truncationMode(.middle).help(title)
            Spacer(minLength: 8)
            Button("自动选择", action: clearSelection)
                .opacity(hasPreferredSession ? 1 : 0)
                .disabled(!hasPreferredSession)
                .accessibilityHidden(!hasPreferredSession)
        }
        .font(.caption)
    }
}

private struct SessionActivitySummary: View {
    let projectName: String?
    let reason: String?

    private var title: String {
        if let projectName, let reason { return "活动候选：\(projectName) · \(reason)" }
        return "活动候选：暂无已确认的工作状态"
    }

    var body: some View {
        Text(title)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).help(title)
    }
}

private struct SessionWindowFooter: View {
    let statusMessage: String?
    let diagnosticMessage: String?
    let needsRecovery: Bool
    let reconnect: () -> Void

    private var message: String {
        [statusMessage, diagnosticMessage].compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message.isEmpty ? " " : message)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(message)
                .accessibilityLabel(message)
                .accessibilityHidden(message.isEmpty)
            Button("重新连接", action: reconnect)
                .fixedSize()
                .opacity(needsRecovery ? 1 : 0)
                .disabled(!needsRecovery)
                .accessibilityHidden(!needsRecovery)
        }
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
