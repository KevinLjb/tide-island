import Foundation

public enum HistoryVisibility: Int, Codable, CaseIterable, Hashable, Sendable {
    case oneHour = 3600, sixHours = 21600, oneDay = 86400
    public var title: String {
        switch self { case .oneHour: "1 小时"; case .sixHours: "6 小时"; case .oneDay: "24 小时" }
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var reminders: SessionReminderSettings
    public var historyVisibility: HistoryVisibility
    /// Last explicit intent; the OS status remains authoritative for startup.
    public var launchAtLogin: Bool
    public var showsCodexQuota: Bool

    public init(reminders: SessionReminderSettings = .init(), historyVisibility: HistoryVisibility = .oneDay,
                launchAtLogin: Bool = false, showsCodexQuota: Bool = false) {
        self.reminders = reminders; self.historyVisibility = historyVisibility; self.launchAtLogin = launchAtLogin
        self.showsCodexQuota = showsCodexQuota
    }

    private enum CodingKeys: String, CodingKey { case reminders, historyVisibility, launchAtLogin, showsCodexQuota }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(reminders: try fields.decode(SessionReminderSettings.self, forKey: .reminders),
                  historyVisibility: try fields.decode(HistoryVisibility.self, forKey: .historyVisibility),
                  launchAtLogin: try fields.decode(Bool.self, forKey: .launchAtLogin),
                  showsCodexQuota: try fields.decodeIfPresent(Bool.self, forKey: .showsCodexQuota) ?? false)
    }

    public func visibleStatuses(_ statuses: [SessionStatus], at now: Date) -> [SessionStatus] {
        guard now.timeIntervalSince1970.isFinite else { return [] }
        return statuses.filter { status in
            guard status.freshness != .expired else { return false }
            switch status.session.phase {
            case .working, .needsInput: return true // Unresolved state is retained.
            case .completed, .failed, .interrupted, .ended:
                let limit = status.session.phase == .ended ? min(historyVisibility.rawValue, 3600) : historyVisibility.rawValue
                return now.timeIntervalSince(status.session.updatedAt) < Double(limit)
            }
        }
    }

    public func projectName(for status: SessionStatus) -> String {
        reminders.showsProjectName ? status.session.projectName : "开发会话"
    }
}

public enum AppPreferenceProblem: String, Error, Equatable, Sendable {
    case invalidData, unsupportedVersion, limitExceeded
}

public enum AppPreferencesCodec {
    public static let maximumBytes = 16 * 1024
    private struct Envelope: Codable {
        let kind: String
        let version: Int
        let preferences: AppPreferences
    }
    public static func encode(_ preferences: AppPreferences) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(kind: "tide-island-preferences", version: 1, preferences: preferences))
        guard data.count <= maximumBytes else { throw AppPreferenceProblem.limitExceeded }
        return data
    }
    public static func decode(_ data: Data) throws -> AppPreferences {
        guard data.count <= maximumBytes else { throw AppPreferenceProblem.limitExceeded }
        do {
            struct Header: Decodable { let kind: String; let version: Int }
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.kind == "tide-island-preferences" else { throw AppPreferenceProblem.invalidData }
            guard header.version == 1 else { throw AppPreferenceProblem.unsupportedVersion }
            return try JSONDecoder().decode(Envelope.self, from: data).preferences
        } catch let error as AppPreferenceProblem { throw error }
        catch { throw AppPreferenceProblem.invalidData }
    }
}

/// The host keeps original bytes in its storage when reading fails. Ordinary
/// edits cannot replace them; only the explicit reset operation unlocks writes.
public struct AppPreferenceDocument: Sendable {
    public private(set) var preferences: AppPreferences
    public private(set) var problem: AppPreferenceProblem?
    public init(data: Data?) {
        do { preferences = try data.map(AppPreferencesCodec.decode) ?? AppPreferences() }
        catch {
            preferences = AppPreferences(reminders: .init(showsProjectName: false), historyVisibility: .oneHour)
            problem = (error as? AppPreferenceProblem) ?? .invalidData
        }
    }
    public mutating func updating(_ value: AppPreferences) throws -> Data {
        if let problem { throw problem }
        let data = try AppPreferencesCodec.encode(value)
        preferences = value
        return data
    }
    public mutating func resetting(to value: AppPreferences = .init()) throws -> Data {
        let data = try AppPreferencesCodec.encode(value)
        preferences = value; problem = nil
        return data
    }
}
