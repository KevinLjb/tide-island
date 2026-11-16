import Foundation

func codexHookFixtures() throws -> [[String: Any]] {
    guard let url = Bundle.module.url(forResource: "lifecycle", withExtension: "json", subdirectory: "Fixtures/Codex"),
          let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
          let fixtures = document["fixtures"] as? [[String: Any]] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return fixtures
}

func codexFixturePayload(named name: String) throws -> [String: Any] {
    let fixtures = try codexHookFixtures()
    guard let fixture = fixtures.first(where: { $0["name"] as? String == name }),
          let payload = fixture["payload"] as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return payload
}
