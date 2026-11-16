import Foundation

public enum WaveApplicationState: String, Sendable {
    case notInstalled, notRunning, running
}

public enum WaveApplicationResponse: Sendable {
    case accepted, unavailable, failed
}

/// App-only public OS integration. No session ID, URL parameters, terminal
/// arguments or credentials are passed to the installed application.
public protocol WaveApplicationDriver: Sendable {
    func state() async throws -> WaveApplicationState
    func open() async throws -> WaveApplicationResponse
}

public enum WaveReturnOutcome: String, Sendable {
    case applicationRequested, notInstalled, openFailed, staleSelection, busy, cancelled
}

public struct WaveReturnResult: Equatable, Sendable {
    public let reference: SessionReference
    public let navigation: WaveNavigationResult?
    public let applicationState: WaveApplicationState?
    public let applicationAttempted: Bool
    public let outcome: WaveReturnOutcome

    public var attemptedRoutes: [WaveNavigationRoute] {
        let focus = navigation?.attemptedRoute == .tabLayoutFocus ? [WaveNavigationRoute.tabLayoutFocus] : []
        return focus + (applicationAttempted ? [.application] : [])
    }

    public var message: String? {
        switch outcome {
        case .applicationRequested:
            applicationState == .notRunning
                ? "已请求启动 Wave，请在 Wave 中确认目标会话。"
                : "已请求返回 Wave，请在 Wave 中确认目标会话。"
        case .notInstalled: "未找到 Wave，请先安装后重试。"
        case .openFailed: "Wave 暂时无法打开，请稍后重试。"
        case .staleSelection: "会话记录已变化，请选择当前会话重试。"
        case .busy: "正在返回 Wave，请稍候。"
        case .cancelled: nil
        }
    }
}

/// Explicit user return action. Even a layout-focus acknowledgement still
/// needs an app activation request; neither proves a particular window visible.
/// No app action follows a stale, concurrent or cancelled navigation request.
public actor WaveReturnCoordinator {
    public static let bundleIdentifier = "dev.commandline.waveterm"

    private let navigator: WaveNavigationCoordinator
    private let driver: any WaveApplicationDriver
    private let snapshot: @Sendable () async -> SessionSnapshot
    private let now: @Sendable () -> Date
    private var running = false

    public init(driver: any WaveApplicationDriver, navigator: WaveNavigationCoordinator? = nil,
                snapshot: @escaping @Sendable () async -> SessionSnapshot,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.driver = driver
        self.navigator = navigator ?? WaveNavigationCoordinator(snapshot: snapshot, now: now)
        self.snapshot = snapshot
        self.now = now
    }

    public func returnToWave(for reference: SessionReference) async -> WaveReturnResult {
        guard !Task.isCancelled else { return result(reference, .cancelled) }
        guard !running else { return result(reference, .busy) }
        running = true
        defer { running = false }
        var navigation: WaveNavigationResult?
        var state: WaveApplicationState?
        var attempted = false
        do {
            let initial = await snapshot()
            guard !Task.isCancelled else { return result(reference, .cancelled) }
            guard SessionLink.isCurrent(reference, in: initial, at: now()) else { return result(reference, .staleSelection) }
            let routed = await navigator.navigate(to: reference)
            navigation = routed
            guard !Task.isCancelled else { return result(reference, .cancelled, navigation: navigation) }
            switch routed.outcome {
            case .rejected: return result(reference, .staleSelection, navigation: navigation)
            case .busy: return result(reference, .busy, navigation: navigation)
            case .cancelled: return result(reference, .cancelled, navigation: navigation)
            case .applicationFallbackRequired, .focusAcknowledged: break
            }
            state = try await driver.state()
            guard !Task.isCancelled else { return result(reference, .cancelled, navigation: navigation, state: state) }
            let current = await snapshot()
            guard !Task.isCancelled else { return result(reference, .cancelled, navigation: navigation, state: state) }
            guard SessionLink.isCurrent(reference, in: current, at: now()) else {
                return result(reference, .staleSelection, navigation: navigation, state: state)
            }
            guard state != .notInstalled else { return result(reference, .notInstalled, navigation: navigation, state: state) }
            attempted = true
            let response = try await driver.open()
            guard !Task.isCancelled else {
                return result(reference, .cancelled, navigation: navigation, state: state, attempted: attempted)
            }
            let outcome: WaveReturnOutcome
            switch response {
            case .accepted: outcome = .applicationRequested
            case .unavailable: outcome = .notInstalled
            case .failed: outcome = .openFailed
            }
            return result(reference, outcome, navigation: navigation, state: state, attempted: attempted)
        } catch is CancellationError {
            return result(reference, .cancelled, navigation: navigation, state: state, attempted: attempted)
        } catch {
            return result(reference, Task.isCancelled ? .cancelled : .openFailed,
                          navigation: navigation, state: state, attempted: attempted)
        }
    }

    private func result(_ reference: SessionReference, _ outcome: WaveReturnOutcome,
                        navigation: WaveNavigationResult? = nil, state: WaveApplicationState? = nil,
                        attempted: Bool = false) -> WaveReturnResult {
        WaveReturnResult(reference: reference, navigation: navigation, applicationState: state,
                         applicationAttempted: attempted, outcome: outcome)
    }
}
