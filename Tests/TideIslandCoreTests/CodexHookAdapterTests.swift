import Foundation
import Testing
@testable import TideIslandCore

@Test func codexHookFixturesMapOnlyAllowlistedMetadata() throws {
    let receivedAt = Date(timeIntervalSince1970: 1_800_000_000.125)
    var forwarded = 0
    for fixture in try codexHookFixtures() {
        let payload = try #require(fixture["payload"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try CodexHookAdapter.event(from: data, receivedAt: receivedAt, waveBlockID: "wave-block")
        guard let expectedKind = fixture["kind"] as? String else {
            #expect(event == nil)
            continue
        }
        forwarded += 1
        let observed = try #require(event)
        #expect(observed.version == 2)
        #expect(observed.phase.rawValue == fixture["phase"] as? String)
        #expect(observed.context?.kind.rawValue == expectedKind)
        #expect(observed.context?.source == .codexHook)
        #expect(observed.context?.receivedAt == receivedAt)
        #expect(observed.context?.sourceOccurredAt == nil)
        #expect(observed.occurredAt == receivedAt)
        #expect(observed.projectName == "tide-island")
        #expect(observed.waveBlockID == "wave-block")
        #expect(try EventCodec.decode(EventCodec.encode(observed)) == observed)
        let encoded = String(decoding: try EventCodec.encode(observed), as: UTF8.self)
        #expect(!encoded.contains("fixture-private"))
        #expect(!encoded.contains("/fixture/projects"))
        #expect(!encoded.contains("fixture-model"))
    }
    #expect(forwarded == 6)
}

@Test func failedToolResultRestoresWorkingWithoutClaimingTurnFailure() throws {
    let payload = try codexFixturePayload(named: "tool-failure-keeps-turn-working")
    let data = try JSONSerialization.data(withJSONObject: payload)
    let event = try #require(CodexHookAdapter.event(from: data))
    #expect(event.phase == .working)
    #expect(event.context?.kind == .toolFinished)
    #expect(event.context?.toolName == "Bash")
    #expect(event.context?.toolUseID == "fixture-tool")
}

@Test func unknownEventsAndAgentMarkersAreIgnoredBeforeOtherFields() throws {
    for value in [
        #"{"hook_event_name":"FutureEvent","private":"fixture-private"}"#,
        #"{"hook_event_name":"SubagentStop","private":"fixture-private"}"#,
        #"{"hook_event_name":"PreToolUse","agent_id":null}"#,
        #"{"hook_event_name":"PreToolUse","agent_type":"custom"}"#,
        #"{"hook_event_name":"SessionStart","source":"resume"}"#,
    ] {
        #expect(try CodexHookAdapter.event(from: Data(value.utf8)) == nil)
    }
}

@Test func requiredTurnAndToolIdentityCannotBeInvented() throws {
    let original = try codexFixturePayload(named: "tool-start")
    for field in ["session_id", "turn_id", "tool_name", "tool_use_id", "cwd"] {
        var payload = original
        payload.removeValue(forKey: field)
        let data = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: (any Error).self) { try CodexHookAdapter.event(from: data) }
    }
    var relative = original
    relative["cwd"] = "relative/project"
    #expect(throws: EventError.self) {
        try CodexHookAdapter.event(from: JSONSerialization.data(withJSONObject: relative))
    }
}

@Test func unknownSourceTimestampIsNotPromotedToAuthoritativeTime() throws {
    var payload = try codexFixturePayload(named: "turn-start")
    payload["timestamp"] = "1999-01-01T00:00:00Z"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let event = try #require(CodexHookAdapter.event(
        from: JSONSerialization.data(withJSONObject: payload), receivedAt: now
    ))
    #expect(event.occurredAt == now)
    #expect(event.context?.sourceOccurredAt == nil)
}

@Test func oversizedHookInputsAreRejectedBeforeParsing() {
    let data = Data(repeating: 0x20, count: CodexHookAdapter.maximumInputBytes + 1)
    #expect(throws: EventError.self) { try CodexHookAdapter.event(from: data) }
}

@Test func registryRetainsSourceAndTurnMetadata() throws {
    let payload = try codexFixturePayload(named: "turn-start")
    let data = try JSONSerialization.data(withJSONObject: payload)
    let event = try #require(CodexHookAdapter.event(from: data))
    var registry = SessionRegistry()
    try registry.apply(event)
    #expect(registry.sessions.first?.turnID == "fixture-turn")
    #expect(registry.sessions.first?.context?.source == .codexHook)
}

@Test func questionToolNamesDoNotInventAConfirmedWaitingState() throws {
    for name in ["request_user_input", "request_user_input_async"] {
        var payload = try codexFixturePayload(named: "tool-start")
        payload["tool_name"] = name
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try #require(CodexHookAdapter.event(from: data))
        #expect(event.phase == .working)
        #expect(event.context?.kind == .toolStarted)
    }
}

@Test func notifySupportsTurnIdentityWithoutRequiringItFromOlderPayloads() throws {
    let data = Data(#"{"type":"agent-turn-complete","thread-id":"thread","turn-id":"turn","cwd":"/projects/tide-island","last-assistant-message":"fixture-private"}"#.utf8)
    let notification = try JSONDecoder().decode(CodexNotification.self, from: data)
    let event = try notification.event()
    #expect(event.version == 2)
    #expect(event.context?.source == .codexNotify)
    #expect(event.context?.kind == .turnCompleted)
    #expect(event.context?.turnID == "turn")
    #expect(event.context?.sourceOccurredAt == nil)
}
