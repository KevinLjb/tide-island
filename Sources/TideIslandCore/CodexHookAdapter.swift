import Foundation

public enum CodexHookEvent: String, CaseIterable, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case interrupt = "Interrupt"
    case sessionEnd = "SessionEnd"

    var kind: EventKind {
        switch self {
        case .userPromptSubmit: .turnStarted
        case .preToolUse: .toolStarted
        case .permissionRequest: .permissionRequested
        case .postToolUse: .toolFinished
        case .interrupt: .turnInterrupted
        case .sessionEnd: .sessionEnded
        }
    }
}

public enum CodexHookAdapter {
    public static let contractCLIVersion = "0.169.0"
    public static let upstreamRevision = "d32063f96c2dff1dc96af839b3952abb6acfeda4"
    public static let maximumInputBytes = 1024 * 1024

    /// Unsupported and child-agent hooks are ignored. This adapter does not
    /// treat Stop as completion: another Stop hook can continue the turn.
    public static func event(
        from data: Data,
        receivedAt: Date = Date(),
        waveBlockID: String? = nil
    ) throws -> AgentEvent? {
        guard data.count <= maximumInputBytes else { throw EventError.oversizedHookInput }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard !header.hasAgentContext, let hook = CodexHookEvent(rawValue: header.hookEventName) else {
            return nil
        }
        let input = try decoder.decode(Input.self, from: data)
        if hook != .sessionEnd, input.turnID == nil {
            throw EventError.invalidField("turn_id")
        }
        if hook == .sessionEnd, input.reason != "other" {
            throw EventError.invalidField("reason")
        }
        let usesTool = [CodexHookEvent.preToolUse, .postToolUse, .permissionRequest].contains(hook)
        let usesToolID = [CodexHookEvent.preToolUse, .postToolUse].contains(hook)
        let kind = hook.kind
        guard let phase = kind.expectedPhase else { throw EventError.invalidField("hook_event_name") }
        let event = AgentEvent(
            version: AgentEvent.currentVersion,
            sessionID: input.sessionID,
            projectName: try projectName(from: input.cwd),
            phase: phase,
            occurredAt: receivedAt,
            waveBlockID: waveBlockID,
            context: EventContext(
                source: .codexHook, kind: kind, receivedAt: receivedAt,
                turnID: hook == .sessionEnd ? nil : input.turnID,
                toolName: usesTool ? input.toolName : nil,
                toolUseID: usesToolID ? input.toolUseID : nil
            )
        )
        try event.validate()
        return event
    }

    static func projectName(from cwd: String) throws -> String {
        guard cwd.hasPrefix("/"), cwd.utf8.count <= 4096,
              !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw EventError.invalidField("cwd") }
        let component = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.lastPathComponent
        let name = component.isEmpty || component == "/" ? "Codex" : component
        var result = ""
        for character in name {
            guard result.utf8.count + String(character).utf8.count <= 160 else { break }
            result.append(character)
        }
        return result.isEmpty ? "Codex" : result
    }

    private struct Header: Decodable {
        let hookEventName: String
        let hasAgentContext: Bool

        enum CodingKeys: String, CodingKey {
            case hookEventName = "hook_event_name"
            case agentID = "agent_id"
            case agentType = "agent_type"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hookEventName = try container.decode(String.self, forKey: .hookEventName)
            hasAgentContext = container.contains(.agentID) || container.contains(.agentType)
        }
    }

    /// Only allowlisted metadata is decoded. Prompt, tool input/output, model,
    /// transcript paths and unknown timestamps are never copied to our event.
    private struct Input: Decodable {
        let sessionID: String
        let cwd: String
        let turnID: String?
        let toolName: String?
        let toolUseID: String?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case cwd, reason
            case sessionID = "session_id"
            case turnID = "turn_id"
            case toolName = "tool_name"
            case toolUseID = "tool_use_id"
        }
    }
}
