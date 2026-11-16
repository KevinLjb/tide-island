import Foundation
import Testing
@testable import TideIslandCore

private let viewEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func activityViewWaitingTargetKeepsBothCountsAndOneSessionLink() {
    let state = viewContent(.needsInput, working: 3, waiting: 2)
    let display = IslandActivityViewState(content: state, isStale: false)
    #expect(display.isValid && display.title == AgentPhase.needsInput.title && display.symbolName == AgentPhase.needsInput.symbolName)
    #expect(display.workingText == "工作中 3" && display.waitingText == "待处理 2" && display.compactCountText == "5")
    #expect(display.countsText == "工作中 3 · 待处理 2" && display.accessibilityLabel.contains("待处理 2"))
    #expect(display.sessionURL.flatMap(SessionLink.sessionID) == state.sessionID)
}

@Test func activityViewWorkingStatusUsesCanonicalPhaseAndCompleteSpokenSummary() {
    let display = IslandActivityViewState(content: viewContent(), isStale: false)
    #expect(display.title == AgentPhase.working.title && display.symbolName == AgentPhase.working.symbolName)
    #expect(display.compactCountText == "1" && display.accessibilityLabel == "project，正在工作，工作中 1 · 待处理 0")
    #expect(display.statusAccessibilityLabel == "project，正在工作")
}

@Test func activityViewStaleProjectionHidesOldCountsAndWorkClaimsAcrossEveryLabel() {
    let content = viewContent(.needsInput, working: 70, waiting: 3)
    let fresh = IslandActivityViewState(content: content, isStale: false)
    let stale = IslandActivityViewState(content: content, isStale: true)
    #expect(stale.isValid && stale.isStale && stale.title == "状态待确认" && stale.symbolName == "clock")
    #expect(stale.workingText == nil && stale.waitingText == nil && stale.compactCountText == "?")
    #expect(stale.countsText == "会话数量待确认" && stale.accessibilityLabel == "project，状态待确认，会话数量待确认")
    #expect(stale.sessionURL == fresh.sessionURL && content.updatedAt == viewEpoch)
}

@Test func activityViewCompactCountsAreBoundedWithoutAbbreviatingAccessibleCounts() {
    for total in [1, 99, 100, 1_000_000, Int.max] {
        let display = IslandActivityViewState(content: viewContent(working: total), isStale: false)
        #expect(display.isValid && display.compactCountText == (total > 99 ? "99+" : String(total)))
        #expect(display.countsText == "工作中 \(total) · 待处理 0")
        #expect(display.accessibilityLabel.contains(String(total)))
    }
}

@Test func activityViewRejectsInvalidConstructedContentWithoutEchoingItOrOfferingALink() {
    let invalid: [IslandActivityContent] = [
        viewContent(working: -1), viewContent(working: 0), viewContent(.completed),
        viewContent(working: Int.max, waiting: 1), viewContent(id: "bad\nID"),
        viewContent(project: "private-invalid\nproject"), viewContent(at: Date(timeIntervalSince1970: .nan)),
    ]
    for content in invalid {
        for stale in [false, true] {
            let display = IslandActivityViewState(content: content, isStale: stale)
            #expect(!display.isValid && display.sessionURL == nil && display.projectName == "潮汐岛")
            #expect(display.title == "会话状态不可用" && display.symbolName == "exclamationmark.triangle")
            #expect(display.workingText == nil && display.waitingText == nil && display.compactCountText == "?")
            #expect(!display.accessibilityLabel.contains("private-invalid"))
        }
    }
}

@Test func activityViewPreservesFullUnicodeNamesAndIdentityWhenOnlyTheLayoutTruncates() {
    let project = String(repeating: "潮", count: 53), id = "会话 / ? & = 🐚"
    let display = IslandActivityViewState(content: viewContent(id: id, project: project), isStale: false)
    #expect(display.projectName == project && display.accessibilityLabel.hasPrefix(project))
    #expect(display.sessionURL.flatMap(SessionLink.sessionID) == id)
}

@Test func activityViewLinkTargetsTheHighlightedSessionRatherThanTheProjectNameOrCount() {
    let first = IslandActivityViewState(content: viewContent(id: "first", project: "same", working: 2), isStale: false)
    let second = IslandActivityViewState(content: viewContent(.needsInput, id: "second", project: "same", working: 2, waiting: 1), isStale: false)
    #expect(first.projectName == second.projectName && first.sessionURL != second.sessionURL)
    #expect(first.sessionURL.flatMap(SessionLink.sessionID) == "first")
    #expect(second.sessionURL.flatMap(SessionLink.sessionID) == "second")
}

@Test func activityViewChangingOnlyTheStaleFlagCanRecoverWithoutMutatingWireContent() throws {
    let content = viewContent(.needsInput, working: 1, waiting: 1)
    let before = try EventCodec.jsonEncoder().encode(content)
    let stale = IslandActivityViewState(content: content, isStale: true)
    let fresh = IslandActivityViewState(content: content, isStale: false)
    let after = try EventCodec.jsonEncoder().encode(content)
    #expect(stale.sessionURL == fresh.sessionURL && before == after)
    #expect(fresh.title == AgentPhase.needsInput.title && fresh.compactCountText == "2")
}

private func viewContent(_ phase: AgentPhase = .working, id: String = "session", project: String = "project",
                         working: Int = 1, waiting: Int = 0, at: Date = viewEpoch) -> IslandActivityContent {
    IslandActivityContent(sessionID: id, projectName: project, phase: phase,
                          workingCount: working, waitingCount: waiting, updatedAt: at)
}
