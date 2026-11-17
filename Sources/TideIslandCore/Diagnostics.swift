import Foundation

public enum DiagnosticError: String, Error, LocalizedError, Sendable {
    case invalidClock, reportTooLarge, invalidDestination, exportFailed

    public var errorDescription: String? { "Diagnostic operation failed (\(rawValue))." }
}

/// A one-shot allowlist projection. Never encode a session, event, navigation
/// reference, arbitrary Error, file name, process environment or raw log here.
public struct DiagnosticReport: Encodable, Sendable {
    public static let maximumBytes = 16 * 1024
    public let schemaVersion = 1
    public let capturedAt: Date
    public let versions = Versions()
    public let scope: String
    public let source: Source?
    public let sessions: Sessions?
    public let inventory: Inventory?
    public let waveReturn: DiagnosticWaveReturn?
    public let system: DiagnosticSystemStatus?
    public let nativeRuntimeVerified = false
    public let visibleWaveFocusVerified = false
    public let replayContainsUserData = false

    public struct Versions: Encodable, Sendable {
        public let tideIsland = TideIslandVersion.version
        public let build = TideIslandVersion.build
        public let readableEventVersions = [1, AgentEvent.currentVersion]
        public let outputEventVersion = AgentEvent.currentVersion
        public let codexContract = CodexHookAdapter.contractCLIVersion
        public let codexContractRevision = CodexHookAdapter.upstreamRevision
        public let reviewedWave = WaveLocation.reviewedWaveVersion
        public let installedCodexQueried = false
        public let installedWaveQueried = false
    }

    public struct Source: Encodable, Sendable {
        public let state: String
        public let problem: String?
        public let frameReceivedAt: Date?
        public let lastSuccessAt: Date?
        public let retryAttempt: Int
        public let willRetry: Bool
        public let rejectionCounts: [String: Int]
        public let unsafeFiles: Int
        public let recoveryIssues: Int
        public let persistencePhase: String
        public let persistenceProblem: String?
    }

    public struct Sessions: Encodable, Sendable {
        public let visible: Int
        public let ignored: Int
        public let working: Int
        public let waiting: Int
        public let unknown: Int
        public let unread: Int
        public let sourceCounts: [String: Int]
        public let legacyWithoutSource: Int
        public let latestObservedAt: Date?
    }

    public struct Inventory: Encodable, Sendable {
        public let state: String
        public let problem: String?
        public let acceptedEventFiles: Int?
        public let rejectedFiles: Int?
        public let unsafeFiles: Int?
        public let rejectionCounts: [String: Int]?
        public let sourceCounts: [String: Int]?
        public let legacyWithoutSource: Int?
        public let oldestObservedAt: Date?
        public let latestObservedAt: Date?
        public let runtimeStateAssessed = false
        public let checkpointRead = false
    }

    /// Captures an already received frame, preserving its age and confirmation
    /// status. It does not reconnect, replay history or change attention state.
    public static func live(frame: InboxFrame?, frameReceivedAt: Date?, at now: Date,
                            waveReturn: DiagnosticWaveReturn? = nil,
                            system: DiagnosticSystemStatus? = nil) throws -> DiagnosticReport {
        try validate(now)
        let source = frame.map { frame in
            Source(state: frame.health.state.rawValue, problem: frame.health.problem?.rawValue,
                   frameReceivedAt: finite(frameReceivedAt), lastSuccessAt: finite(frame.health.lastSuccessAt),
                   retryAttempt: frame.health.retryAttempt, willRetry: frame.health.willRetry,
                   rejectionCounts: reasons(frame.health.rejectionCounts), unsafeFiles: frame.health.unsafeFiles,
                   recoveryIssues: frame.health.recoveryIssues, persistencePhase: frame.persistence.phase.rawValue,
                   persistenceProblem: frame.persistence.problem?.rawValue)
        }
        let sessions = frame.map { frame in
            let snapshot = frame.snapshot, all = snapshot.sessions + snapshot.ignoredSessions
            return Sessions(visible: snapshot.sessions.count, ignored: snapshot.ignoredSessions.count,
                            working: snapshot.workingCount, waiting: snapshot.waitingCount,
                            unknown: snapshot.unknownCount, unread: snapshot.unreadCount,
                            sourceCounts: sourceCounts(all.compactMap { $0.session.context?.source }),
                            legacyWithoutSource: all.filter { $0.session.context == nil }.count,
                            latestObservedAt: all.compactMap { finite($0.session.updatedAt) }.max())
        }
        return DiagnosticReport(capturedAt: now, scope: frame == nil ? "liveUnavailable" : "cachedReceiverFrame",
                                source: source, sessions: sessions, inventory: nil, waveReturn: waveReturn, system: system)
    }

