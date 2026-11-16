import Foundation
import Testing
@testable import TideIslandCore

@Test func eventRoundTripPreservesRoutingMetadata() throws {
    let event = AgentEvent(
        sessionID: "session-1", projectName: "tide-island", phase: .needsInput,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_000.125), waveBlockID: "wave-block-1"
    )
    #expect(try EventCodec.decode(EventCodec.encode(event)) == event)
}

@Test func unsupportedProtocolVersionIsRejected() {
    let event = AgentEvent(version: 3, sessionID: "session", projectName: "project", phase: .working)
    #expect(throws: EventError.self) { try EventCodec.encode(event) }
}

@Test func legacyV1EventsRemainReadable() throws {
    let data = Data(#"{"version":1,"id":"00000000-0000-0000-0000-000000000001","sessionID":"legacy","projectName":"project","phase":"working","occurredAt":"2026-11-16T00:00:00Z"}"#.utf8)
    let event = try EventCodec.decode(data)
    #expect(event.version == 1)
    #expect(event.phase == .working)
    #expect(event.context == nil)
    #expect(try EventCodec.decode(EventCodec.encode(event)) == event)
}

@Test func v2RequiresConsistentContextAndV1CannotContainNewPhases() throws {
    let missing = AgentEvent(version: 2, sessionID: "session", projectName: "project", phase: .working)
    #expect(throws: EventError.self) { try missing.validate() }
    for phase in [AgentPhase.interrupted, .ended] {
        let legacy = AgentEvent(sessionID: "session", projectName: "project", phase: phase)
        #expect(throws: EventError.self) { try legacy.validate() }
    }
    let inconsistent = AgentEvent(
        version: 2, sessionID: "session", projectName: "project", phase: .working,
        context: EventContext(source: .codexHook, kind: .permissionRequested, receivedAt: Date(), turnID: "turn", toolName: "Bash")
    )
    #expect(throws: EventError.self) { try inconsistent.validate() }
}

@Test func invalidSessionNamesAreRejected() {
    for sessionID in ["", "   ", "session\nspoof", String(repeating: "a", count: 257)] {
        let event = AgentEvent(sessionID: sessionID, projectName: "project", phase: .working)
        #expect(throws: EventError.self) { try event.validate() }
    }
}

@Test func codexTurnCompletionDoesNotCopyPrivateMessages() throws {
    let payload = Data("""
    {"type":"agent-turn-complete","thread-id":"thread-1","cwd":"/work/tide-island",
     "last-assistant-message":"private reply","input-messages":["private prompt"]}
    """.utf8)
    let notification = try JSONDecoder().decode(CodexNotification.self, from: payload)
    let event = try notification.event(at: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(event.sessionID == "thread-1")
    #expect(event.projectName == "tide-island")
    #expect(event.phase == .completed)
    let encoded = String(decoding: try EventCodec.encode(event), as: UTF8.self)
    #expect(!encoded.contains("private"))
}

@Test func unsupportedCodexNotificationsAreRejected() throws {
    let payload = Data(#"{"type":"unknown","thread-id":"thread-1","cwd":"/work"}"#.utf8)
    let notification = try JSONDecoder().decode(CodexNotification.self, from: payload)
    #expect(throws: EventError.self) { try notification.event() }
}

@Test func sessionLinksEncodeIDsAndRejectForeignRoutes() throws {
    let id = "thread with space&query=?"
    let url = try #require(SessionLink.url(for: id))
    #expect(SessionLink.sessionID(from: url) == id)
    for value in [
        "https://session?id=thread", "tide-island://other?id=thread",
        "tide-island://session?id=", "tide-island://session?id=a&id=b",
        "tide-island://session/path?id=a",
    ] {
        let parsedURL = try #require(URL(string: value))
        #expect(SessionLink.sessionID(from: parsedURL) == nil)
    }
}
