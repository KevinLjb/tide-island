import Foundation

/// A conservative, byte-preserving editor for one top-level setting. This is
/// not a general TOML validator. Other values are lexically skipped (including
/// multiline strings / nested arrays), never decoded or reserialized.
struct TOMLNotifyDocument {
    let data: Data
    let arguments: [String]?
    private let valueRange: Range<Int>?
    private let assignmentRange: Range<Int>?

    init(data: Data) throws {
        guard data.count <= CodexNotifyConfiguration.maximumBytes else { throw NotifyConfigurationError.limitExceeded }
        guard String(data: data, encoding: .utf8) != nil, !data.contains(0), !data.starts(with: [0xEF, 0xBB, 0xBF]) else {
            throw NotifyConfigurationError.invalidDocument
        }
        var scanner = TOMLNotifyScanner(bytes: Array(data))
        let ranges = try scanner.findNotify()
        self.data = data; valueRange = ranges?.value; assignmentRange = ranges?.assignment
        if let ranges {
            var value = TOMLNotifyScanner(bytes: Array(data[ranges.value]))
            arguments = try value.stringArray()
        } else { arguments = nil }
    }

    func replacing(with arguments: [String]) throws -> Data {
        let value = Data(Self.render(arguments).utf8)
        let result: Data
        if let valueRange { result = data.prefix(valueRange.lowerBound) + value + data.suffix(from: valueRange.upperBound) }
        else { result = Data("notify = ".utf8) + value + Data([10]) + data }
        guard result.count <= CodexNotifyConfiguration.maximumBytes else { throw NotifyConfigurationError.limitExceeded }
        return result
    }

    func removing() -> Data {
        guard let assignmentRange else { return data }
        // Leave a trailing comment / newline intact; do not delete a whole
        // configuration file just because our inserted setting was its only key.
        return data.prefix(assignmentRange.lowerBound) + data.suffix(from: assignmentRange.upperBound)
    }

    static func render(_ arguments: [String]) -> String {
        "[" + arguments.map { value in
            var encoded = "\""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 34: encoded += "\\\""
                case 92: encoded += "\\\\"
                case 8: encoded += "\\b"
                case 9: encoded += "\\t"
                case 10: encoded += "\\n"
                case 12: encoded += "\\f"
                case 13: encoded += "\\r"
                case 0...31, 127: encoded += String(format: "\\u%04X", scalar.value)
                default: encoded.unicodeScalars.append(scalar)
                }
            }
            return encoded + "\""
        }.joined(separator: ", ") + "]"
    }
}

