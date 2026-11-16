import Foundation
import Testing
@testable import TideIslandCore

@Test func eventsWithinTheSameSecondKeepTheirChronologicalOrder() throws {
    let root = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.temporaryDirectory
    let directory = root.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = EventInbox(directory: directory)
    // Deliberately write the later event first to exercise timestamp ordering.
    for (time, phase) in [(200.875, AgentPhase.completed), (200.125, .working)] {
        try inbox.write(AgentEvent(
            sessionID: "one", projectName: "one", phase: phase,
            occurredAt: Date(timeIntervalSince1970: time)
        ))
    }
    var registry = SessionRegistry()
    for event in try inbox.readRecent().events { try registry.apply(event) }
    #expect(registry.sessions.first?.phase == .completed)
}

@Test func inboxHandlesIndependentWritersAndReportsCorruptEvents() throws {
    let root = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.temporaryDirectory
    let directory = root.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = EventInbox(directory: directory)
    for id in ["first", "second"] {
        try inbox.write(AgentEvent(sessionID: id, projectName: id, phase: .working))
    }
    try Data("not-json".utf8).write(to: directory.appendingPathComponent(UUID().uuidString + ".json"))
    // Non-event files and symlinks are never read as inbox events.
    try Data("unrelated".utf8).write(to: directory.appendingPathComponent("notes.json"))
    let link = directory.appendingPathComponent(UUID().uuidString + ".json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("notes.json"))
    let batch = try inbox.readRecent()
    #expect(Set(batch.events.map(\.sessionID)) == ["first", "second"])
    #expect(batch.rejectedFiles == 1)
    #expect(try inbox.readRecent(limit: 0).events.isEmpty)
}
