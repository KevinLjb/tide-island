import Foundation

public struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let projectName: String
    public let phase: AgentPhase
    public let updatedAt: Date
    public let waveBlockID: String?
    public let waveLocation: WaveLocation?
    public let lastEventID: UUID
    public let context: EventContext?

    /// SessionEnd has no turn in its payload. Keep the tracked turn separate
    /// from the latest observation's context without altering that observation.
    public let turnID: String?

    init(event: AgentEvent, turnID: String? = nil) {
        id = event.sessionID
        projectName = event.projectName
        phase = event.phase
        updatedAt = event.occurredAt
        waveBlockID = event.waveBlockID
        waveLocation = event.waveLocation
        lastEventID = event.id
        context = event.context
        self.turnID = turnID ?? event.context?.turnID
    }
}

public enum SessionEventDecision: String, Codable, Sendable {
    case applied
    case duplicateEvent = "duplicate-event"
    case olderEvent = "older-event"
    case retiredTurn = "retired-turn"
    case unknownTurn = "unknown-turn"
    case missingTurn = "missing-turn"
    case terminalTurn = "terminal-turn"
    case outdatedTool = "outdated-tool"
    case waitingForInput = "waiting-for-input"
    case timestampTie = "timestamp-tie"
    case sessionEnded = "session-ended"
    case turnAlreadyStarted = "turn-already-started"
}

public struct SessionRegistry: Sendable {
    public static let eventHistoryLimit = 512
    public static let retiredTurnLimit = 64
    public static let toolHistoryLimit = 256
    public static let pendingEventLimit = 64

    private var storage: [String: SessionState] = [:]

    public init() {}

    struct PersistedState: Codable {
        fileprivate let storage: [String: SessionState]

        func validateLegacyLocations() throws {
            guard storage.values.allSatisfy({ !$0.hasWaveLocation }) else { throw SessionStateError.invalidData }
        }
    }

    func persistedState() -> PersistedState { PersistedState(storage: storage) }

    init(persisted: PersistedState) throws {
        guard persisted.storage.count <= SessionCheckpointCodec.maximumSessions else { throw SessionStateError.limitExceeded }
        for (id, state) in persisted.storage {
            guard id == state.session.id else { throw SessionStateError.invalidData }
            try state.validateCheckpoint()
        }
        storage = persisted.storage
    }