    /// With no explicit inbox this reports versions only and never reads user
    /// data. An inventory is a complete bounded scan, not reconstructed live
    /// sessions: reset-suppressed files must never become current state here.
    public static func offline(inbox: EventInbox? = nil, at now: Date = Date(),
                               limits: InboxReadLimits = InboxReadLimits()) throws -> DiagnosticReport {
        try validate(now)
        var inventory: Inventory?
        if let inbox {
            do {
                var cursor = InboxCursor()
                let update = try inbox.readIncrementally(using: &cursor, limits: limits)
                inventory = Inventory(state: "scanned", problem: nil, acceptedEventFiles: update.events.count,
                    rejectedFiles: update.rejectedFiles, unsafeFiles: update.skippedFiles,
                    rejectionCounts: reasons(update.rejectionCounts),
                    sourceCounts: sourceCounts(update.events.compactMap { $0.context?.source }),
                    legacyWithoutSource: update.events.filter { $0.context == nil }.count,
                    oldestObservedAt: update.events.compactMap { finite($0.occurredAt) }.min(),
                    latestObservedAt: update.events.compactMap { finite($0.occurredAt) }.max())
            } catch {
                inventory = Inventory(state: "unavailable", problem: inboxProblem(error), acceptedEventFiles: nil,
                    rejectedFiles: nil, unsafeFiles: nil, rejectionCounts: nil, sourceCounts: nil,
                    legacyWithoutSource: nil, oldestObservedAt: nil, latestObservedAt: nil)
            }
        }
        return DiagnosticReport(capturedAt: now, scope: inbox == nil ? "versionsOnly" : "offlineInventory",
                                source: nil, sessions: nil, inventory: inventory, waveReturn: nil, system: nil)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self) + Data([10])
        guard data.count <= Self.maximumBytes else { throw DiagnosticError.reportTooLarge }
        return data
    }

    private static func validate(_ time: Date) throws {
        guard finite(time) != nil else { throw DiagnosticError.invalidClock }
    }

    private static func finite(_ time: Date?) -> Date? {
        time.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
    }

    private static func reasons(_ values: [InboxRejectionReason: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    private static func sourceCounts(_ sources: [EventSource]) -> [String: Int] {
        sources.reduce(into: [:]) { $0[$1.rawValue, default: 0] += 1 }
    }

    private static func inboxProblem(_ error: any Error) -> String {
        guard let error = error as? InboxError else { return "fileOperation" }
        switch error {
        case .unsafeDirectory: return "unsafeDirectory"
        case .unmanagedDirectory: return "unmanagedDirectory"
        case .unsafeFile: return "unsafeFile"
        case .changedDuringRead: return "changedDuringRead"
        case .limitExceeded: return "limitExceeded"
        case .busy: return "busy"
        case .invalidPolicy: return "invalidPolicy"
        case .stalePlan: return "stalePlan"
        case .fileOperation: return "fileOperation"
        case .conflictingEventID: return "conflictingEventID"
        case .cleanupIncomplete: return "cleanupIncomplete"
        case .recoveryRequired: return "recoveryRequired"
        case .receiverAlreadyRunning: return "receiverAlreadyRunning"
        }
    }
}

/// Construct this at completion of the actual action. Only enum values / time
/// survive; the session reference and navigation location cannot be encoded.
public struct DiagnosticWaveReturn: Encodable, Sendable {
    public let observedAt: Date
    public let attemptedRoutes: [String]
    public let outcome: String
    public let navigationOutcome: String?
    public let navigationReason: String?
    public let applicationState: String?
    public let visibleFocusVerified = false

    public init(result: WaveReturnResult, at time: Date) throws {
        guard time.timeIntervalSince1970.isFinite else { throw DiagnosticError.invalidClock }
        observedAt = time
        attemptedRoutes = result.attemptedRoutes.map(\.rawValue)
        outcome = result.outcome.rawValue
        navigationOutcome = result.navigation?.outcome.rawValue
        navigationReason = result.navigation?.reason?.rawValue
        applicationState = result.applicationState?.rawValue
    }
}

/// Cached system observations only; assembling this never invokes native APIs.
public struct DiagnosticSystemStatus: Encodable, Sendable {
    public let activityAvailability: String
    public let activityProblem: String?
    public let remindersEnabled: Bool
    public let notificationAuthorization: String
    public let reminderProblem: String?
    public let loginItem: String

    public init(activity: NativeActivityAvailability, activityProblem: IslandActivityError?, remindersEnabled: Bool,
                notificationAuthorization: SessionReminderAuthorization?, reminderProblem: SessionReminderProblem?, login: LoginItemState) {
        switch activity {
        case .unknown: activityAvailability = "unknown"
        case .unavailable: activityAvailability = "unavailable"
        case .disabled: activityAvailability = "disabled"
        case .allowed: activityAvailability = "allowed"
        }
        self.activityProblem = activityProblem?.rawValue
        self.remindersEnabled = remindersEnabled
        switch notificationAuthorization {
        case nil: self.notificationAuthorization = "unknown"
        case .notRequested: self.notificationAuthorization = "notRequested"
        case .allowed: self.notificationAuthorization = "allowed"
        case .denied: self.notificationAuthorization = "denied"
        }
        self.reminderProblem = reminderProblem?.rawValue
        switch login {
        case .disabled: loginItem = "disabled"
        case .enabled: loginItem = "enabled"
        case .requiresApproval: loginItem = "requiresApproval"
        case .unavailable: loginItem = "unavailable"
        }
    }
}
