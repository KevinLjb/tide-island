import Foundation
import ServiceManagement
import TideIslandCore

@MainActor
final class NativePreferences {
    private let defaults = UserDefaults.standard
    private let key = "tide-island.preferences.v1"
    private(set) var document: AppPreferenceDocument

    init() {
        let object = UserDefaults.standard.object(forKey: "tide-island.preferences.v1")
        document = AppPreferenceDocument(data: object == nil ? nil : (object as? Data ?? Data()))
    }
    func save(_ value: AppPreferences) throws {
        let data = try document.updating(value)
        defaults.set(data, forKey: key)
    }
    func reset(_ value: AppPreferences) throws {
        let data = try document.resetting(to: value)
        defaults.set(data, forKey: key)
    }
}

@MainActor
struct NativeLoginItemClient {
    func state() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
    func setEnabled(_ enabled: Bool) async throws -> LoginItemState {
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
        return state()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
