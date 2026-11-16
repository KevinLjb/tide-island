import Foundation

public enum SessionLinkError: String, Error, Equatable, Sendable {
    case invalidLink, sessionUnavailable, ambiguousSession

    public var message: String {
        switch self {
        case .invalidLink: "这个会话链接无效。"
        case .sessionUnavailable: "链接对应的会话已不可用，请从当前列表选择。"
        case .ambiguousSession: "无法唯一确认链接对应的会话，请从当前列表选择。"
        }
    }
}

public enum SessionLink {
    public static func url(for sessionID: String) -> URL? {
        guard validID(sessionID) else { return nil }
        var components = URLComponents()
        components.scheme = "tide-island"
        components.host = "session"
        components.queryItems = [URLQueryItem(name: "id", value: sessionID)]
        return components.url
    }

    public static func sessionID(from url: URL) -> String? {
        guard url.absoluteString.utf8.count <= 4096,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "tide-island", components.host == "session",
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "id", let value = items[0].value, validID(value)
        else { return nil }
        return value
    }

    public static func resolve(_ url: URL, in snapshot: SessionSnapshot, at now: Date) -> Result<SessionReference, SessionLinkError> {
        guard let id = sessionID(from: url) else { return .failure(.invalidLink) }
        let matches = snapshot.sessions.filter { $0.id == id }
        guard matches.count <= 1 else { return .failure(.ambiguousSession) }
        guard let status = matches.first, isCurrent(status.reference, in: snapshot, at: now) else {
            return .failure(.sessionUnavailable)
        }
        return .success(status.reference)
    }

    static func isCurrent(_ reference: SessionReference, in snapshot: SessionSnapshot, at now: Date) -> Bool {
        let matches = snapshot.sessions.filter { $0.id == reference.sessionID }
        guard now.timeIntervalSince1970.isFinite, matches.count == 1, let status = matches.first else { return false }
        return status.reference == reference && !status.attention.isIgnored && status.freshness != .expired &&
            status.expiresAt.map({ now < $0 }) != false
    }

    private static func validID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256 &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
