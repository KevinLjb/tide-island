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

enum NativeLoginItemState: Equatable {
    case disabled, enabled, requiresApproval, unavailable
    var isRequested: Bool { self == .enabled || self == .requiresApproval }
    var message: String? {
        switch self {
        case .disabled, .enabled: nil
        case .requiresApproval: "等待系统允许，可前往登录项设置查看。"
        case .unavailable: "请先安装潮汐岛，再设置登录时启动。"
        }
    }
}

@MainActor
struct NativeLoginItemClient {
    func state() -> NativeLoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
    func setEnabled(_ enabled: Bool) async throws -> NativeLoginItemState {
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
        return state()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
