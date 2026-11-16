import Foundation

/// Configuration editing must retain unknown fields and exact number tokens.
/// Duplicate keys are rejected rather than silently discarding a user's hook.
indirect enum ConfigurationJSON: Equatable {
    case object([String: ConfigurationJSON])
    case array([ConfigurationJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    var object: [String: ConfigurationJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var array: [ConfigurationJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    static func decode(_ data: Data) throws -> ConfigurationJSON {
        guard data.count <= CodexHookConfiguration.maximumBytes else { throw HookConfigurationError.invalidConfiguration }
        var parser = Parser(bytes: Array(data))
        let result = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw HookConfigurationError.invalidConfiguration }
        return result
    }

    func encode() throws -> Data {
        let data = Data(try (render(depth: 0) + "\n").utf8)
        guard data.count <= CodexHookConfiguration.maximumBytes else { throw HookConfigurationError.invalidConfiguration }
        return data
    }

    private func render(depth: Int) throws -> String {
        let indent = String(repeating: "  ", count: depth)
        let nextIndent = indent + "  "
        switch self {
        case .object(let values):
            if values.isEmpty { return "{}" }
            let entries = try values.keys.sorted().map { key in
                nextIndent + (try Self.quote(key)) + ": " + (try values[key]!.render(depth: depth + 1))
            }
            return "{\n" + entries.joined(separator: ",\n") + "\n" + indent + "}"
        case .array(let values):
            if values.isEmpty { return "[]" }
            let entries = try values.map { nextIndent + (try $0.render(depth: depth + 1)) }
            return "[\n" + entries.joined(separator: ",\n") + "\n" + indent + "]"
        case .string(let value): return try Self.quote(value)
        case .number(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quote(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func whitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func take(_ byte: UInt8) -> Bool {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func value(depth: Int) throws -> ConfigurationJSON {
            whitespace()
            guard depth <= 64, index < bytes.count else { throw HookConfigurationError.invalidConfiguration }
            switch bytes[index] {
            case 0x7B:
                index += 1
                var values: [String: ConfigurationJSON] = [:]
                if take(0x7D) { return .object(values) }
                while true {
                    let key = try string()
                    guard values[key] == nil, take(0x3A) else { throw HookConfigurationError.invalidConfiguration }
                    values[key] = try value(depth: depth + 1)
                    if take(0x7D) { return .object(values) }
                    guard take(0x2C) else { throw HookConfigurationError.invalidConfiguration }
                }
            case 0x5B:
                index += 1
                var values: [ConfigurationJSON] = []
                if take(0x5D) { return .array(values) }
                while true {
                    values.append(try value(depth: depth + 1))
                    if take(0x5D) { return .array(values) }
                    guard take(0x2C) else { throw HookConfigurationError.invalidConfiguration }
                }
            case 0x22: return .string(try string())
            default:
                let start = index
                while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x7D, 0x5D].contains(bytes[index]) {
                    index += 1
                }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                switch token {
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "null": return .null
                default:
                    guard token.range(of: #"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#,
                                      options: .regularExpression) != nil else {
                        throw HookConfigurationError.invalidConfiguration
                    }
                    return .number(token)
                }
            }
        }

        mutating func string() throws -> String {
            whitespace()
            let start = index
            guard take(0x22) else { throw HookConfigurationError.invalidConfiguration }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw HookConfigurationError.invalidConfiguration }
                }
                if byte == 0x5C { index += 1 }
            }
            throw HookConfigurationError.invalidConfiguration
        }
    }
}
