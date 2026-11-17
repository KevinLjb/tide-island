/// These values describe public API availability / authorization only. They
/// never assert that a Dynamic Island exists or that the OS displayed a view.
public enum NativeActivityAvailability: Equatable, Sendable {
    case unknown, unavailable, disabled, allowed
}

public enum LoginItemState: Equatable, Sendable {
    case disabled, enabled, requiresApproval, unavailable
    public var isRequested: Bool { self == .enabled || self == .requiresApproval }
    public var message: String? {
        switch self {
        case .disabled, .enabled: nil
        case .requiresApproval: "等待系统允许，可前往登录项设置查看。"
        case .unavailable: "请先安装潮汐岛，再设置登录时启动。"
        }
    }
}

public enum SystemStatusLevel: Equatable, Sendable { case information, attention }
public enum SystemStatusAction: Equatable, Sendable { case none, checkAgain, openSessions, reminderSettings, loginSettings }

public struct SystemStatusNotice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let level: SystemStatusLevel
    public let action: SystemStatusAction
}

/// Pure presentation of independent system observations. Refreshing this
/// projection cannot request permissions, register login items, replay a
/// reminder, change a session or infer visible system presentation.
public struct SystemStatusProjection: Equatable, Sendable {
    public let notices: [SystemStatusNotice]
    public let activitySummary: String
    public var attentionCount: Int { notices.filter { $0.level == .attention }.count }

    public init(activity: NativeActivityAvailability = .unknown, hasConfirmedSource: Bool = false,
                activityProblem: IslandActivityError? = nil, remindersEnabled: Bool = false,
                notificationAuthorization: SessionReminderAuthorization? = nil,
                reminderProblem: SessionReminderProblem? = nil, login: LoginItemState = .disabled) {
        let activityNotice: SystemStatusNotice
        switch activity {
        case .unknown:
            activityNotice = .init(id: "activity.checking", title: "正在检查实时活动", detail: "菜单栏与会话列表仍可使用。", level: .information, action: .checkAgain)
        case .unavailable:
            activityNotice = .init(id: "activity.unavailable", title: "当前环境不支持原生实时活动", detail: "可继续使用菜单栏与会话列表；原生展示需要支持的系统。", level: .attention, action: .none)
        case .disabled:
            activityNotice = .init(id: "activity.disabled", title: "系统已关闭实时活动", detail: "请在系统设置中检查实时活动。菜单栏与会话列表仍可使用。", level: .attention, action: .checkAgain)
        case .allowed:
            activityNotice = hasConfirmedSource
                ? .init(id: "activity.allowed", title: "系统允许实时活动", detail: "有新鲜会话时可提交状态；展示位置和显示时机由系统决定。", level: .information, action: .none)
                : .init(id: "activity.source", title: "实时活动等待来源确认", detail: "请先恢复事件通道；列表保留的观察可能尚未确认。", level: .attention, action: .checkAgain)
        }
        var result = [activityNotice]
        if let problem = activityProblem, !(problem == .disabled && activity == .disabled) {
            let notice = Self.activityFailure(problem)
            result.append(notice)
            activitySummary = activity == .allowed ? notice.title : activityNotice.title
        } else { activitySummary = activityNotice.title }

        if !remindersEnabled {
            result.append(.init(id: "reminder.off", title: "会话提醒已关闭", detail: "可在设置中主动启用；检查状态不会申请通知权限。", level: .information, action: .reminderSettings))
        } else {
            switch notificationAuthorization {
            case nil:
                result.append(.init(id: "reminder.checking", title: "正在检查通知权限", detail: "会话提醒与实时活动使用独立的系统设置。", level: .information, action: .checkAgain))
            case .notRequested:
                result.append(.init(id: "reminder.notRequested", title: "通知权限尚未申请", detail: "请在提醒设置中主动启用，完成系统授权。", level: .attention, action: .reminderSettings))
            case .denied:
                result.append(.init(id: "reminder.denied", title: "系统未允许通知", detail: "请在系统设置的通知中允许潮汐岛，再重新检查。", level: .attention, action: .reminderSettings))
            case .allowed:
                result.append(hasConfirmedSource
                    ? .init(id: "reminder.allowed", title: "系统允许通知", detail: "提醒仍遵循已读、忽略和安静时段；系统可能调整横幅与声音。", level: .information, action: .none)
                    : .init(id: "reminder.source", title: "提醒等待来源确认", detail: "恢复通道后只处理符合条件的新提醒，不补发旧提醒。", level: .attention, action: .checkAgain))
            }
            if let problem = reminderProblem,
               !(problem == .permissionDenied && notificationAuthorization == .denied),
               !(problem == .authorizationNotRequested && notificationAuthorization == .notRequested) {
                result.append(Self.reminderFailure(problem))
            }
        }
        if login == .requiresApproval {
            result.append(.init(id: "login.approval", title: "登录启动等待系统允许", detail: login.message ?? "", level: .attention, action: .loginSettings))
        } else if login == .unavailable {
            result.append(.init(id: "login.unavailable", title: "登录启动暂不可用", detail: login.message ?? "", level: .information, action: .none))
        }
        notices = result
    }