private struct TOMLNotifyScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func findNotify() throws -> (value: Range<Int>, assignment: Range<Int>)? {
        var isRoot = true
        var result: (value: Range<Int>, assignment: Range<Int>)?
        while true {
            skipSpaceAndComments()
            guard index < bytes.count else { return result }
            if bytes[index] == 91 {
                index += 1
                let arrayTable = consume(91)
                let keys = try keyPath(until: 93)
                guard consume(93), !arrayTable || consume(93) else { throw NotifyConfigurationError.invalidDocument }
                skipHorizontal()
                guard index == bytes.count || [10, 13, 35].contains(bytes[index]) else { throw NotifyConfigurationError.invalidDocument }
                if keys.first == "notify" { throw NotifyConfigurationError.unsupportedNotify }
                isRoot = false
                continue
            }
            let assignmentStart = index
            let keys = try keyPath(until: 61)
            guard consume(61) else { throw NotifyConfigurationError.invalidDocument }
            skipHorizontal()
            let start = index
            let end = try skipValue()
            if isRoot && keys.first == "notify" {
                guard keys.count == 1, result == nil else { throw NotifyConfigurationError.unsupportedNotify }
                result = (start..<end, assignmentStart..<end)
            }
        }
    }

    mutating func stringArray() throws -> [String] {
        skipSpaceAndComments()
        guard consume(91) else { throw NotifyConfigurationError.unsupportedNotify }
        var result: [String] = []
        skipSpaceAndComments()
        if consume(93) { try requireEnd(); return result }
        while true {
            guard result.count < NotifyDispatchConfiguration.maximumArguments else { throw NotifyConfigurationError.limitExceeded }
            result.append(try string())
            skipSpaceAndComments()
            if consume(93) { break }
            guard consume(44) else { throw NotifyConfigurationError.unsupportedNotify }
            skipSpaceAndComments()
            if consume(93) { break }
        }
        try requireEnd()
        guard result.reduce(0, { $0 + $1.utf8.count }) <= NotifyDispatchConfiguration.maximumArgumentBytes,
              result.first.map({ !$0.isEmpty }) != false, result.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw NotifyConfigurationError.unsupportedNotify
        }
        return result
    }

    private mutating func requireEnd() throws {
        skipSpaceAndComments()
        guard index == bytes.count else { throw NotifyConfigurationError.unsupportedNotify }
    }

    private mutating func keyPath(until terminator: UInt8) throws -> [String] {
        var result: [String] = []
        while true {
            skipHorizontal()
            guard index < bytes.count, result.count < 64 else { throw NotifyConfigurationError.invalidDocument }
            if bytes[index] == 34 || bytes[index] == 39 { result.append(try string()) }
            else {
                let start = index
                while index < bytes.count, Self.isBareKey(bytes[index]) { index += 1 }
                guard index > start else { throw NotifyConfigurationError.invalidDocument }
                result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            }
            skipHorizontal()
            if index < bytes.count, bytes[index] == terminator { return result }
            guard consume(46) else { throw NotifyConfigurationError.invalidDocument }
        }
    }

    private mutating func skipValue() throws -> Int {
        let start = index
        var stack: [UInt8] = []
        var quote: UInt8?
        var multiline = false
        while index < bytes.count {
            let byte = bytes[index]
            if let active = quote {
                if active == 34 && byte == 92 {
                    guard index + 1 < bytes.count else { throw NotifyConfigurationError.invalidDocument }
                    if !multiline && [10, 13].contains(bytes[index + 1]) { throw NotifyConfigurationError.invalidDocument }
                    index += 2; continue
                }
                if byte == active {
                    var count = 1
                    while index + count < bytes.count && bytes[index + count] == active { count += 1 }
                    if !multiline { index += 1; quote = nil; continue }
                    if count >= 3 {
                        guard count <= 5 else { throw NotifyConfigurationError.invalidDocument }
                        index += count; quote = nil; multiline = false; continue
                    }
                }
                guard multiline || ![10, 13].contains(byte) else { throw NotifyConfigurationError.invalidDocument }
                index += 1; continue
            }
            if byte == 34 || byte == 39 {
                quote = byte
                multiline = index + 2 < bytes.count && bytes[index + 1] == byte && bytes[index + 2] == byte
                index += multiline ? 3 : 1
                continue
            }
            if byte == 35 {
                if stack.isEmpty { break }
                while index < bytes.count && ![10, 13].contains(bytes[index]) { index += 1 }
                continue
            }
            if [10, 13].contains(byte) && stack.isEmpty { break }
            if byte == 91 || byte == 123 {
                guard stack.count < 64 else { throw NotifyConfigurationError.limitExceeded }
                stack.append(byte)
            } else if byte == 93 || byte == 125 {
                guard let opening = stack.popLast(), (opening == 91 && byte == 93) || (opening == 123 && byte == 125) else {
                    throw NotifyConfigurationError.invalidDocument
                }
            }
            index += 1
        }
        guard quote == nil, stack.isEmpty else { throw NotifyConfigurationError.invalidDocument }
        var end = index
        while end > start && [9, 32].contains(bytes[end - 1]) { end -= 1 }
        guard end > start else { throw NotifyConfigurationError.invalidDocument }
        return end
    }

    private mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 34 || bytes[index] == 39 else { throw NotifyConfigurationError.unsupportedNotify }
        let quote = bytes[index]; index += 1
        guard !(index + 1 < bytes.count && bytes[index] == quote && bytes[index + 1] == quote) else { throw NotifyConfigurationError.unsupportedNotify }
        var result: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == quote {
                guard let value = String(bytes: result, encoding: .utf8) else { throw NotifyConfigurationError.invalidDocument }
                return value
            }
            guard byte >= 32 || byte == 9, byte != 127 else { throw NotifyConfigurationError.invalidDocument }
            if quote == 34 && byte == 92 {
                guard index < bytes.count else { throw NotifyConfigurationError.invalidDocument }
                let escape = bytes[index]; index += 1
                let mappings: [UInt8: UInt8] = [34: 34, 92: 92, 98: 8, 116: 9, 110: 10, 102: 12, 114: 13]
                if let mapped = mappings[escape] { result.append(mapped) }
                else if escape == 117 || escape == 85 {
                    let length = escape == 117 ? 4 : 8
                    guard index + length <= bytes.count,
                          let number = UInt32(String(decoding: bytes[index..<(index + length)], as: UTF8.self), radix: 16),
                          let scalar = UnicodeScalar(number) else { throw NotifyConfigurationError.invalidDocument }
                    result.append(contentsOf: String(scalar).utf8); index += length
                } else { throw NotifyConfigurationError.invalidDocument }
            } else { result.append(byte) }
        }
        throw NotifyConfigurationError.invalidDocument
    }

    private mutating func skipHorizontal() { while index < bytes.count && [9, 32].contains(bytes[index]) { index += 1 } }
    private mutating func skipSpaceAndComments() {
        while index < bytes.count {
            if [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
            else if bytes[index] == 35 { while index < bytes.count && ![10, 13].contains(bytes[index]) { index += 1 } }
            else { return }
        }
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
    private static func isBareKey(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
    }
}
