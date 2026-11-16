import Foundation
import TideIslandCore
@preconcurrency import UserNotifications

@MainActor
final class NativeReminderController: NSObject, UNUserNotificationCenterDelegate {
    private let client: NativeReminderClient
    private let coordinator: SessionReminderCoordinator
    var onOpenSession: (@MainActor @Sendable (URL) -> Void)?
    var frames: AsyncStream<SessionReminderDelivery> { coordinator.frames }

    override init() {
        let client = NativeReminderClient()
        self.client = client
        coordinator = SessionReminderCoordinator(client: client)
        super.init()
        client.center.delegate = self
    }

    func submit(snapshot: SessionSnapshot, sequence: UInt64, isPrimary: Bool, settings: SessionReminderSettings) async {
        // No trusted foreground-block driver is installed. Opening Wave or
        // selecting a row is never converted into verified viewing evidence.
        await coordinator.submit(snapshot: snapshot, sequence: sequence, isPrimary: isPrimary, settings: settings)
    }

    /// Called only by the explicit settings action.
    func requestAuthorization() async throws -> Bool {
        try await client.center.requestAuthorization(options: [.alert, .sound])
    }

    /// Read-only; never prompts and never posts a notification.
    func authorization() async -> SessionReminderAuthorization { await client.authorization() }

    func shutdown() async { await coordinator.shutdown() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo["tideIslandSessionURL"] as? String,
              raw.utf8.count <= 4096, let url = URL(string: raw), SessionLink.sessionID(from: url) != nil else { return }
        await openSession(url)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    private func openSession(_ url: URL) { onOpenSession?(url) }
}

@MainActor
private final class NativeReminderClient: SessionReminderClient {
    let center = UNUserNotificationCenter.current()

    func authorization() async -> SessionReminderAuthorization {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional { return .allowed }
        return settings.authorizationStatus == .notDetermined ? .notRequested : .denied
    }

    func post(_ reminder: SessionReminder) async throws {
        try Task.checkCancellation()
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        if reminder.sound { content.sound = .default }
        content.userInfo = ["tideIslandSessionURL": reminder.sessionURL.absoluteString]
        try await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: nil))
    }
}
