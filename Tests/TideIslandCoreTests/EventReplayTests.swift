import Foundation
import Testing
@testable import TideIslandCore

@Test func lifecycleReplayChecksAllGoldenStatesAndProducesIdenticalBytes() throws {
    let data = try replayFixture("lifecycle")
    let first = try EventReplay.run(data)
    let second = try EventReplay.run(data)
    #expect(first.passed)
    #expect(first.scenarioCount == 24)
    #expect(first.stepCount == 116)
    #expect(first.mismatchCount == 0)
    #expect(first == second)
    #expect(try EventReplay.encode(first) == EventReplay.encode(second))
    let encoded = String(decoding: try EventReplay.encode(first), as: UTF8.self)
    for privateValue in ["fixture-private", "/fixture/projects", "fixture-model", "transcript_path", "tool_response"] {
        #expect(!encoded.contains(privateValue))
    }
}

@Test func selectingAReplayScenarioKeepsItsStandaloneStateAndTrace() throws {
    let data = try replayFixture("lifecycle")
    let full = try EventReplay.run(data)
    let selected = try EventReplay.run(data, scenario: "permission-wait-resume")
    #expect(selected.passed)
    #expect(selected.scenarioCount == 1)
    #expect(selected.scenarios.first == full.scenarios.first(where: { $0.name == "permission-wait-resume" }))
    #expect(throws: ReplayError.self) { try EventReplay.run(data, scenario: "missing-scenario") }
}

@Test func expectedInputRejectionsRemainVisibleAndCanRecover() throws {
    let report = try EventReplay.run(replayFixture("lifecycle"), scenario: "rejected-input-recovery")
    #expect(report.passed)
    let steps = try #require(report.scenarios.first?.steps)
    #expect(steps.filter { $0.disposition == .rejected }.count == 5)
    #expect(steps.filter { $0.disposition == .rejected }.allSatisfy { $0.event == nil && $0.errorCode != nil })
    #expect(steps.last?.sessions.first?.phase == .completed)
}

@Test func incorrectExpectationsProduceActionableMismatches() throws {
    var book = try replayFixtureObject()
    var scenarios = try #require(book["scenarios"] as? [[String: Any]])
    var steps = try #require(scenarios[0]["steps"] as? [[String: Any]])
    steps[0]["expect"] = ["disposition": "discarded", "sessions": []]
    scenarios[0]["steps"] = steps
    book["scenarios"] = scenarios
    let report = try EventReplay.run(JSONSerialization.data(withJSONObject: book), scenario: "normal-turn")
    #expect(!report.passed)
    #expect(report.mismatchCount == 2)
    #expect(report.scenarios.first?.steps.first?.mismatches == ["disposition", "sessions"])
    #expect(report.scenarios.first?.steps.first?.event?.phase == .working)
}

@Test func replayDeliversDeclaredOrderWithoutSortingTimestamps() throws {
    var book = try replayFixtureObject()
    var scenarios = try #require(book["scenarios"] as? [[String: Any]])
    var steps = try #require(scenarios[0]["steps"] as? [[String: Any]])
    steps[0]["at"] = "2026-11-16T00:00:10.000Z"
    steps[1]["at"] = "2026-11-16T00:00:00.000Z"
    let ids = try steps.map { step in
        let text = try #require(step["id"] as? String)
        return try #require(UUID(uuidString: text))
    }
    scenarios[0]["steps"] = steps
    book["scenarios"] = scenarios
    let report = try EventReplay.run(JSONSerialization.data(withJSONObject: book), scenario: "normal-turn")
    #expect(report.scenarios.first?.steps.map(\.eventID) == ids)
}

@Test func missingClocksIdentitiesAssertionsAndUnknownFieldsAreDefinitionErrors() throws {
    let original = try replayFixtureObject()
    for field in ["id", "at", "expect", "source", "payload"] {
        var book = original
        var scenarios = try #require(book["scenarios"] as? [[String: Any]])
        var steps = try #require(scenarios[0]["steps"] as? [[String: Any]])
        steps[0].removeValue(forKey: field)
        scenarios[0]["steps"] = steps
        book["scenarios"] = scenarios
        #expect(throws: ReplayError.self) { try EventReplay.run(JSONSerialization.data(withJSONObject: book)) }
    }
    for addition in [["paylod": "fixture-private"], ["payloadJSON": "{}"], ["at": "not-a-clock"], ["source": "other"]] {
        var book = original
        var scenarios = try #require(book["scenarios"] as? [[String: Any]])
        var steps = try #require(scenarios[0]["steps"] as? [[String: Any]])
        for (key, value) in addition { steps[0][key] = value }
        scenarios[0]["steps"] = steps
        book["scenarios"] = scenarios
        #expect(throws: ReplayError.self) { try EventReplay.run(JSONSerialization.data(withJSONObject: book)) }
    }
    for text in ["{}", "[]", #"{"schemaVersion":1,"scenarios":[]}"#,
                 #"{"schemaVersion":1,"schemaVersion":1,"scenarios":[]}"#] {
        #expect(throws: ReplayError.self) { try EventReplay.run(Data(text.utf8)) }
    }
}

@Test func replayRejectsDuplicateScenariosAndExcessiveStepOrSnapshotCounts() throws {
    var book = try replayFixtureObject()
    let scenarios = try #require(book["scenarios"] as? [[String: Any]])
    book["scenarios"] = [scenarios[0], scenarios[0]]
    #expect(throws: ReplayError.self) { try EventReplay.run(JSONSerialization.data(withJSONObject: book)) }
    let first = try #require((scenarios[0]["steps"] as? [[String: Any]])?.first)
    book["scenarios"] = [["name": "too-many-steps", "steps": Array(repeating: first, count: EventReplay.maximumSteps + 1)]]
    #expect(throws: ReplayError.self) { try EventReplay.run(JSONSerialization.data(withJSONObject: book)) }

    var growing: [[String: Any]] = []
    for index in 0..<64 {
        var step = first
        var payload = try #require(step["payload"] as? [String: Any])
        payload["session_id"] = "session-\(index)"
        step["payload"] = payload
        step["id"] = String(format: "00000000-0000-0000-0000-%012d", index)
        growing.append(step)
    }
    book["scenarios"] = [["name": "too-many-snapshots", "steps": growing]]
    #expect(throws: ReplayError.self) { try EventReplay.run(JSONSerialization.data(withJSONObject: book)) }
    #expect(throws: ReplayError.self) { try EventReplay.run(Data(repeating: 0x20, count: EventReplay.maximumInputBytes + 1)) }
}

@Test func allFixtureDefinitionsAreValidatedBeforeScenarioSelection() throws {
    var book = try replayFixtureObject()
    var scenarios = try #require(book["scenarios"] as? [[String: Any]])
    scenarios[1]["steps"] = [["payloadJSON": "fixture-private"]]
    book["scenarios"] = scenarios
    #expect(throws: ReplayError.self) {
        try EventReplay.run(JSONSerialization.data(withJSONObject: book), scenario: "normal-turn")
    }
}

private func replayFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Replay"))
    return try Data(contentsOf: url)
}

private func replayFixtureObject() throws -> [String: Any] {
    let data = try replayFixture("lifecycle")
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}