    public var sessions: [AgentSession] {
        storage.values.map(\.session).sorted {
            if $0.phase.attentionPriority != $1.phase.attentionPriority {
                return $0.phase.attentionPriority < $1.phase.attentionPriority
            }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    /// Read-only membership, including ignored observations. This is the
    /// existing bounded dedup window, not an applied-event or arrival log.
    func metadataEventIDs(for reference: SessionReference) -> Set<UUID>? {
        guard let state = storage[reference.sessionID], state.session.lastEventID == reference.eventID else { return nil }
        return Set(state.seen.orderedValues).union([state.session.lastEventID])
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent) throws -> Bool {
        try applyResult(event) == .applied
    }

    /// Ignored events can update bounded history, but never the visible session.
    @discardableResult
    public mutating func applyResult(_ event: AgentEvent) throws -> SessionEventDecision {
        try event.validate()
        guard var state = storage[event.sessionID] else {
            storage[event.sessionID] = SessionState(event)
            return .applied
        }
        guard !state.seen.contains(event.id) else { return .duplicateEvent }
        state.seen.insert(event.id)
        let decision = state.receive(event)
        storage[event.sessionID] = state
        return decision
    }
}

private struct SessionState: Codable, Sendable {
    var session: AgentSession
    var seen = BoundedHistory<UUID>(capacity: SessionRegistry.eventHistoryLimit)
    var retired = BoundedHistory<String>(capacity: SessionRegistry.retiredTurnLimit)
    var toolIDs = BoundedHistory<String>(capacity: SessionRegistry.toolHistoryLimit)
    private var tools: [String: ToolState] = [:]
    var turnAnchor: Date?
    var sawStart: Bool
    private var waitingToolIDs: Set<String>? = nil
    private var pending: [AgentEvent] = []

    init(_ event: AgentEvent) {
        session = AgentSession(event: event)
        turnAnchor = event.context?.turnID == nil ? nil : event.occurredAt
        sawStart = Self.isStart(event)
        seen.insert(event.id)
        _ = recordTool(event)
        updateWaiting(event)
    }

    mutating func receive(_ event: AgentEvent) -> SessionEventDecision {
        let turn = event.context?.turnID
        let starts = Self.isStart(event)
        if event.context?.kind == .sessionEnded {
            guard event.occurredAt >= session.updatedAt else { return .olderEvent }
            guard session.phase != .ended else { return .sessionEnded }
            return accept(event)
        }
        if session.phase == .ended {
            let manualRestart = session.turnID == nil && turn == nil && starts
            guard starts, turn != session.turnID || manualRestart else { return .sessionEnded }
            guard event.occurredAt >= session.updatedAt else { return .olderEvent }
            guard turn.map({ !retired.contains($0) }) != false else { return .retiredTurn }
            return begin(event)
        }
        if let currentTurn = session.turnID {
            guard let turn else { return .missingTurn }
            if turn != currentTurn {
                guard !retired.contains(turn) else { return .retiredTurn }
                guard starts else {
                    if pending.count == SessionRegistry.pendingEventLimit { pending.removeFirst() }
                    pending.append(event)
                    return .unknownTurn
                }
                // A delayed old-turn tool result must not make a newer start
                // look old: compare starts with the turn boundary, not activity.
                guard event.occurredAt >= (turnAnchor ?? session.updatedAt) else { return .olderEvent }
                return begin(event)
            }
            turnAnchor = min(turnAnchor ?? event.occurredAt, event.occurredAt)
            if event.context?.kind == .turnStarted {
                if !sawStart {
                    sawStart = true
                    turnAnchor = min(turnAnchor ?? event.occurredAt, event.occurredAt)
                }
                return .turnAlreadyStarted
            }
            if let decision = recordTool(event) { return decision }
            let terminal = Self.terminalRank(event.phase)
            let currentTerminal = Self.terminalRank(session.phase)
            if currentTerminal > 0 {
                guard terminal > currentTerminal else { return .terminalTurn }
                return accept(event)
            }
            // A scoped terminal observation dominates working tools even if
            // its file arrived late or its receiver clock is earlier.
            if terminal > 0 { return accept(event) }
            if event.occurredAt < session.updatedAt {
                let finishesVisibleTool = event.context?.kind == .toolFinished
                    && session.context?.kind == .toolStarted
                    && event.context?.toolUseID == session.context?.toolUseID
                guard finishesVisibleTool else { return .olderEvent }
                return accept(event)
            }
            if session.phase == .needsInput, event.phase == .working,
               event.context?.source != .manual {
                guard event.context?.kind == .toolFinished,
                      session.context?.kind == .permissionRequested,
                      event.context?.toolName == session.context?.toolName else { return .waitingForInput }
                if var remaining = waitingToolIDs, let id = event.context?.toolUseID {
                    remaining.remove(id)
                    waitingToolIDs = remaining
                    guard remaining.isEmpty else { return .waitingForInput }
                }
            }
            return acceptOrdered(event)
        }
        // An unscoped legacy session can be bootstrapped by any identified
        // observation. Once identified, unscoped updates no longer replace it.
        if turn != nil {
            guard event.occurredAt >= session.updatedAt else { return .olderEvent }
            return begin(event)
        }
        return acceptOrdered(event)
    }

    private mutating func begin(_ event: AgentEvent) -> SessionEventDecision {
        if let previous = session.turnID { retired.insert(previous) }
        tools.removeAll(keepingCapacity: true)
        toolIDs = BoundedHistory(capacity: SessionRegistry.toolHistoryLimit)
        turnAnchor = event.context?.turnID == nil ? nil : event.occurredAt
        sawStart = Self.isStart(event)
        waitingToolIDs = nil
        _ = recordTool(event)
        session = AgentSession(event: event)
        updateWaiting(event)
        // Completion/tool observations can precede their start's publication.
        // Bind only this turn after an explicit boundary; do not lose evidence
        // merely because its UUID was recorded while it was still unbound.
        let deferred = pending.filter { $0.context?.turnID == event.context?.turnID }
        pending.removeAll { $0.context?.turnID == event.context?.turnID }
        for observation in deferred { _ = receive(observation) }
        return .applied
    }

    private mutating func accept(_ event: AgentEvent) -> SessionEventDecision {
        session = AgentSession(event: event, turnID: session.turnID)
        updateWaiting(event)
        return .applied
    }

    private mutating func updateWaiting(_ event: AgentEvent) {
        guard event.context?.kind == .permissionRequested, let name = event.context?.toolName else {
            waitingToolIDs = nil
            return
        }
        let candidates = Set(tools.filter { $0.value.name == name && !$0.value.finished }.map(\.key))
        waitingToolIDs = candidates.isEmpty ? nil : candidates
    }

    private mutating func acceptOrdered(_ event: AgentEvent) -> SessionEventDecision {
        guard event.occurredAt >= session.updatedAt else { return .olderEvent }
        if event.occurredAt == session.updatedAt {
            let incoming = Self.priority(event.phase, event.context?.kind)
            let existing = Self.priority(session.phase, session.context?.kind)
            guard incoming > existing || (incoming == existing && event.id.uuidString > session.lastEventID.uuidString) else {
                return .timestampTie
            }
        }
        return accept(event)
    }

    private mutating func recordTool(_ event: AgentEvent) -> SessionEventDecision? {
        guard let context = event.context, let id = context.toolUseID, let name = context.toolName,
              context.kind == .toolStarted || context.kind == .toolFinished else { return nil }
        if let existing = tools[id] {
            guard existing.name == name, !existing.finished, context.kind == .toolFinished else { return .outdatedTool }
        }
        if let evicted = toolIDs.insert(id) { tools.removeValue(forKey: evicted) }
        tools[id] = ToolState(name: name, finished: context.kind == .toolFinished)
        return nil
    }

    private static func isStart(_ event: AgentEvent) -> Bool {
        event.context?.kind == .turnStarted
            || (event.context?.source == .manual && event.context?.kind == .status && event.phase == .working)
    }

    private static func terminalRank(_ phase: AgentPhase) -> Int {
        switch phase {
        case .working, .needsInput: 0
        case .completed: 1
        case .interrupted: 2
        case .failed: 3
        case .ended: 4
        }
    }

    private static func priority(_ phase: AgentPhase, _ kind: EventKind?) -> Int {
        if terminalRank(phase) > 0 { return 3 + terminalRank(phase) }
        if phase == .needsInput { return 3 }
        if kind == .turnStarted { return 0 }
        if kind == .toolFinished { return 2 }
        return 1
    }

    private struct ToolState: Codable, Sendable {
        let name: String
        let finished: Bool
    }
}

extension SessionState {
    var hasWaveLocation: Bool {
        session.waveLocation != nil || pending.contains { $0.waveLocation != nil }
    }

    enum CodingKeys: String, CodingKey {
        case session, seen, retired, toolIDs, tools, turnAnchor, sawStart, waitingToolIDs, pending
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        session = try values.decode(AgentSession.self, forKey: .session)
        seen = try values.decode(BoundedHistory<UUID>.self, forKey: .seen)
        retired = try values.decode(BoundedHistory<String>.self, forKey: .retired)
        toolIDs = try values.decode(BoundedHistory<String>.self, forKey: .toolIDs)
        tools = try values.decode([String: ToolState].self, forKey: .tools)
        turnAnchor = try values.decodeIfPresent(Date.self, forKey: .turnAnchor)
        sawStart = try values.decode(Bool.self, forKey: .sawStart)
        let waiting = try values.decodeIfPresent([String].self, forKey: .waitingToolIDs)
        guard waiting.map({ Set($0).count == $0.count }) != false else { throw SessionStateError.invalidData }
        waitingToolIDs = waiting.map(Set.init)
        pending = try values.decode([AgentEvent].self, forKey: .pending)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(session, forKey: .session)
        try values.encode(seen, forKey: .seen)
        try values.encode(retired, forKey: .retired)
        try values.encode(toolIDs, forKey: .toolIDs)
        try values.encode(tools, forKey: .tools)
        try values.encodeIfPresent(turnAnchor, forKey: .turnAnchor)
        try values.encode(sawStart, forKey: .sawStart)
        try values.encodeIfPresent(waitingToolIDs?.sorted(), forKey: .waitingToolIDs)
        try values.encode(pending, forKey: .pending)
    }

    func validateCheckpoint() throws {
        let observation = AgentEvent(version: session.context == nil ? 1 : 2, id: session.lastEventID,
                                     sessionID: session.id, projectName: session.projectName, phase: session.phase,
                                     occurredAt: session.updatedAt, waveBlockID: session.waveBlockID,
                                     waveLocation: session.waveLocation, context: session.context)
        try observation.validate()
        guard seen.capacity == SessionRegistry.eventHistoryLimit,
              retired.capacity == SessionRegistry.retiredTurnLimit,
              toolIDs.capacity == SessionRegistry.toolHistoryLimit,
              pending.count <= SessionRegistry.pendingEventLimit,
              tools.count <= SessionRegistry.toolHistoryLimit,
              (waitingToolIDs?.count ?? 0) <= SessionRegistry.toolHistoryLimit,
              turnAnchor?.timeIntervalSince1970.isFinite != false,
              Set(toolIDs.orderedValues) == Set(tools.keys) else { throw SessionStateError.invalidData }
        if session.turnID != session.context?.turnID {
            guard session.context?.kind == .sessionEnded else { throw SessionStateError.invalidData }
        }
        if let turn = session.turnID { try SessionCheckpointCodec.validateIdentifier(turn) }
        for turn in retired.orderedValues { try SessionCheckpointCodec.validateIdentifier(turn) }
        for (id, tool) in tools {
            try SessionCheckpointCodec.validateIdentifier(id)
            try SessionCheckpointCodec.validateIdentifier(tool.name)
        }
        for id in waitingToolIDs ?? [] { try SessionCheckpointCodec.validateIdentifier(id) }
        for event in pending {
            try event.validate()
            guard event.sessionID == session.id else { throw SessionStateError.invalidData }
        }
    }
}

/// FIFO eviction is deterministic and does not depend on wall-clock time.
private struct BoundedHistory<Key: Hashable & Codable & Sendable>: Codable, Sendable {
    let capacity: Int
    private var values: Set<Key> = []
    private var slots: [Key] = []
    private var next = 0

    init(capacity: Int) { self.capacity = capacity }

    var orderedValues: [Key] { slots }

    private enum CodingKeys: String, CodingKey { case capacity, slots, next }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capacity = try container.decode(Int.self, forKey: .capacity)
        slots = try container.decode([Key].self, forKey: .slots)
        next = try container.decode(Int.self, forKey: .next)
        guard capacity > 0, capacity <= SessionRegistry.eventHistoryLimit, slots.count <= capacity,
              Set(slots).count == slots.count, next >= 0, next < capacity,
              slots.count == capacity || next == 0 else { throw SessionStateError.invalidData }
        values = Set(slots)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capacity, forKey: .capacity)
        try container.encode(slots, forKey: .slots)
        try container.encode(next, forKey: .next)
    }

    func contains(_ key: Key) -> Bool { values.contains(key) }

    @discardableResult
    mutating func insert(_ key: Key) -> Key? {
        guard values.insert(key).inserted else { return nil }
        guard slots.count == capacity else { slots.append(key); return nil }
        let evicted = slots[next]
        values.remove(evicted)
        slots[next] = key
        next = (next + 1) % capacity
        return evicted
    }
}
