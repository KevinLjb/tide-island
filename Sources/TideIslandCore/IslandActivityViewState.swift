import Foundation

/// One projection for every Activity view and its spoken description. The SDK
/// supplies isStale; this value never refreshes event clocks or changes state.
public struct IslandActivityViewState: Equatable, Sendable {
    public let projectName: String
    public let title: String
    public let symbolName: String
    public let countsText: String
    public let workingText: String?
    public let waitingText: String?
    public let compactCountText: String
    public let sessionURL: URL?
    public let isValid: Bool
    public let isStale: Bool

    public var accessibilityLabel: String { "\(projectName)，\(title)，\(countsText)" }
    public var statusAccessibilityLabel: String { "\(projectName)，\(title)" }

    public init(content: IslandActivityContent, isStale: Bool) {
        let valid: Bool
        do { try IslandActivityPresentationPolicy.standard.validate(content); valid = true }
        catch { valid = false }
        self.isValid = valid
        self.isStale = isStale
        projectName = valid ? content.projectName : "潮汐岛"
        title = !valid ? "会话状态不可用" : isStale ? "状态待确认" : content.phase.title
        symbolName = !valid ? "exclamationmark.triangle" : isStale ? "clock" : content.phase.symbolName
        sessionURL = valid ? SessionLink.url(for: content.sessionID) : nil
        if valid, !isStale {
            // Validation has already excluded negative counts and overflow.
            let total = content.workingCount + content.waitingCount
            workingText = "工作中 \(content.workingCount)"
            waitingText = "待处理 \(content.waitingCount)"
            countsText = "工作中 \(content.workingCount) · 待处理 \(content.waitingCount)"
            compactCountText = total > 99 ? "99+" : String(total)
        } else {
            workingText = nil; waitingText = nil; compactCountText = "?"
            countsText = valid ? "会话数量待确认" : "请从菜单栏打开潮汐岛"
        }
    }
}
