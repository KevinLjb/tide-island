import Foundation

public enum SessionMetadataProblem: String, Error, Equatable, Sendable {
    case sourceUnavailable, staleSelection, invalidLimit, invalidClock

    public var message: String {
        switch self {
        case .sourceUnavailable: "事件来源暂时无法确认，请重新连接后重试。"
        case .staleSelection: "会话记录已变化，请从当前列表重新选择。"
        case .invalidLimit: "无法读取这次观察记录，请重试。"
        case .invalidClock: "当前时间无法确认，请检查系统时间后重试。"
        }
    }
}

/// Only metadata needed to inspect observations. Not a provider transcript or
/// proof that every remembered event was applied to the current session.
public struct SessionEventMetadata: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let phase: AgentPhase
    public let occurredAt: Date
    public let source: EventSource?
    public let kind: EventKind?
    public let isCurrentObservation: Bool

    init(event: AgentEvent, currentEventID: UUID) {
        id = event.id; phase = event.phase; occurredAt = event.occurredAt
        source = event.context?.source; kind = event.context?.kind
        isCurrentObservation = event.id == currentEventID
    }

    public var sourceTitle: String {
        switch source {
        case .manual: "手动状态"
        case .codexHook: "Codex 生命周期"
        case .codexNotify: "Codex 本轮通知"
        case nil: "未记录来源"
        }
    }
    public var kindTitle: String {
        switch kind {
        case .status, nil: "状态观察"
        case .turnStarted: "本轮开始"
        case .toolStarted: "工具开始"
        case .toolFinished: "工具结束"
        case .permissionRequested: "等待许可"
        case .turnCompleted: "本轮结束"
        case .turnInterrupted: "本轮中断"
        case .sessionEnded: "会话退出"
        }
    }
}

public struct SessionMetadataHistory: Equatable, Sendable {
    public static let maximumResults = 20
    public let reference: SessionReference
    public let entries: [SessionEventMetadata]
    public let availableCount: Int
    /// The last receiver scan, not the time at which this query was performed.
    public let confirmedAt: Date
}
