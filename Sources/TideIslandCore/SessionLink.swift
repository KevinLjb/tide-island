import Foundation

public enum SessionLink {
    public static func url(for sessionID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "tide-island"
        components.host = "session"
        components.queryItems = [URLQueryItem(name: "id", value: sessionID)]
        return components.url
    }

    public static func sessionID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "tide-island", components.host == "session",
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "id", let value = items[0].value, !value.isEmpty
        else { return nil }
        return value
    }
}
