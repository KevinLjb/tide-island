import Foundation

public enum IslandActivityDeliveryPhase: String, Sendable {
    case idle, scheduled, updating, synchronized, failed, stopping, stopped
}

/// Client acknowledgement metadata, not proof of visible system presentation.
public struct IslandActivityDelivery: Equatable, Sendable {
    public let sourceSequence: UInt64?
    public let synchronizedSequence: UInt64?
    public let phase: IslandActivityDeliveryPhase
    public let problem: IslandActivityError?
}

/// One ordered source stream, one latest pending snapshot, one SDK operation.
/// Sequence numbers belong to the source, so delayed caller tasks cannot make
/// an older snapshot win merely by reaching this actor later.
public actor IslandActivityScheduler {
    public static let minimumUpdateInterval: TimeInterval = 1
    public nonisolated let frames: AsyncStream<IslandActivityDelivery>

    private let continuation: AsyncStream<IslandActivityDelivery>.Continuation
    private let controller: IslandActivityController
    private let policy = IslandActivityPresentationPolicy.standard
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var sourceSequence: UInt64?
    private var synchronizedSequence: UInt64?
    private var phase: IslandActivityDeliveryPhase = .idle
    private var problem: IslandActivityError?
    private var pending: Pending?
    private var worker: Task<Void, Never>?
    private var delayTask: Task<Void, any Error>?
    private var hasSynchronized = false
    private var lastPresentation: IslandActivityPresentation?
    private var lastAttemptPresentation: IslandActivityPresentation?
    private var lastAttemptAt: TimeInterval?
    private var sourceScope: IslandActivityScope = .ownedOnly
    private var sourceShowsProjectName = true
    private var accepting = true
    private var shutdownTask: Task<Bool, Never>?

    public init(client: any IslandActivityClient, now: @escaping @Sendable () -> Date = { Date() },
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        controller = IslandActivityController(client: client, now: now)
        self.now = now; self.uptime = uptime; self.sleep = sleep
        let stream = AsyncStream<IslandActivityDelivery>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = stream.stream; continuation = stream.continuation
    }

    @discardableResult
    public func submit(snapshot: SessionSnapshot, sequence: UInt64, scope: IslandActivityScope = .ownedOnly,
                       forceReconciliation: Bool = false, showsProjectName: Bool = true) -> Bool {
        guard accepting, sourceSequence.map({ sequence > $0 }) != false else { return false }
        let force = forceReconciliation || pending?.force == true || scope != sourceScope || showsProjectName != sourceShowsProjectName
        sourceSequence = sequence
        sourceShowsProjectName = showsProjectName
        sourceScope = scope
        pending = Pending(sequence: sequence, snapshot: snapshot, scope: scope, force: force, showsProjectName: showsProjectName)
        if worker == nil { phase = .scheduled }
        // A temporary throttle wait can be interrupted; an already dispatched
        // native operation is allowed to finish before the latest one follows.
        let presentation = try? policy.presentation(for: snapshot, at: now(), showsProjectName: showsProjectName)
        if force || isUrgent(presentation) { delayTask?.cancel() }
        emit()
        startWorker()
        return true
    }

    public func current() -> IslandActivityDelivery {
        IslandActivityDelivery(sourceSequence: sourceSequence, synchronizedSequence: synchronizedSequence, phase: phase, problem: problem)
    }

    /// Wait for currently queued work to settle. Does not poll, fabricate an
    /// acknowledgement or request another SDK update. Intended for verification.
    public func flush() async {
        while let worker { await worker.value }
    }

    /// Reject new input immediately, settle dispatched operations, then clean
    /// up in an uncancelled task. Failed cleanup can be explicitly retried.
    @discardableResult
    public func shutdown() async -> Bool {
        if let shutdownTask { return await shutdownTask.value }
        accepting = false; pending = nil; delayTask?.cancel()
        phase = .stopping; emit()
        let inFlight = worker, controller = self.controller
        let task = Task { [weak self] in
            await inFlight?.value
            do {
                try await controller.shutdown()
                await self?.finishShutdown(problem: nil)
                return true
            } catch {
                await self?.finishShutdown(problem: (error as? IslandActivityError) ?? .endFailed)
                return false
            }
        }
        shutdownTask = task
        let succeeded = await task.value
        if !succeeded { shutdownTask = nil }
        return succeeded
    }

    private struct Pending: Sendable {
        let sequence: UInt64
        let snapshot: SessionSnapshot
        let scope: IslandActivityScope
        let force: Bool
        let showsProjectName: Bool
    }

    private func startWorker() {
        guard accepting, worker == nil, pending != nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    private func drain() async {
        defer {
            worker = nil
            delayTask?.cancel(); delayTask = nil
            if pending != nil { startWorker() }
        }
        while !Task.isCancelled, let next = pending {
            pending = nil
            do {
                let presentation = try policy.presentation(for: next.snapshot, at: now(), showsProjectName: next.showsProjectName)
                if !next.force, hasSynchronized, presentation == lastPresentation {
                    synchronizedSequence = next.sequence
                    problem = nil; phase = pending == nil ? .synchronized : .scheduled
                    emit()
                    continue
                }
                let delay = next.force ? 0 : try nextDelay(for: presentation)
                if delay > 0 {
                    pending = next
                    phase = .scheduled; emit()
                    let sleeper = sleep
                    let timer = Task { try await sleeper(delay) }
                    delayTask = timer
                    do { try await timer.value }
                    catch {
                        if Task.isCancelled { return }
                        if !timer.isCancelled {
                            pending = nil
                            fail(.schedulingFailed)
                            return
                        }
                    }
                    delayTask = nil
                    // Select the newest queued snapshot and recompute both the
                    // payload and deadline after the await, including expiry.
                    continue
                }
                phase = .updating; emit()
                if presentation != nil {
                    lastAttemptAt = try monotonicTime()
                    lastAttemptPresentation = presentation
                }
                // A failed/lost response may still have changed the SDK state.
                // Do not reuse an earlier successful dedup cache in that case.
                hasSynchronized = false
                let actual = try await controller.deliver(snapshot: next.snapshot, scope: next.scope, showsProjectName: next.showsProjectName)
                lastPresentation = actual
                if actual == nil { lastAttemptPresentation = nil }
                hasSynchronized = true
                synchronizedSequence = next.sequence
                problem = nil; phase = !accepting ? .stopping : pending == nil ? .synchronized : .scheduled
                emit()
            } catch is CancellationError {
                if Task.isCancelled { return }
                fail(.cancelled)
            } catch let error as IslandActivityError {
                fail(error)
            } catch {
                fail(.schedulingFailed)
            }
        }
    }

    private func nextDelay(for presentation: IslandActivityPresentation?) throws -> TimeInterval {
        guard presentation != nil else { return 0 }
        let time = try monotonicTime()
        guard lastAttemptAt.map({ time >= $0 }) != false else { throw IslandActivityError.invalidClock }
        guard !isUrgent(presentation), let lastAttemptAt else { return 0 }
        return max(0, Self.minimumUpdateInterval - (time - lastAttemptAt))
    }

    private func isUrgent(_ presentation: IslandActivityPresentation?) -> Bool {
        guard let presentation else { return true }
        guard presentation.state.waitingCount > 0 else { return false }
        guard let previous = lastAttemptPresentation else { return true }
        return presentation.state.waitingCount > previous.state.waitingCount ||
            (presentation.state.phase == .needsInput &&
             (previous.state.phase != .needsInput || previous.state.sessionID != presentation.state.sessionID))
    }

    private func monotonicTime() throws -> TimeInterval {
        let value = uptime()
        guard value.isFinite, value >= 0 else { throw IslandActivityError.invalidClock }
        return value
    }

    private func fail(_ error: IslandActivityError) {
        problem = error; phase = .failed
        emit()
    }

    private func finishShutdown(problem: IslandActivityError?) {
        hasSynchronized = false; lastPresentation = nil
        self.problem = problem
        phase = problem == nil ? .stopped : .failed
        emit()
    }

    private func emit() { continuation.yield(current()) }

    deinit {
        worker?.cancel(); delayTask?.cancel()
        continuation.finish()
    }
}
