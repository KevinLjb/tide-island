import Foundation

/// Uses the actual adapters, wire codec and registry. No current clock, Wave
/// environment, inbox, process launch, native APIs or user configuration is used.
public enum EventReplay {
    public static let maximumInputBytes = 1024 * 1024
    public static let maximumReportBytes = 4 * 1024 * 1024
    public static let maximumSteps = 256
    public static let maximumSnapshotSessions = 1024

    public static func run(_ data: Data, scenario: String? = nil) throws -> ReplayReport {
        guard data.count <= maximumInputBytes else { throw ReplayError.limitExceeded }
        let scenarios: [Scenario]
        do { scenarios = try parse(data) }
        catch let error as ReplayError { throw error }
        catch { throw ReplayError.invalidFixture }
        let selected = scenarios.filter { scenario == nil || $0.name == scenario }
        guard !selected.isEmpty else { throw ReplayError.scenarioNotFound }
        var results: [ReplayScenarioResult] = []
        var snapshotCount = 0
        for scenario in selected {
            var registry = SessionRegistry()
            var steps: [ReplayStepResult] = []
            for (index, step) in scenario.steps.enumerated() {
                let converted = convert(step)
                let disposition: ReplayDisposition
                if let event = converted.event {
                    disposition = try registry.apply(event) ? .applied : .discarded
                } else { disposition = converted.error == nil ? .filtered : .rejected }
                let sessions = registry.sessions.map(ReplaySessionSnapshot.init)
                snapshotCount += sessions.count
                guard snapshotCount <= maximumSnapshotSessions else { throw ReplayError.limitExceeded }
                var mismatches: [String] = []
                if disposition != step.expected.disposition { mismatches.append("disposition") }
                if converted.error != step.expected.errorCode { mismatches.append("errorCode") }
                if sessions != step.expected.sessions { mismatches.append("sessions") }
                steps.append(ReplayStepResult(
                    index: index + 1, eventID: step.id, receivedAt: step.at, source: step.source,
                    disposition: disposition, errorCode: converted.error, event: converted.event,
                    sessions: sessions, expected: step.expected, mismatches: mismatches
                ))
            }
            results.append(ReplayScenarioResult(
                name: scenario.name, passed: steps.allSatisfy { $0.mismatches.isEmpty }, steps: steps,
                finalSessions: steps.last?.sessions ?? []
            ))
        }
        let steps = results.flatMap(\.steps)
        return ReplayReport(
            passed: results.allSatisfy(\.passed), scenarioCount: results.count, stepCount: steps.count,
            mismatchCount: steps.reduce(0) { $0 + $1.mismatches.count }, scenarios: results
        )
    }

    public static func encode(_ report: ReplayReport) throws -> Data {
        let data = try EventCodec.jsonEncoder().encode(report)
        guard data.count <= maximumReportBytes else { throw ReplayError.limitExceeded }
        return data
    }

    private struct Scenario {
        let name: String
        let steps: [Step]
    }

    private struct Step {
        let id: UUID
        let at: Date
        let source: ReplayInputSource
        let waveBlockID: String?
        let payload: Data
        let expected: ReplayExpectation
    }

    private static func convert(_ step: Step) -> (event: AgentEvent?, error: ReplayInputError?) {
        do {
            let observed: AgentEvent
            switch step.source {
            case .hook:
                guard let event = try CodexHookAdapter.event(from: step.payload, receivedAt: step.at, waveBlockID: step.waveBlockID) else {
                    return (nil, nil)
                }
                observed = event
            case .notify:
                let notification = try JSONDecoder().decode(CodexNotification.self, from: step.payload)
                observed = try notification.event(at: step.at, waveBlockID: step.waveBlockID)
            case .event:
                observed = try EventCodec.decode(step.payload)
                guard observed.id == step.id else { return (nil, .identityMismatch) }
            }
            // The receiver normally assigns a UUID. Replay substitutes only
            // this identity; the production adapter's metadata remains intact.
            let event = AgentEvent(
                version: observed.version, id: step.id, sessionID: observed.sessionID,
                projectName: observed.projectName, phase: observed.phase, occurredAt: observed.occurredAt,
                waveBlockID: observed.waveBlockID, context: observed.context
            )
            // Model the actual writer/reader boundary before applying state.
            return (try EventCodec.decode(EventCodec.encode(event)), nil)
        } catch {
            switch step.source {
            case .hook: return (nil, .invalidHook)
            case .notify: return (nil, .invalidNotify)
            case .event: return (nil, .invalidEvent)
            }
        }
    }

