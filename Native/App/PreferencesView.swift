import SwiftUI
import TideIslandCore

struct PreferencesView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SystemStatusView(model: model)
            Form {
                Section("会话提醒") {
                    Toggle("启用提醒", isOn: Binding(get: { model.preferences.reminders.enabled }, set: model.setRemindersEnabled))
                        .disabled(model.notificationBusy)
                    if model.notificationBusy { ProgressView("正在请求通知权限…").controlSize(.small) }
                    Toggle("等待我处理时提醒", isOn: binding(\.reminders.needsInput))
                    Toggle("本轮结束时提醒", isOn: binding(\.reminders.turnEnded))
                    Toggle("播放声音", isOn: binding(\.reminders.sound))
                    Text("收到本轮结束提醒后，可返回终端确认结果。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("安静时段") {
                    Toggle("启用安静时段", isOn: Binding(get: { model.preferences.reminders.quietHours != nil }, set: model.setQuietHoursEnabled))
                    if let hours = model.preferences.reminders.quietHours {
                        DatePicker("开始", selection: timeBinding(start: true, fallback: hours.startMinute), displayedComponents: .hourAndMinute)
                        DatePicker("结束", selection: timeBinding(start: false, fallback: hours.endMinute), displayedComponents: .hourAndMinute)
                        Text("按当地时间生效，支持跨午夜；结束后不补发这一时段内的旧提醒。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("显示") {
                    Toggle("显示项目名称", isOn: binding(\.reminders.showsProjectName))
                    Text("控制会话列表、实时活动和通知中的项目名称。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("历史状态显示", selection: binding(\.historyVisibility)) {
                        ForEach(HistoryVisibility.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }
                    Text("用于已结束的本轮状态；未确认的工作会话会继续保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Codex 额度") {
                    Toggle("在展开的灵动岛显示额度", isOn: binding(\.showsCodexQuota))
                    if model.preferences.showsCodexQuota {
                        if let snapshot = model.codexQuotaState.snapshot {
                            TimelineView(.explicit([.now] + snapshot.displayBoundaries)) { context in
                                let windows = snapshot.windows(at: context.date)
                                if windows.isEmpty { Text("等待刷新额度") }
                                ForEach(windows) { window in
                                    LabeledContent {
                                        Text("\(window.remainingPercent)%").monospacedDigit()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(window.title)剩余")
                                            if let reset = window.resetsAt {
                                                Text("\(reset, format: .dateTime.month().day().hour().minute()) 重置")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Button("刷新额度") { model.refreshCodexQuota() }
                            .disabled(model.codexQuotaState == .checking)
                    }
                    Text(model.codexQuotaState.message).font(.caption).foregroundStyle(.secondary)
                }
                Section("启动") {
                    Toggle("登录时启动潮汐岛", isOn: Binding(get: { model.loginItemState.isRequested }, set: model.setLaunchAtLogin))
                        .disabled(model.loginBusy)
                    if let message = model.loginItemState.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.loginItemState == .requiresApproval {
                        Button("前往登录项设置") { model.openLoginItemSettings() }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.preferencesReadOnly)
            if let message = model.preferencesMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Button("恢复显示与提醒默认值") { model.resetPreferences() }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } })
    }
    private func timeBinding(start: Bool, fallback: Int) -> Binding<Date> {
        Binding(get: {
            let hours = model.preferences.reminders.quietHours
            let value = (start ? hours?.startMinute : hours?.endMinute) ?? fallback
            return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: value / 60, minute: value % 60)) ?? Date()
        }, set: { date in
            let fields = Calendar.current.dateComponents([.hour, .minute], from: date)
            guard let hour = fields.hour, let minute = fields.minute else { return }
            model.setQuietHoursMinute(hour * 60 + minute, start: start)
        })
    }
}

/// Shared by the session window and settings. Recovery stays available even
/// when a damaged preference record makes the editable form read-only.
struct SystemStatusView: View {
    @ObservedObject var model: SessionModel
    @Environment(\.openWindow) private var openWindow
    @State private var isExpanded = false

    var body: some View {
        let status = model.systemStatus
        VStack(alignment: .leading, spacing: 6) {
            Label(status.activitySummary, systemImage: status.attentionCount > 0 ? "exclamationmark.circle" : "info.circle")
                .font(.callout)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(status.activitySummary)
                .accessibilityLabel(status.activitySummary)
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(status.notices) { notice in
                        VStack(alignment: .leading, spacing: 4) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(notice.title).font(.callout.bold())
                                Text(notice.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            switch notice.action {
                            case .none, .checkAgain: EmptyView()
                            case .openSessions:
                                Button("打开会话") {
                                    openWindow(id: "sessions")
                                    NSApplication.shared.activate(ignoringOtherApps: true)
                                }
                            case .reminderSettings: SettingsLink { Text("查看提醒设置") }
                            case .loginSettings: Button("前往登录项设置") { model.openLoginItemSettings() }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button("重新检查系统状态") { model.recheckSystemStatus() }
                            .disabled(model.systemStatusBusy)
                        ZStack {
                            if model.systemStatusBusy {
                                ProgressView("正在检查系统状态")
                                    .labelsHidden().controlSize(.small)
                            }
                        }
                        .frame(width: 14, height: 14)
                    }
                }.padding(.top, 8)
            } label: {
                Text(status.attentionCount > 0 ? "系统状态 · \(status.attentionCount) 项需关注" : "系统状态")
                    .lineLimit(1).monospacedDigit()
            }.font(.caption)
        }
    }
}
