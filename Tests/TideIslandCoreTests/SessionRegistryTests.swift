import Foundation
import Testing
@testable import TideIslandCore

@Test func lateAndDuplicateEventsDoNotRegressSessionState() throws {
    var registry = SessionRegistry()
    let completed = AgentEvent(
        sessionID: "one", projectName: "one", phase: .completed,
        occurredAt: Date(timeIntervalSince1970: 200)
    )
    let applied = try registry.apply(completed)
    #expect(applied)
    let duplicate = try registry.apply(completed)
    #expect(!duplicate)
    let older = try registry.apply(AgentEvent(
        sessionID: "one", projectName: "one", phase: .working,
        occurredAt: Date(timeIntervalSince1970: 100)
    ))
    #expect(!older)
    #expect(registry.sessions.count == 1)
    #expect(registry.sessions.first?.phase == .completed)
}

@Test func humanAttentionComesFirstAndSessionsStayIndependent() throws {
    var registry = SessionRegistry()
    for (id, phase) in [("working", AgentPhase.working), ("waiting", .needsInput), ("failed", .failed)] {
        try registry.apply(AgentEvent(sessionID: id, projectName: id, phase: phase))
    }
    #expect(registry.sessions.map(\.id) == ["waiting", "failed", "working"])
    try registry.apply(AgentEvent(sessionID: "working", projectName: "working", phase: .completed))
    #expect(registry.sessions.first?.id == "waiting")
    #expect(registry.sessions.first(where: { $0.id == "failed" })?.phase == .failed)
}
