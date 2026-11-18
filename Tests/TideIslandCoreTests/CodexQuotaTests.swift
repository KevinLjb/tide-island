import Foundation
import Testing
@testable import TideIslandCore

private let quotaEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func codexQuotaMapsAWeeklyPrimaryWithoutInventingAShortWindow() throws {
    let quota = try quotaSnapshot(primary: #"{"usedPercent":28,"windowDurationMins":10080,"resetsAt":1800007200}"#)
    let windows = quota.windows(at: quotaEpoch)
    #expect(windows.map(\.title) == ["7 天"])
    #expect(windows.map(\.remainingPercent) == [72])
    #expect(windows.first?.resetsAt == quotaEpoch.addingTimeInterval(7200))
}

@Test func codexQuotaPrefersCodexBucketAndIgnoresOtherBuckets() throws {
    let raw = #"{"id":2,"result":{"rateLimits":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"other":"unexpected data","codex":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300}}}}}"#
    let snapshot = try CodexQuotaSnapshot.decodeResponse(Data(raw.utf8), requestID: 2, checkedAt: quotaEpoch)
    #expect(snapshot.windows(at: quotaEpoch).map(\.remainingPercent) == [90])
    let otherOnly = raw.replacingOccurrences(of: "\"codex\":{", with: "\"other_2\":{")
    #expect(throws: CodexQuotaProblem.unavailable) {
        try CodexQuotaSnapshot.decodeResponse(Data(otherOnly.utf8), requestID: 2, checkedAt: quotaEpoch)
    }
    #expect(throws: CodexQuotaProblem.invalidResponse) {
        try CodexQuotaSnapshot.decodeResponse(Data(raw.utf8), requestID: 3, checkedAt: quotaEpoch)
    }
}

@Test func codexQuotaHidesResetAndExpiredReadingsWithoutInventingRecovery() throws {
    let quota = try quotaSnapshot(primary: #"{"usedPercent":117,"windowDurationMins":10080}"#,
                                  secondary: #"{"usedPercent":64,"windowDurationMins":300,"resetsAt":1800000030}"#)
    #expect(quota.windows(at: quotaEpoch).map(\.remainingPercent) == [36, 0])
    #expect(quota.windows(at: quotaEpoch.addingTimeInterval(30)).map(\.minutes) == [10080])
    #expect(quota.windows(at: quotaEpoch.addingTimeInterval(600)).isEmpty)
    #expect(quota.windows(at: quotaEpoch.addingTimeInterval(-1)).isEmpty)
    #expect(quota.displayBoundaries == [quotaEpoch.addingTimeInterval(30), quotaEpoch.addingTimeInterval(600)])
}

@Test func codexQuotaUnknownDurationsAndErrorsStayUnavailable() throws {
    for window in [#"{"usedPercent":12}"#, #"{"usedPercent":-1,"windowDurationMins":300}"#,
                   #"{"usedPercent":12,"windowDurationMins":300,"resetsAt":1799999999}"#] {
        #expect(throws: CodexQuotaProblem.unavailable) { try quotaSnapshot(primary: window) }
    }
    #expect(throws: CodexQuotaProblem.unavailable) {
        try CodexQuotaSnapshot.decodeResponse(Data(#"{"id":2,"error":{"code":-32600,"message":"test"}}"#.utf8),
                                               requestID: 2, checkedAt: quotaEpoch)
    }
}

@Test func codexQuotaIsOptionalAndCorruptExtrasDoNotDropExistingActivity() throws {
    let quota = try quotaSnapshot(primary: #"{"usedPercent":60,"windowDurationMins":300}"#)
    let old = IslandActivityContent(sessionID: "session", projectName: "project", phase: .working,
                                    workingCount: 1, waitingCount: 0, updatedAt: quotaEpoch)
    let new = IslandActivityContent(sessionID: old.sessionID, projectName: old.projectName, phase: old.phase,
                                    workingCount: 1, waitingCount: 0, updatedAt: quotaEpoch, codexQuota: quota)
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    let encoded = try encoder.encode(new)
    #expect(try decoder.decode(IslandActivityContent.self, from: encoded) == new)
    #expect(try decoder.decode(IslandActivityContent.self, from: encoder.encode(old)) == old)
    var corrupt = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    corrupt["codexQuota"] = ["windows": ["bad"]]
    let decoded = try decoder.decode(IslandActivityContent.self, from: JSONSerialization.data(withJSONObject: corrupt))
    #expect(decoded == old)
}

@Test func quotaPreferenceDecodesOlderRecordsAsOffAndKeepsOtherChoices() throws {
    let original = AppPreferences(reminders: .init(showsProjectName: false), historyVisibility: .sixHours, launchAtLogin: true)
    var envelope = try #require(JSONSerialization.jsonObject(with: AppPreferencesCodec.encode(original)) as? [String: Any])
    var preferences = try #require(envelope["preferences"] as? [String: Any])
    preferences.removeValue(forKey: "showsCodexQuota")
    envelope["preferences"] = preferences
    var decoded = try AppPreferencesCodec.decode(JSONSerialization.data(withJSONObject: envelope))
    #expect(decoded == original && !decoded.showsCodexQuota)
    decoded.showsCodexQuota = true
    #expect(try AppPreferencesCodec.decode(AppPreferencesCodec.encode(decoded)) == decoded)
}

private func quotaSnapshot(primary: String, secondary: String = "null") throws -> CodexQuotaSnapshot {
    let json = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":\#(primary),"secondary":\#(secondary)}}}"#
    return try CodexQuotaSnapshot.decodeResponse(Data(json.utf8), requestID: 2, checkedAt: quotaEpoch)
}
