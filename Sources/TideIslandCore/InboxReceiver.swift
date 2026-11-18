import Dispatch
import Foundation

public enum InboxChannelState: String, Sendable {
    case stopped, recovering, healthy, degraded, unavailable
}

public enum InboxChannelProblem: String, Sendable {
    case directoryUnavailable, invalidMarker, readLimitExceeded, unsafeFile
    case changing, busy, receiverInUse, interruptedOperation, damagedEvents, watcherUnavailable, savedStateUnavailable, ioFailure
}

public struct InboxHealth: Equatable, Sendable {
    public internal(set) var state: InboxChannelState = .stopped
    public internal(set) var problem: InboxChannelProblem?
    public internal(set) var retryAttempt = 0
    public internal(set) var willRetry = false
    public internal(set) var lastSuccessAt: Date?
    public internal(set) var rejectionCounts: [InboxRejectionReason: Int] = [:]
    public internal(set) var unsafeFiles = 0
    public internal(set) var recoveryIssues = 0

    public var message: String? {
        if state == .healthy { return nil }
        if state == .stopped { return "事件通道已停止。" }
        let detail: String
        switch problem {
        case .directoryUnavailable: detail = "事件目录不可访问，将检查目录并重新监听。"
        case .invalidMarker: detail = "事件目录标记无效，请检查或恢复原有标记后重试。"
        case .readLimitExceeded: detail = "事件读取超过上限，未接受不完整批次；请通过命令行调整扫描预算并维护历史。"
        case .unsafeFile: detail = "事件目录含不安全的文件或锁，请检查后重试。"
        case .changing: detail = "事件目录已变化，正在重新确认。"
        case .busy: detail = "事件维护繁忙，暂时无法确认状态。"
        case .receiverInUse: detail = "已有另一个 TideIsland 接收者使用此目录，请关闭该实例后重试。"
        case .interruptedOperation: detail = "存在未完成或冲突的写入 / 清理操作，已保留文件；请检查 inbox recover 的原因码。"
        case .damagedEvents:
            detail = "存在无法识别或不安全的事件（损坏 \(rejectionCounts[.malformed, default: 0])、未知版本 \(rejectionCounts[.unsupportedVersion, default: 0])、过大 \(rejectionCounts[.oversized, default: 0])、ID 不匹配 \(rejectionCounts[.filenameMismatch, default: 0])、链接等 \(unsafeFiles)），已保留文件。"
        case .watcherUnavailable: detail = "目录监听已失效，正在重新连接。"
        case .savedStateUnavailable: detail = "保存的会话数据尚未恢复，暂不确认实时状态。"
        case .ioFailure, nil: detail = "事件通道暂不可用，请检查本地数据目录后重试。"
        }
        return detail + (willRetry ? " 正在有限次自动重试。" : " 可点击重新连接。")
    }
}

public struct InboxFrame: Sendable {
    public let snapshot: SessionSnapshot
    public let health: InboxHealth
    public let cleanupPlan: InboxCleanupPlan?
    public let notice: String?
    public let persistence: SessionPersistenceStatus
    public let resetPreview: SessionResetPreview?
}

