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

@Test func equalTimestampStartsUsePublicationOrderWithAStableFinalFallback() throws {
    let root = ProcessInfo.processInfo.environment["TIDE_ISLAND_TEST_TMPDIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.temporaryDirectory
    let directory = root.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = EventInbox(directory: directory)
    let date = Date(timeIntervalSince1970: 500)
    let high = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
    let low = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    var paths: [URL] = []
    for (id, turn, publishedAt) in [(high, "z-old", 1.0), (low, "a-new", 2.0)] {
        let event = AgentEvent(version: 2, id: id, sessionID: "same-session", projectName: "project", phase: .working,
                               occurredAt: date, context: EventContext(source: .codexHook, kind: .turnStarted,
                                                                       receivedAt: date, turnID: turn))
        let path = try inbox.write(event)
        paths.append(path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: publishedAt)], ofItemAtPath: path.path)
    }
    let first = try inbox.readRecent().events
    #expect(first.map(\.id) == [high, low])
    var registry = SessionRegistry()
    for event in first { try registry.apply(event) }
    #expect(registry.sessions.first?.turnID == "a-new")
    for path in paths {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: path.path)
    }
    let tied = try inbox.readRecent().events
    #expect(tied.map(\.id) == [low, high])
    #expect(try inbox.readRecent().events == tied)
}