    private static func activityFailure(_ problem: IslandActivityError) -> SystemStatusNotice {
        let title: String, detail: String
        switch problem {
        case .disabled:
            title = "上次活动请求被系统关闭"; detail = "请检查系统的实时活动设置，然后重新检查。"
        case .invalidClock:
            title = "活动时间无法确认"; detail = "请检查系统时间后重新检查；原始观察时间保持不变。"
        case .invalidContent, .contentBudgetExceeded:
            title = "活动内容暂不可提交"; detail = "已保留会话状态；请重新检查，持续出现时可提交诊断。"
        case .invalidActivityID, .invalidInventory:
            title = "系统活动清单无法确认"; detail = "未删除无法确认的系统活动，请重新检查。"
        case .inventoryFailed:
            title = "上次系统活动读取失败"; detail = "请重新检查；读取失败时不会创建重复活动。"
        case .requestFailed:
            title = "上次活动创建失败"; detail = "菜单栏与会话列表仍可使用，可重新检查。"
        case .foregroundRequired:
            title = "实时活动需要应用进入前台"; detail = "请打开会话窗口，激活潮汐岛后重新检查；会话状态已保留。"
        case .updateFailed:
            title = "上次活动更新失败"; detail = "系统中可能保留较早状态，可重新检查。"
        case .endFailed:
            title = "上次活动结束未确认"; detail = "系统中可能仍有活动，可重新检查；不会用新建活动掩盖清理失败。"
        case .busy, .schedulingFailed:
            title = "上次活动同步未完成"; detail = "请重新检查，会话状态与操作仍保留。"
        case .cancelled, .stopped:
            title = "上次活动操作已停止"; detail = "可重新检查当前状态；停止不代表会话已结束。"
        }
        return .init(id: "activity.error.\(problem.rawValue)", title: title, detail: detail, level: .attention,
                     action: problem == .foregroundRequired ? .openSessions : .checkAgain)
    }

    private static func reminderFailure(_ problem: SessionReminderProblem) -> SystemStatusNotice {
        let title: String, detail: String
        switch problem {
        case .permissionDenied, .authorizationNotRequested:
            title = "上次提醒未获系统允许"; detail = "请检查提醒与系统通知设置；允许后不补发旧提醒。"
        case .deliveryFailed:
            title = "上次提醒提交未确认"; detail = "通知可能已经提交，同一提醒不会自动重发；可在会话列表查看。"
        case .invalidClock:
            title = "提醒时间无法确认"; detail = "请检查系统时间；原始观察时间保持不变。"
        case .invalidSnapshot, .capacityExceeded:
            title = "提醒来源暂不可用"; detail = "请检查事件通道，未接受不完整或超限的状态。"
        }
        return .init(id: "reminder.error.\(problem.rawValue)", title: title, detail: detail, level: .attention,
                     action: problem == .permissionDenied || problem == .authorizationNotRequested ? .reminderSettings : .checkAgain)
    }
}
