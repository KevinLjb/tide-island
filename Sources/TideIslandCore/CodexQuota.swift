import Foundation

public enum CodexQuotaProblem: Error, Equatable, Sendable {
    case invalidResponse, unavailable
}

public struct CodexQuotaWindow: Codable, Hashable, Sendable, Identifiable {
    public let minutes: Int
    public let remainingPercent: Int
    public let resetsAt: Date?

    public var id: Int { minutes }

    public var title: String {
        if minutes.isMultiple(of: 1440) { return "\(minutes / 1440) 天" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    fileprivate var isValid: Bool {
        (1...44_640).contains(minutes) && (0...100).contains(remainingPercent) &&
        resetsAt.map { CodexQuotaSnapshot.validDate($0) } != false
    }
}

/// Only the account's Codex quota windows and the time of this read travel to
/// WidgetKit. Account IDs, subscription details and the RPC response stay out.
public struct CodexQuotaSnapshot: Codable, Hashable, Sendable {
    public static let refreshInterval: TimeInterval = 5 * 60
    public static let maximumAge: TimeInterval = 2 * refreshInterval
    public static let maximumResponseBytes = 64 * 1024

    public let checkedAt: Date
    private let windows: [CodexQuotaWindow]

    public func windows(at now: Date) -> [CodexQuotaWindow] {
        let age = now.timeIntervalSince(checkedAt)
        guard age >= 0, age < Self.maximumAge else { return [] }
        return windows.filter { $0.resetsAt.map { $0 > now } != false }
    }

    public var displayBoundaries: [Date] {
        let expiresAt = checkedAt.addingTimeInterval(Self.maximumAge)
        return (windows.compactMap(\.resetsAt).filter { $0 > checkedAt && $0 < expiresAt } + [expiresAt]).sorted()
    }

    public static func decodeResponse(_ data: Data, requestID: Int, checkedAt: Date) throws -> Self {
        guard data.count <= maximumResponseBytes else { throw CodexQuotaProblem.invalidResponse }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw CodexQuotaProblem.invalidResponse }
        guard response.id == requestID else { throw CodexQuotaProblem.invalidResponse }
        guard let bucket = response.result?.bucket, bucket.limitId == nil || bucket.limitId == "codex" else {
            throw CodexQuotaProblem.unavailable
        }
        let windows = [bucket.primary, bucket.secondary].compactMap { $0?.window }
        let snapshot = try Self(checkedAt: checkedAt, windows: windows)
        guard !snapshot.windows(at: checkedAt).isEmpty else { throw CodexQuotaProblem.unavailable }
        return snapshot
    }

    private enum CodingKeys: String, CodingKey { case checkedAt, windows }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(checkedAt: fields.decode(Date.self, forKey: .checkedAt),
                      windows: fields.decode([CodexQuotaWindow].self, forKey: .windows))
    }

    private init(checkedAt: Date, windows: [CodexQuotaWindow]) throws {
        guard Self.validDate(checkedAt), windows.count <= 2, windows.allSatisfy(\.isValid),
              Set(windows.map(\.minutes)).count == windows.count else { throw CodexQuotaProblem.invalidResponse }
        self.checkedAt = checkedAt
        self.windows = windows.sorted { $0.minutes < $1.minutes }
    }

    fileprivate static func validDate(_ date: Date) -> Bool {
        (0...4_102_444_800).contains(date.timeIntervalSince1970)
    }

    private struct Response: Decodable {
        let id: Int
        let result: Result?
    }

    private struct Result: Decodable {
        private struct Buckets: Decodable { let codex: Bucket? }
        private enum CodingKeys: String, CodingKey { case rateLimitsByLimitId, rateLimits }
        let bucket: Bucket?

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            if let buckets = try fields.decodeIfPresent(Buckets.self, forKey: .rateLimitsByLimitId) {
                bucket = buckets.codex
            } else {
                bucket = try fields.decodeIfPresent(Bucket.self, forKey: .rateLimits)
            }
        }
    }

    private struct Bucket: Decodable {
        let limitId: String?
        let primary: RateLimit?
        let secondary: RateLimit?
    }

    private struct RateLimit: Decodable {
        let usedPercent: Int
        let windowDurationMins: Int?
        let resetsAt: Int64?

        var window: CodexQuotaWindow? {
            guard let windowDurationMins, usedPercent >= 0 else { return nil }
            let date = resetsAt.map { Date(timeIntervalSince1970: Double($0)) }
            let window = CodexQuotaWindow(minutes: windowDurationMins, remainingPercent: 100 - min(100, usedPercent), resetsAt: date)
            return window.isValid ? window : nil
        }
    }
}
