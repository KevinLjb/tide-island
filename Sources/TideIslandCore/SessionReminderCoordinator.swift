import Foundation

/// One ordered source and one notification operation. Same-phase observations
/// within a known turn share an episode, even when their event UUIDs differ.
public actor SessionReminderCoordinator {
    public static let maximumSessions = 512
    public nonisolated let frames: AsyncStream<SessionReminderDelivery>
    private let continuation: AsyncStream<SessionReminderDelivery>.Continuation
    private let client: any SessionReminderClient
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private var sequence: UInt64?
    private var entries: [String: Entry] = [:]
    private var latest: Input?
    private var initialized = false
    private var accepting = true
    private var worker: Task<Void, Never>?
    private var submittedCount: UInt64 = 0
    private var problem: SessionReminderProblem?

    public init(client: any SessionReminderClient, now: @escaping @Sendable () -> Date = { Date() },
                calendar: @escaping @Sendable () -> Calendar = { Calendar.current }) {
        self.client = client; self.now = now; self.calendar = calendar
        let stream = AsyncStream<SessionReminderDelivery>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = stream.stream; continuation = stream.continuation
    }

    @discardableResult
    public func submit(snapshot: SessionSnapshot, sequence: UInt64, isPrimary: Bool,
                       settings: SessionReminderSettings = .init(), viewing: VerifiedSessionViewing? = nil) -> Bool {
        guard accepting, self.sequence.map({ sequence > $0 }) != false else { return false }
        self.sequence = sequence
        latest = nil // Bad/late authority must never leave an older input usable.
        do {
            let statuses = snapshot.sessions + snapshot.ignoredSessions
            guard statuses.count <= Self.maximumSessions else { throw SessionReminderProblem.capacityExceeded }
            guard Set(statuses.map(\.id)).count == statuses.count else { throw SessionReminderProblem.invalidSnapshot }
            for status in statuses {
                do {
                    try AgentEvent(version: 2, sessionID: status.id, projectName: status.session.projectName,
                                   phase: status.session.phase, occurredAt: status.session.updatedAt,
                                   context: .init(source: .manual, kind: .status, receivedAt: status.session.updatedAt)).validate()
                    guard status.freshUntil.timeIntervalSince1970.isFinite else { throw SessionReminderProblem.invalidSnapshot }
                } catch { throw SessionReminderProblem.invalidSnapshot }
            }
            latest = Input(statuses: Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) }),
                           isPrimary: isPrimary, settings: settings, viewing: viewing)
            if isPrimary {
                let baseline = !initialized
                let ids = Set(statuses.map(\.id))
                entries = entries.filter { ids.contains($0.key) }
                for status in statuses where baseline || status.sourceIssue == nil {
                    if var entry = entries[status.id], entry.phase == status.session.phase, entry.turnID == status.session.turnID {
                        if entry.outcome == .retryable { entry.outcome = .pending }
                        entries[status.id] = entry
                    } else {
                        entries[status.id] = Entry(phase: status.session.phase, turnID: status.session.turnID,
                                                  episodeID: status.reference.eventID,
                                                  outcome: baseline || SessionReminderKind(phase: status.session.phase) == nil ? .settled : .pending)
                    }
                }
                initialized = true
                if baseline || !settings.enabled { problem = nil }
            }
            if worker == nil, isPrimary {
                worker = Task { [weak self] in await self?.drain() }
            }
        } catch let error as SessionReminderProblem { problem = error }
        catch { problem = .invalidSnapshot }
        emit()
        return true
    }

    public func current() -> SessionReminderDelivery {
        .init(sourceSequence: sequence, submittedCount: submittedCount, problem: problem, stopped: !accepting)
    }

    public func flush() async { while let worker { await worker.value } }

    public func shutdown() async {
        accepting = false
        emit()
        await worker?.value
        emit()
    }

    private enum Outcome: Equatable { case pending, checking, sending, settled, retryable, uncertain }
    private struct Entry {
        let phase: AgentPhase
        let turnID: String?
        let episodeID: UUID
        var outcome: Outcome
    }
    private struct Input {
        let statuses: [String: SessionStatus]
        let isPrimary: Bool
        let settings: SessionReminderSettings
        let viewing: VerifiedSessionViewing?
    }

    private func drain() async {
        defer { worker = nil }
        while accepting, let input = latest, input.isPrimary {
            let pending = input.statuses.values.filter { entries[$0.id]?.outcome == .pending }.sorted {
                if $0.session.phase.attentionPriority != $1.session.phase.attentionPriority {
                    return $0.session.phase.attentionPriority < $1.session.phase.attentionPriority
                }
                if $0.session.updatedAt != $1.session.updatedAt { return $0.session.updatedAt > $1.session.updatedAt }
                return $0.id < $1.id
            }
            guard let status = pending.first, let entry = entries[status.id] else { return }
            do {
                guard try candidate(status.id, episode: entry.episodeID) != nil else {
                    settle(status.id, episode: entry.episodeID, outcome: .settled); continue
                }
                settle(status.id, episode: entry.episodeID, outcome: .checking)
                let authorization = await client.authorization()
                guard accepting else { return }
                // Rebuild from the newest input after permission await. A
                // resumed/ignored/read/expired or quiet session must not alert.
                guard let reminder = try candidate(status.id, episode: entry.episodeID) else {
                    let outcome: Outcome = latest?.isPrimary == true ? .settled : .pending
                    settle(status.id, episode: entry.episodeID, outcome: outcome); continue
                }
                guard authorization == .allowed else {
                    settle(status.id, episode: entry.episodeID, outcome: .retryable)
                    problem = authorization == .notRequested ? .authorizationNotRequested : .permissionDenied
                    emit(); return // A new ordered input may retry the query.
                }
                settle(status.id, episode: entry.episodeID, outcome: .sending)
                do { try await client.post(reminder) }
                catch {
                    // The OS may have accepted a post whose response was lost.
                    // Do not post again in this episode on an ordinary refresh.
                    settle(status.id, episode: entry.episodeID, outcome: .uncertain)
                    if latest != nil { problem = .deliveryFailed }
                    emit(); continue
                }
                submittedCount &+= 1
                settle(status.id, episode: entry.episodeID, outcome: .settled)
                // A completed older post cannot validate a newer malformed
                // source that arrived while the SDK call was suspended.
                if latest != nil { problem = nil }
                emit()
            } catch let error as SessionReminderProblem {
                settle(status.id, episode: entry.episodeID, outcome: .retryable)
                problem = error; emit(); return
            } catch {
                settle(status.id, episode: entry.episodeID, outcome: .settled)
                problem = .invalidSnapshot; emit(); return
            }
        }
    }

    private func candidate(_ id: String, episode: UUID) throws -> SessionReminder? {
        guard let input = latest, input.isPrimary, let status = input.statuses[id],
              entries[id]?.episodeID == episode, let kind = SessionReminderKind(phase: status.session.phase) else { return nil }
        let settings = input.settings
        guard settings.enabled, kind == .needsInput ? settings.needsInput : settings.turnEnded else { return nil }
        let time = now()
        guard time.timeIntervalSince1970.isFinite else { throw SessionReminderProblem.invalidClock }
        guard status.sourceIssue == nil, status.freshness == .fresh, !status.attention.isIgnored, status.attention.isUnread,
              status.session.updatedAt <= time, status.freshUntil > time,
              settings.quietHours?.contains(time, calendar: calendar()) != true,
              input.viewing?.matches(status, at: time) != true,
              let url = SessionLink.url(for: id) else { return nil }
        return SessionReminder(reference: status.reference, episodeID: episode, kind: kind,
                               projectName: status.session.projectName, occurredAt: status.session.updatedAt,
                               sound: settings.sound, sessionURL: url)
    }

    private func settle(_ id: String, episode: UUID, outcome: Outcome) {
        guard var entry = entries[id], entry.episodeID == episode else { return }
        entry.outcome = outcome; entries[id] = entry
    }

    private func emit() { continuation.yield(current()) }
    deinit { worker?.cancel(); continuation.finish() }
}
