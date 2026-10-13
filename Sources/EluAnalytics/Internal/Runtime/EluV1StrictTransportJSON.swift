import Foundation

enum EluV1StrictTransportJSONError: Error, Equatable, Sendable {
    case malformed
    case duplicateKey
    case nestingLimitExceeded
    case collectionLimitExceeded
}

indirect enum EluV1StrictTransportJSONValue: Equatable, Sendable {
    case object([String: EluV1StrictTransportJSONValue])
    case array([EluV1StrictTransportJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    var objectValue: [String: EluV1StrictTransportJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [EluV1StrictTransportJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var int64Value: Int64? {
        guard case let .number(value) = self,
              !value.contains("."),
              !value.contains("e"),
              !value.contains("E")
        else {
            return nil
        }
        return Int64(value)
    }
}

/// A small strict JSON reader for acknowledgement and error responses. Foundation's
/// keyed decoders intentionally collapse duplicate object keys, which is unsafe at
/// the queue-deletion boundary. This reader rejects duplicates before any semantic
/// field is trusted.
enum EluV1StrictTransportJSON {
    static let maximumNestingDepth = 32
    static let maximumCollectionEntries = 2_048

    static func parse(_ data: Data) throws -> EluV1StrictTransportJSONValue {
        guard !data.isEmpty else {
            throw EluV1StrictTransportJSONError.malformed
        }
        var parser = Parser(bytes: Array(data))
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw EluV1StrictTransportJSONError.malformed
        }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                default:
                    return
                }
            }
        }

        mutating func parseValue(depth: Int) throws -> EluV1StrictTransportJSONValue {
            guard depth <= EluV1StrictTransportJSON.maximumNestingDepth else {
                throw EluV1StrictTransportJSONError.nestingLimitExceeded
            }
            skipWhitespace()
            guard index < bytes.count else {
                throw EluV1StrictTransportJSONError.malformed
            }
            switch bytes[index] {
            case 0x7B:
                return try parseObject(depth: depth)
            case 0x5B:
                return try parseArray(depth: depth)
            case 0x22:
                return .string(try parseString())
            case 0x74:
                try consumeLiteral("true")
                return .bool(true)
            case 0x66:
                try consumeLiteral("false")
                return .bool(false)
            case 0x6E:
                try consumeLiteral("null")
                return .null
            case 0x2D, 0x30 ... 0x39:
                return .number(try parseNumber())
            default:
                throw EluV1StrictTransportJSONError.malformed
            }
        }

        mutating func parseObject(depth: Int) throws -> EluV1StrictTransportJSONValue {
            try consume(0x7B)
            skipWhitespace()
            if consumeIfPresent(0x7D) {
                return .object([:])
            }

            var result: [String: EluV1StrictTransportJSONValue] = [:]
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw EluV1StrictTransportJSONError.malformed
                }
                let key = try parseString()
                guard result[key] == nil else {
                    throw EluV1StrictTransportJSONError.duplicateKey
                }
                skipWhitespace()
                try consume(0x3A)
                let value = try parseValue(depth: depth + 1)
                result[key] = value
                guard result.count <= EluV1StrictTransportJSON.maximumCollectionEntries else {
                    throw EluV1StrictTransportJSONError.collectionLimitExceeded
                }
                skipWhitespace()
                if consumeIfPresent(0x7D) {
                    return .object(result)
                }
                try consume(0x2C)
            }
        }

        mutating func parseArray(depth: Int) throws -> EluV1StrictTransportJSONValue {
            try consume(0x5B)
            skipWhitespace()
            if consumeIfPresent(0x5D) {
                return .array([])
            }

            var result: [EluV1StrictTransportJSONValue] = []
            while true {
                result.append(try parseValue(depth: depth + 1))
                guard result.count <= EluV1StrictTransportJSON.maximumCollectionEntries else {
                    throw EluV1StrictTransportJSONError.collectionLimitExceeded
                }
                skipWhitespace()
                if consumeIfPresent(0x5D) {
                    return .array(result)
                }
                try consume(0x2C)
            }
        }

        mutating func parseString() throws -> String {
            let start = index
            try consume(0x22)
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if escaped {
                    escaped = false
                    index += 1
                    continue
                }
                if byte == 0x5C {
                    escaped = true
                    index += 1
                    continue
                }
                if byte == 0x22 {
                    index += 1
                    let token = Data(bytes[start ..< index])
                    do {
                        return try JSONDecoder().decode(String.self, from: token)
                    } catch {
                        throw EluV1StrictTransportJSONError.malformed
                    }
                }
                guard byte >= 0x20 else {
                    throw EluV1StrictTransportJSONError.malformed
                }
                index += 1
            }
            throw EluV1StrictTransportJSONError.malformed
        }

        mutating func parseNumber() throws -> String {
            let start = index
            _ = consumeIfPresent(0x2D)
            guard index < bytes.count else {
                throw EluV1StrictTransportJSONError.malformed
            }
            if consumeIfPresent(0x30) {
                if index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                    throw EluV1StrictTransportJSONError.malformed
                }
            } else {
                guard (0x31 ... 0x39).contains(bytes[index]) else {
                    throw EluV1StrictTransportJSONError.malformed
                }
                index += 1
                while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                    index += 1
                }
            }

            if consumeIfPresent(0x2E) {
                guard index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) else {
                    throw EluV1StrictTransportJSONError.malformed
                }
                while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                    index += 1
                }
            }

            if index < bytes.count, (bytes[index] == 0x65 || bytes[index] == 0x45) {
                index += 1
                if index < bytes.count, (bytes[index] == 0x2B || bytes[index] == 0x2D) {
                    index += 1
                }
                guard index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) else {
                    throw EluV1StrictTransportJSONError.malformed
                }
                while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                    index += 1
                }
            }

            guard let result = String(bytes: bytes[start ..< index], encoding: .utf8) else {
                throw EluV1StrictTransportJSONError.malformed
            }
            return result
        }

        mutating func consumeLiteral(_ literal: StaticString) throws {
            let expected = Array(String(describing: literal).utf8)
            guard index <= bytes.count - expected.count,
                  Array(bytes[index ..< (index + expected.count)]) == expected
            else {
                throw EluV1StrictTransportJSONError.malformed
            }
            index += expected.count
        }

        mutating func consume(_ byte: UInt8) throws {
            guard consumeIfPresent(byte) else {
                throw EluV1StrictTransportJSONError.malformed
            }
        }

        mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