/// One serialized owner of IO, source confirmation, attention actions, retries
/// and time boundaries. AppKit / ActivityKit are consumers of these frames.
public actor InboxReceiver {
    public nonisolated let frames: AsyncStream<InboxFrame>
    private let continuation: AsyncStream<InboxFrame>.Continuation
    private let inbox: EventInbox
    private let limits: InboxReadLimits
    private let now: @Sendable () -> Date
    private let stateFile: SessionStateFile?
    private var store = SessionStore()
    private var cursor = InboxCursor()
    private var confirmedEvents: [UUID: AgentEvent] = [:]
    private var health = InboxHealth()
    private var notice: String?
    private var cleanupPlan: InboxCleanupPlan?
    private var resetPreview: SessionResetPreview?
    private var persistence = SessionPersistenceStatus()
    private var loadedState = false
    private var hasCheckpoint = false
    private var stateRevision: SessionStateRevision?
    private var processedFiles: [String: String] = [:]
    private var needsSave = false
    private var saveTask: Task<Void, Never>?
    private var started = false
    private var lease: InboxConsumerLease?
    private var directoryMonitor: InboxMonitor?
    private var parentMonitor: InboxMonitor?
    private(set) var directoryGeneration: UInt64 = 0
    private var parentGeneration: UInt64 = 0
    private var retryAttempt = 0
    private var retryTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    public init(inbox: EventInbox, limits: InboxReadLimits = InboxReadLimits(), persistence stateFile: SessionStateFile? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.inbox = inbox
        self.limits = limits
        self.now = now
        self.stateFile = stateFile
        if stateFile != nil { persistence.phase = .loading }
        let pair = AsyncStream<InboxFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = pair.stream
        continuation = pair.continuation
    }

    @discardableResult
    public func start() -> InboxFrame {
        guard !started else { return current() }
        started = true
        return reconnect()
    }

    /// Explicit retry, activation and wake all verify and rearm the real path.
    @discardableResult
    public func reconnect() -> InboxFrame {
        guard started else { return start() }
        let announcesRecovery = health.state != .healthy
        if stateFile != nil, persistence.phase == .unavailable, !needsSave { loadedState = false }
        cancelScheduledReads()
        retryAttempt = 0
        cancelMonitors()
        health.state = .recovering
        health.problem = .changing
        health.willRetry = false
        health.retryAttempt = 0
        cleanupPlan = nil
        resetPreview = nil
        // Verification below is synchronous on this actor. A routine check of
        // a healthy source publishes its verified result once, rather than a
        // provisional loss that can end an activity and trigger another check.
        // Startup / existing failures and real watcher invalidations still
        // publish recovery; reload failures still publish an unavailable frame.
        if announcesRecovery { emit() }
        return reload()
    }

    @discardableResult
    public func stop() -> InboxFrame {
        _ = flushSavedState()
        started = false
        cancelScheduledReads()
        expiryTask?.cancel(); expiryTask = nil
        cancelMonitors()
        lease = nil
        confirmedEvents = [:]
        cleanupPlan = nil
        resetPreview = nil
        if stateFile != nil { loadedState = false }
        health.state = .stopped
        health.problem = nil
        health.willRetry = false
        return emit()
    }

    public func current() -> InboxFrame {
        InboxFrame(snapshot: store.snapshot(at: now(),
                                            sourceIssue: health.state == .healthy ? nil : .channelUnavailable,
                                            confirmedEvents: confirmedEvents),
                   health: health, cleanupPlan: cleanupPlan, notice: notice, persistence: persistence, resetPreview: resetPreview)
    }

    /// Reads already confirmed, remembered metadata only. No disk read, source
    /// refresh, preference action, replay or new cleanup intent occurs here.
    public func metadataHistory(for reference: SessionReference, limit: Int = 8) -> Result<SessionMetadataHistory, SessionMetadataProblem> {
        guard (1...SessionMetadataHistory.maximumResults).contains(limit) else { return .failure(.invalidLimit) }
        let time = now()
        guard time.timeIntervalSince1970.isFinite else { return .failure(.invalidClock) }
        guard started, health.state == .healthy, let confirmedAt = health.lastSuccessAt,
              confirmedAt.timeIntervalSince1970.isFinite else { return .failure(.sourceUnavailable) }
        let snapshot = store.snapshot(at: time, confirmedEvents: confirmedEvents)
        guard let status = (snapshot.sessions + snapshot.ignoredSessions).first(where: { $0.reference == reference }),
              let ids = store.metadataEventIDs(for: reference) else { return .failure(.staleSelection) }
        guard status.sourceIssue == nil else { return .failure(.sourceUnavailable) }
        // At most the existing 512 UUID window plus its current observation
        // can match. A reset's suppressed import index never becomes history.
        let remembered = confirmedEvents.values.filter { $0.sessionID == reference.sessionID && ids.contains($0.id) }.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            if ($0.id == reference.eventID) != ($1.id == reference.eventID) { return $0.id == reference.eventID }
            return $0.id.uuidString < $1.id.uuidString
        }
        return .success(SessionMetadataHistory(reference: reference,
            entries: remembered.prefix(limit).map { SessionEventMetadata(event: $0, currentEventID: reference.eventID) },
            availableCount: remembered.count, confirmedAt: confirmedAt))
    }

    @discardableResult
    public func perform(_ action: SessionAction, for reference: SessionReference) -> Bool {
        guard stateFile == nil || loadedState else { return false }
        let accepted = store.perform(action, for: reference, at: now())
        notice = accepted ? nil : "状态已变化，请使用当前会话记录重试。"
        if accepted { needsSave = true; resetPreview = nil; _ = flushSavedState() }
        emit()
        return accepted
    }

    public func clearSelection() {
        guard stateFile == nil || loadedState else { return }
        store.clearSelection()
        needsSave = true
        resetPreview = nil
        _ = flushSavedState()
        emit()
    }

    /// Preferences are saved before their action returns. Event bursts share
    /// a maximum 300 ms save window; their original inbox files remain durable.
    @discardableResult
    public func flushSavedState(forceVerification: Bool = false) -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard let stateFile else { needsSave = false; return true }
        guard loadedState, let expected = stateRevision else { return false }
        guard needsSave || (forceVerification && hasCheckpoint) else { return true }
        do {
            try lease?.verifyPath()
            guard lease != nil else { throw SessionStateError.conflict }
            stateRevision = try stateFile.save(store, index: processedFiles, expected: expected)
            needsSave = false
            hasCheckpoint = true
            persistence.phase = .saved
            persistence.problem = nil
            return true
        } catch {
            persistence.phase = .unavailable
            persistence.problem = (error as? SessionStateError) ?? .fileOperation
            return false
        }
    }

    @discardableResult
    public func previewReset() -> SessionResetPreview? {
        do {
            guard let stateFile, started, let lease else { throw SessionStateError.fileOperation }
            try lease.verifyPath()
            _ = flushSavedState()
            resetPreview = try stateFile.previewReset(limits: limits)
            notice = nil
        } catch {
            resetPreview = nil
            notice = "无法生成清除预览，请检查事件目录和恢复数据后重试。"
        }
        emit()
        return resetPreview
    }

    @discardableResult
    public func applyReset(expectedFingerprint: String) -> Bool {
        guard let stateFile, started, let lease, let preview = resetPreview,
              preview.fingerprint == expectedFingerprint else {
            notice = "清除预览已变化，请重新预览。"; emit(); return false
        }
        resetPreview = nil
        saveTask?.cancel(); saveTask = nil
        do {
            try lease.verifyPath()
            let result = try stateFile.resetWhileReceiving(preview, expectedFingerprint: expectedFingerprint, limits: limits)
            store = result.snapshot.store
            cursor = result.cursor
            processedFiles = result.snapshot.importIndex
            stateRevision = result.snapshot.revision
            loadedState = true
            hasCheckpoint = true
            needsSave = false
            persistence.phase = .saved
            persistence.problem = nil
            cleanupPlan = nil
            notice = "已清除会话与偏好；保留事件文件，已有记录不再重新导入。"
            _ = reload(preserveNotice: true)
            return true
        } catch {
            notice = "恢复数据或事件目录已变化，尚未清除；请重新预览。"
            emit()
            return false
        }
    }

    public func previewCleanup() {
        do {
            guard started, let lease else { throw InboxError.receiverAlreadyRunning }
            try lease.verifyPath()
            cleanupPlan = try inbox.previewCleanup(at: now(), limits: limits)
            notice = nil
        } catch {
            cleanupPlan = nil
            notice = "无法生成清理预览；请先恢复事件通道。"
        }
        emit()
    }

    public func applyCleanup() {
        guard started, let lease, let plan = cleanupPlan else { return }
        cleanupPlan = nil
        do {
            try lease.verifyPath()
            _ = reload(preserveNotice: true)
            guard health.state == .healthy || health.state == .degraded else {
                notice = "事件历史尚未完整读取，暂不清理。"; emit(); return
            }
            guard flushSavedState(forceVerification: true) else {
                notice = "会话状态尚未保存，暂不清理历史，以免重启后丢失轮次保护。"
                emit(); return
            }
            let result = try inbox.applyCleanup(plan, expectedFingerprint: plan.fingerprint, limits: limits)
            notice = "已清理 \(result.removedFiles) 个过期事件文件。"
            if !result.failedFiles.isEmpty { notice = "清理尚未完成，将尝试恢复已批准的操作。" }
            if !result.targetsMet { notice = (notice ?? "") + "受保护或无法识别的历史仍超出容量目标。" }
            _ = reload(preserveNotice: true)
        } catch {
            notice = "清理预览已变化或清理中断，请恢复通道后重新预览。"
            _ = reload(preserveNotice: true)
        }
    }

    /// Demo and manual inputs use the same file publication/confirmation path.
    public func submit(_ event: AgentEvent) {
        do {
            guard started, let lease else { throw InboxError.receiverAlreadyRunning }
            try lease.verifyPath()
            try inbox.write(event)
            _ = reload()
        } catch {
            fail(error)
        }
    }

    private func reload(preserveNotice: Bool = false) -> InboxFrame {
        guard started else { return current() }
        do {
            if lease == nil { lease = try InboxConsumerLease(inbox: inbox.directory) }
            try lease?.verifyPath()
            try armParentMonitor()
            try inbox.prepare()
            try armDirectoryMonitor()
            if let stateFile, !loadedState {
                guard stateFile.inbox.directory.standardizedFileURL == inbox.directory.standardizedFileURL else {
                    throw SessionStateError.scopeMismatch
                }
                let restored = try stateFile.load()
                store = restored.store
                cursor = InboxCursor()
                confirmedEvents = [:]
                processedFiles = restored.importIndex
                stateRevision = restored.revision
                loadedState = true
                hasCheckpoint = restored.existed
                needsSave = false
                persistence.phase = .saved
                persistence.problem = nil
            }
            let recovery = try inbox.recoverInterruptedOperations(limits: limits)
            var nextCursor = cursor
            let update = try inbox.readIncrementally(using: &nextCursor, limits: limits)
            var nextStore = store
            let events = nextCursor.unimportedEvents(update.events, index: processedFiles)
            try nextStore.receive(events)
            try lease?.verifyPath()
            cursor = nextCursor
            store = nextStore
            let nextIndex = cursor.importIndex
            if !events.isEmpty || nextIndex != processedFiles || (stateFile != nil && !hasCheckpoint) {
                needsSave = true
                resetPreview = nil
            }
            processedFiles = nextIndex
            confirmedEvents = cursor.confirmedEvents
            if update.changedFiles > 0 || update.removedFiles > 0 || update.directoryChanged { cleanupPlan = nil }
            retryTask?.cancel(); retryTask = nil
            retryAttempt = 0
            health = InboxHealth()
            health.lastSuccessAt = now()
            health.rejectionCounts = update.rejectionCounts
            health.unsafeFiles = update.skippedFiles
            health.recoveryIssues = recovery.issues.count
            health.state = .healthy
            if !recovery.issues.isEmpty {
                health.state = .degraded; health.problem = .interruptedOperation
            } else if update.rejectedFiles > 0 || update.skippedFiles > 0 {
                health.state = .degraded; health.problem = .damagedEvents
            }
            scheduleSave()
            if !preserveNotice {
                notice = nil
                if update.scannedFiles > InboxRetentionPolicy().maximumFiles || update.totalBytes > InboxRetentionPolicy().maximumBytes {
                    notice = "事件历史超过容量目标，可预览历史清理。"
                }
                if recovery.recoveredEvents > 0 || recovery.resumedCleanupFiles > 0 || recovery.removedStages > 0 {
                    notice = "已恢复中断的事件写入 / 历史清理。"
                }
            }
        } catch { return fail(error) }
        return emit()
    }

    @discardableResult
    private func fail(_ error: Error) -> InboxFrame {
        cleanupPlan = nil
        resetPreview = nil
        health.state = .unavailable
        health.willRetry = false
        var retryable = false
        if let savedError = error as? SessionStateError {
            persistence.phase = .unavailable
            persistence.problem = savedError
            health.problem = .savedStateUnavailable
            retryTask?.cancel(); retryTask = nil
            return emit()
        }
        switch error as? InboxError {
        case .busy: health.problem = .busy; retryable = true
        case .changedDuringRead:
            health.problem = .changing; retryable = true
            cancelMonitors()
            // Reacquire only after checking the lease's path; never keep using
            // an unlinked lock when its parent has been replaced.
            if (try? lease?.verifyPath()) == nil { lease = nil }
        case .unsafeDirectory: health.problem = .directoryUnavailable; retryable = true
        case .unmanagedDirectory: health.problem = .invalidMarker
        case .limitExceeded: health.problem = .readLimitExceeded
        case .unsafeFile: health.problem = .unsafeFile
        case .receiverAlreadyRunning: health.problem = .receiverInUse
        case .recoveryRequired: health.problem = .interruptedOperation
        default: health.problem = .ioFailure; retryable = true
        }
        retryTask?.cancel(); retryTask = nil
        if started, retryable, retryAttempt < 5 {
            retryAttempt += 1
            health.state = .recovering
            health.willRetry = true
            let delay = 0.1 * pow(2, Double(retryAttempt - 1))
            retryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.retryRead()
            }
        }
        health.retryAttempt = retryAttempt
        return emit()
    }

    private func retryRead() { retryTask = nil; _ = reload() }

    private func armParentMonitor() throws {
        guard parentMonitor == nil else { return }
        parentGeneration &+= 1
        let generation = parentGeneration
        parentMonitor = try InboxMonitor(directory: inbox.directory.deletingLastPathComponent()) { [weak self] flags in
            Task { await self?.monitorChanged(flags: flags, generation: generation, parent: true) }
        }
    }

    private func armDirectoryMonitor() throws {
        let directory = try InboxDirectory(url: inbox.directory, create: false, requireMarker: true)
        let rootIdentity = String(directory.identity.split(separator: ":").prefix(2).joined(separator: ":"))
        if directoryMonitor?.identity == rootIdentity { return }
        directoryMonitor?.cancel()
        directoryGeneration &+= 1
        let generation = directoryGeneration
        directoryMonitor = try InboxMonitor(directory: inbox.directory) { [weak self] flags in
            Task { await self?.monitorChanged(flags: flags, generation: generation, parent: false) }
        }
        try directory.verifyPath()
    }

    // Internal so tests can deliver a real old generation after rearming.
    func monitorChanged(flags: UInt, generation: UInt64, parent: Bool) {
        guard started, generation == (parent ? parentGeneration : directoryGeneration) else { return }
        let event = DispatchSource.FileSystemEvent(rawValue: flags)
        if !event.intersection([.delete, .rename, .revoke]).isEmpty {
            health.state = .recovering
            health.problem = .watcherUnavailable
            health.willRetry = true
            cleanupPlan = nil
            if parent {
                parentMonitor?.cancel(); parentMonitor = nil; parentGeneration &+= 1
                lease = nil
            } else {
                directoryMonitor?.cancel(); directoryMonitor = nil; directoryGeneration &+= 1
            }
            emit()
        }
        retryAttempt = 0
        retryTask?.cancel(); retryTask = nil
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.debouncedRead()
        }
    }

    private func debouncedRead() { debounceTask = nil; _ = reload() }

    private func cancelMonitors() {
        directoryGeneration &+= 1; parentGeneration &+= 1
        directoryMonitor?.cancel(); directoryMonitor = nil
        parentMonitor?.cancel(); parentMonitor = nil
    }

    private func cancelScheduledReads() {
        retryTask?.cancel(); retryTask = nil
        debounceTask?.cancel(); debounceTask = nil
    }

    @discardableResult
    private func emit() -> InboxFrame {
        let frame = current()
        continuation.yield(frame)
        expiryTask?.cancel(); expiryTask = nil
        if started, let deadline = frame.snapshot.nextTransitionAt {
            let delay = max(0.1, deadline.timeIntervalSince(now()))
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.expire()
            }
        }
        return frame
    }

    private func expire() { expiryTask = nil; emit() }

    private func scheduleSave() {
        guard stateFile != nil, loadedState, needsSave, saveTask == nil else { return }
        // Never postpone an existing deadline during a continuous event burst.
        if persistence.phase != .unavailable { persistence.phase = .pending }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.savePending()
        }
    }

    private func savePending() { saveTask = nil; _ = flushSavedState(); emit() }

    deinit {
        retryTask?.cancel(); debounceTask?.cancel(); expiryTask?.cancel(); saveTask?.cancel()
        directoryMonitor?.cancel(); parentMonitor?.cancel()
        continuation.finish()
    }
}
