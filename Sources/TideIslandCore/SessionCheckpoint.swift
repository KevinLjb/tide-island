import Foundation

public enum SessionStateError: String, Error, LocalizedError, Sendable {
    case invalidData, unsupportedVersion, scopeMismatch, limitExceeded
    case unsafePath, conflict, busy, fileOperation

    public var errorDescription: String? {
        switch self {
        case .invalidData: "Saved session metadata is invalid; the original file was preserved."
        case .unsupportedVersion: "Saved session metadata uses an unsupported version; the original file was preserved."
        case .scopeMismatch: "Saved session metadata belongs to a different inbox."
        case .limitExceeded: "Saved session metadata exceeds the bounded storage limits."
        case .unsafePath: "The saved session path or file is unsafe."
        case .conflict: "Saved session metadata changed; no stale data was written."
        case .busy: "Saved session metadata is busy; retry later."
        case .fileOperation: "Saved session metadata could not be read or written."
        }
    }
}

public struct SessionStateRevision: Equatable, Sendable {
    public let fingerprint: String
}

public struct SessionStateSnapshot: Sendable {
    public let store: SessionStore
    public let revision: SessionStateRevision
    public let existed: Bool
    let importIndex: [String: String]
}

public enum SessionPersistencePhase: String, Sendable {
    case disabled, loading, saved, pending, unavailable
}

public struct SessionPersistenceStatus: Equatable, Sendable {
    public internal(set) var phase: SessionPersistencePhase = .disabled
    public internal(set) var problem: SessionStateError?

    public var message: String? {
        guard phase == .unavailable else { return nil }
        switch problem {
        case .invalidData, .unsupportedVersion, .scopeMismatch:
            return "保存的会话数据无法安全恢复，原文件已保留；请检查后重试，或预览清除会话与偏好。"
        case .conflict:
            return "保存的会话数据已被外部修改，未覆盖文件；当前操作可能尚未保存，请重新启动或预览清除。"
        case .limitExceeded:
            return "会话恢复数据超过保存上限，未截断状态；当前操作尚未保存，可预览清除已有记录。"
        default:
            return "会话恢复数据暂不可读写；当前操作可能尚未保存，请检查访问权限后重试。"
        }
    }
}

struct SessionCheckpoint: Codable {
    let kind: String
    let version: Int
    let scope: String
    let store: SessionStore.PersistedState
    let importIndex: [String: String]
}

enum SessionCheckpointCodec {
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumSessions = 2048
    static let maximumFiles = 65_536

    static func encode(store: SessionStore, index: [String: String], scope: String) throws -> Data {
        do {
            let persisted = store.persistedState()
            _ = try SessionStore(persisted: persisted)
            try validateIndex(index)
            let checkpoint = SessionCheckpoint(kind: "tide-island-session-state", version: 1, scope: scope,
                                               store: persisted, importIndex: index)
            let encoder = JSONEncoder()
            // Date's native numeric representation preserves the exact source
            // observation; the event wire format remains unchanged.
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(checkpoint)
            guard data.count <= maximumBytes else { throw SessionStateError.limitExceeded }
            return data
        } catch let error as SessionStateError { throw error }
        catch { throw SessionStateError.invalidData }
    }

    static func decode(_ data: Data, scope: String) throws -> (store: SessionStore, index: [String: String]) {
        guard data.count <= maximumBytes else { throw SessionStateError.limitExceeded }
        do {
            struct Header: Decodable { let version: Int }
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == 1 else { throw SessionStateError.unsupportedVersion }
            let checkpoint = try decoder.decode(SessionCheckpoint.self, from: data)
            guard checkpoint.kind == "tide-island-session-state" else { throw SessionStateError.invalidData }
            guard checkpoint.scope == scope else { throw SessionStateError.scopeMismatch }
            try validateIndex(checkpoint.importIndex)
            return (try SessionStore(persisted: checkpoint.store), checkpoint.importIndex)
        } catch let error as SessionStateError { throw error }
        catch { throw SessionStateError.invalidData }
    }

    static func validateIdentifier(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SessionStateError.invalidData
        }
    }

    private static func validateIndex(_ index: [String: String]) throws {
        guard index.count <= maximumFiles else { throw SessionStateError.limitExceeded }
        for (name, digest) in index {
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil,
                  digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw SessionStateError.invalidData
            }
        }
    }
}