    private static func parse(_ data: Data) throws -> [Scenario] {
        let root = try object(ConfigurationJSON.decode(data), allowed: ["schemaVersion", "description", "scenarios"])
        guard root["schemaVersion"] == .number("1"), let scenarios = root["scenarios"]?.array,
              !scenarios.isEmpty, scenarios.count <= 32 else { throw ReplayError.invalidFixture }
        var names: Set<String> = []
        var stepCount = 0
        var result: [Scenario] = []
        for value in scenarios {
            let fields = try object(value, allowed: ["name", "description", "steps"])
            guard let name = fields["name"]?.string,
                  name.range(of: #"\A[a-z][a-z0-9-]{0,79}\z"#, options: .regularExpression) != nil,
                  names.insert(name).inserted, let steps = fields["steps"]?.array, !steps.isEmpty else {
                throw ReplayError.invalidFixture
            }
            stepCount += steps.count
            guard stepCount <= maximumSteps else { throw ReplayError.limitExceeded }
            result.append(Scenario(name: name, steps: try steps.map(parseStep)))
        }
        return result
    }

    private static func parseStep(_ value: ConfigurationJSON) throws -> Step {
        let fields = try object(value, allowed: ["id", "at", "source", "waveBlockID", "payload", "payloadJSON", "expect"])
        guard let identity = fields["id"]?.string, let id = UUID(uuidString: identity),
              let time = fields["at"], time.string != nil,
              let sourceName = fields["source"]?.string, let source = ReplayInputSource(rawValue: sourceName),
              let expectation = fields["expect"], (fields["payload"] == nil) != (fields["payloadJSON"] == nil) else {
            throw ReplayError.invalidFixture
        }
        let at = try EventCodec.jsonDecoder().decode(Date.self, from: time.encode())
        let wave: String?
        if let value = fields["waveBlockID"] {
            guard source != .event, let text = value.string else { throw ReplayError.invalidFixture }
            wave = text
        } else { wave = nil }
        let payload: Data
        if let json = fields["payloadJSON"] {
            guard let text = json.string else { throw ReplayError.invalidFixture }
            payload = Data(text.utf8)
        } else { payload = try fields["payload"]!.encode() }
        let expectedFields = try object(expectation, allowed: ["disposition", "errorCode", "sessions"])
        guard let sessions = expectedFields["sessions"]?.array else { throw ReplayError.invalidFixture }
        for session in sessions {
            let sessionFields = try object(session, allowed: ["id", "projectName", "phase", "updatedAt", "lastEventID", "context", "waveBlockID"])
            if let context = sessionFields["context"], context != .null {
                _ = try object(context, allowed: ["source", "kind", "receivedAt", "sourceOccurredAt", "turnID", "toolName", "toolUseID"])
            }
        }
        let expected = try EventCodec.jsonDecoder().decode(ReplayExpectation.self, from: expectation.encode())
        guard Set(expected.sessions.map(\.id)).count == expected.sessions.count,
              (expected.disposition == .rejected) == (expected.errorCode != nil) else {
            throw ReplayError.invalidFixture
        }
        for session in expected.sessions { try session.validate() }
        return Step(id: id, at: at, source: source, waveBlockID: wave, payload: payload, expected: expected)
    }

    private static func object(_ value: ConfigurationJSON, allowed: Set<String>) throws -> [String: ConfigurationJSON] {
        guard let fields = value.object, Set(fields.keys).isSubset(of: allowed) else { throw ReplayError.invalidFixture }
        return fields
    }
}
