import CryptoKit
import Foundation

enum EluV1StrictCanonicalJSONError: Error, Equatable, Sendable {
    case invalidUTF8
    case malformed
    case duplicateObjectKey
    case unpairedSurrogate
    case excessiveNesting
    case unsupportedNumber
    case rootIsNotObject
}

/// Duplicate-safe RFC 8259 parsing plus the frozen ELU/JCS projection rules.
///
/// The parser intentionally operates on UTF-16 code units. Foundation's JSON
/// decoders and dictionary bridges are not used until duplicate decoded names,
/// lone surrogates, and exact numeric lexemes have been checked.
enum EluV1StrictCanonicalJSON {
    static let maximumNesting = 64

    struct Member: Sendable {
        let name: [UInt16]
        let value: Value
    }

    indirect enum Value: Sendable {
        case object([Member])
        case array([Value])
        case string([UInt16])
        case number(String)
        case bool(Bool)
        case null
    }

    struct Document: Sendable {
        let value: Value
        let canonicalData: Data

        var canonicalString: String {
            String(decoding: canonicalData, as: UTF8.self)
        }

        func objectProperty(_ name: String) throws -> Value? {
            guard case let .object(members) = value else {
                throw EluV1StrictCanonicalJSONError.rootIsNotObject
            }
            let units = Array(name.utf16)
            return members.first(where: { $0.name == units })?.value
        }

        func canonicalObjectProperty(_ name: String) throws -> Data? {
            guard let value = try objectProperty(name) else { return nil }
            return try EluV1StrictCanonicalJSON.canonicalData(for: value)
        }

        func canonicalRemovingObjectProperty(_ name: String) throws -> Data {
            guard case let .object(members) = value else {
                throw EluV1StrictCanonicalJSONError.rootIsNotObject
            }
            let units = Array(name.utf16)
            return try EluV1StrictCanonicalJSON.canonicalData(
                for: .object(members.filter { $0.name != units })
            )
        }
    }

    static func parse(_ data: Data) throws -> Document {
        guard let source = String(data: data, encoding: .utf8) else {
            throw EluV1StrictCanonicalJSONError.invalidUTF8
        }
        let value = try Parser(Array(source.utf16)).parse()
        return Document(value: value, canonicalData: try canonicalData(for: value))
    }

    static func canonicalData(for value: Value) throws -> Data {
        var output = String()
        try appendCanonical(value, to: &output)
        guard let data = output.data(using: .utf8) else {
            throw EluV1StrictCanonicalJSONError.unpairedSurrogate
        }
        return data
    }

    static func hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ value: Value) throws -> String {
        hash(try canonicalData(for: value))
    }

    private static func appendCanonical(_ value: Value, to output: inout String) throws {
        switch value {
        case let .object(members):
            output.append("{")
            let ordered = members.sorted { left, right in
                left.name.lexicographicallyPrecedes(right.name)
            }
            for (index, member) in ordered.enumerated() {
                if index > 0 { output.append(",") }
                try appendQuoted(member.name, to: &output)
                output.append(":")
                try appendCanonical(member.value, to: &output)
            }
            output.append("}")

        case let .array(values):
            output.append("[")
            for (index, child) in values.enumerated() {
                if index > 0 { output.append(",") }
                try appendCanonical(child, to: &output)
            }
            output.append("]")

        case let .string(units):
            try appendQuoted(units, to: &output)

        case let .number(token):
            output.append(try canonicalNumber(token))

        case let .bool(value):
            output.append(value ? "true" : "false")

        case .null:
            output.append("null")
        }
    }

    private static func appendQuoted(_ units: [UInt16], to output: inout String) throws {
        try validateScalarSequence(units)
        output.append("\"")
        var index = 0
        while index < units.count {
            let unit = units[index]
            switch unit {
            case 0x08: output.append("\\b")
            case 0x09: output.append("\\t")
            case 0x0A: output.append("\\n")
            case 0x0C: output.append("\\f")
            case 0x0D: output.append("\\r")
            case 0x22: output.append("\\\"")
            case 0x5C: output.append("\\\\")
            case 0x00 ... 0x1F:
                output.append(String(format: "\\u%04x", unit))
            case 0xD800 ... 0xDBFF:
                output.append(String(decoding: units[index ... index + 1], as: UTF16.self))
                index += 1
            default:
                output.append(String(decoding: CollectionOfOne(unit), as: UTF16.self))
            }
            index += 1
        }
        output.append("\"")
    }

    private static func validateScalarSequence(_ units: [UInt16]) throws {
        var index = 0
        while index < units.count {
            switch units[index] {
            case 0xD800 ... 0xDBFF:
                guard index + 1 < units.count,
                      (0xDC00 ... 0xDFFF).contains(units[index + 1])
                else {
                    throw EluV1StrictCanonicalJSONError.unpairedSurrogate
                }
                index += 2
            case 0xDC00 ... 0xDFFF:
                throw EluV1StrictCanonicalJSONError.unpairedSurrogate
            default:
                index += 1
            }
        }
    }

    private static func canonicalNumber(_ token: String) throws -> String {
        if let exactInteger = exactInt64Canonical(token) {
            return exactInteger
        }
        guard let value = Double(token), value.isFinite else {
            throw EluV1StrictCanonicalJSONError.unsupportedNumber
        }
        if value == 0 { return "0" }
        return try canonicalBinary64(value)
    }

    /// Classifies mathematical integrality from the original token, before a
    /// binary64 conversion can round 2^53+1 or either signed Int64 boundary.
    private static func exactInt64Canonical(_ token: String) -> String? {
        var unsigned = token
        let negative = unsigned.first == "-"
        if negative { unsigned.removeFirst() }

        let exponentIndex = unsigned.firstIndex(where: { $0 == "e" || $0 == "E" })
        let coefficient = exponentIndex.map { String(unsigned[..<$0]) } ?? unsigned
        let exponentText = exponentIndex.map { String(unsigned[unsigned.index(after: $0)...]) }
        let exponent: Int
        if let exponentText {
            guard let parsed = Int(exponentText) else { return nil }
            exponent = parsed
        } else {
            exponent = 0
        }

        let pointIndex = coefficient.firstIndex(of: ".")
        let fractionLength = pointIndex.map {
            coefficient.distance(
                from: coefficient.index(after: $0),
                to: coefficient.endIndex
            )
        } ?? 0
        var digits = String(coefficient.filter { $0 != "." })
        while digits.first == "0" { digits.removeFirst() }
        if digits.isEmpty { return "0" }

        let scale: Int
        let (candidateScale, overflow) = exponent.subtractingReportingOverflow(fractionLength)
        guard !overflow else { return nil }
        scale = candidateScale

        if scale < 0 {
            guard scale != Int.min else { return nil }
            let requiredZeros = -scale
            guard requiredZeros <= digits.count,
                  digits.suffix(requiredZeros).allSatisfy({ $0 == "0" })
            else {
                return nil
            }
            digits.removeLast(requiredZeros)
            while digits.first == "0" { digits.removeFirst() }
            if digits.isEmpty { return "0" }
        } else {
            guard scale <= 19, digits.count + scale <= 19 else { return nil }
            digits.append(contentsOf: String(repeating: "0", count: scale))
        }

        let limit = negative ? "9223372036854775808" : "9223372036854775807"
        guard digits.count < limit.count || (digits.count == limit.count && digits <= limit) else {
            return nil
        }
        return negative ? "-" + digits : digits
    }

    /// Swift uses a shortest round-tripping binary64 decimal. This normalizes
    /// only its layout to RFC 8785's ECMAScript fixed/exponent thresholds.
    private static func canonicalBinary64(_ value: Double) throws -> String {
        var raw = String(value).lowercased()
        let negative = raw.first == "-"
        if negative { raw.removeFirst() }

        let exponentIndex = raw.firstIndex(of: "e")
        let coefficient = exponentIndex.map { String(raw[..<$0]) } ?? raw
        let explicitExponent: Int
        if let exponentIndex {
            guard let parsed = Int(raw[raw.index(after: exponentIndex)...]) else {
                throw EluV1StrictCanonicalJSONError.unsupportedNumber
            }
            explicitExponent = parsed
        } else {
            explicitExponent = 0
        }

        let pointIndex = coefficient.firstIndex(of: ".")
        let fractionLength = pointIndex.map {
            coefficient.distance(
                from: coefficient.index(after: $0),
                to: coefficient.endIndex
            )
        } ?? 0
        var digits = String(coefficient.filter { $0 != "." })
        var scale = explicitExponent - fractionLength
        while digits.first == "0" { digits.removeFirst() }
        while digits.last == "0" {
            digits.removeLast()
            scale += 1
        }
        guard !digits.isEmpty else { return "0" }

        let scientificExponent = digits.count + scale - 1
        let body: String
        if (-6 ... 20).contains(scientificExponent) {
            let point = digits.count + scale
            if point <= 0 {
                body = "0." + String(repeating: "0", count: -point) + digits
            } else if point >= digits.count {
                body = digits + String(repeating: "0", count: point - digits.count)
            } else {
                let split = digits.index(digits.startIndex, offsetBy: point)
                body = String(digits[..<split]) + "." + String(digits[split...])
            }
        } else {
            let head = String(digits.removeFirst())
            let mantissa = digits.isEmpty ? head : head + "." + digits
            let sign = scientificExponent >= 0 ? "+" : ""
            body = mantissa + "e" + sign + String(scientificExponent)
        }
        return negative ? "-" + body : body
    }

    private final class Parser {
        private let source: [UInt16]
        private var index = 0

        init(_ source: [UInt16]) {
            self.source = source
        }

        func parse() throws -> Value {
            skipWhitespace()
            let value = try parseValue(depth: 0)
            skipWhitespace()
            guard index == source.count else {
                throw EluV1StrictCanonicalJSONError.malformed
            }
            return value
        }

        private func parseValue(depth: Int) throws -> Value {
            guard depth <= maximumNesting, index < source.count else {
                throw depth > maximumNesting
                    ? EluV1StrictCanonicalJSONError.excessiveNesting
                    : EluV1StrictCanonicalJSONError.malformed
            }
            switch source[index] {
            case 0x7B: return try parseObject(depth: depth + 1)
            case 0x5B: return try parseArray(depth: depth + 1)
            case 0x22: return .string(try parseString())
            case 0x74: return try parseLiteral("true", value: .bool(true))
            case 0x66: return try parseLiteral("false", value: .bool(false))
            case 0x6E: return try parseLiteral("null", value: .null)
            case 0x2D, 0x30 ... 0x39: return .number(try parseNumber())
            default: throw EluV1StrictCanonicalJSONError.malformed
            }
        }

        private func parseObject(depth: Int) throws -> Value {
            guard depth <= maximumNesting else {
                throw EluV1StrictCanonicalJSONError.excessiveNesting
            }
            index += 1
            skipWhitespace()
            if consume(0x7D) { return .object([]) }
            var members: [Member] = []
            var names = Set<[UInt16]>()
            while true {
                guard peek == 0x22 else {
                    throw EluV1StrictCanonicalJSONError.malformed
                }
                let name = try parseString()
                guard names.insert(name).inserted else {
                    throw EluV1StrictCanonicalJSONError.duplicateObjectKey
                }
                skipWhitespace()
                try require(0x3A)
                skipWhitespace()
                members.append(Member(name: name, value: try parseValue(depth: depth)))
                skipWhitespace()
                if consume(0x7D) { return .object(members) }
                try require(0x2C)
                skipWhitespace()
                guard peek != 0x7D else {
                    throw EluV1StrictCanonicalJSONError.malformed
                }
            }
        }

        private func parseArray(depth: Int) throws -> Value {
            guard depth <= maximumNesting else {
                throw EluV1StrictCanonicalJSONError.excessiveNesting
            }
            index += 1
            skipWhitespace()
            if consume(0x5D) { return .array([]) }
            var values: [Value] = []
            while true {
                values.append(try parseValue(depth: depth))
                skipWhitespace()
                if consume(0x5D) { return .array(values) }
                try require(0x2C)
                skipWhitespace()
                guard peek != 0x5D else {
                    throw EluV1StrictCanonicalJSONError.malformed
                }
            }
        }

        private func parseString() throws -> [UInt16] {
            try require(0x22)
            var decoded: [UInt16] = []
            while index < source.count {
                let unit = source[index]
                index += 1
                if unit == 0x22 {
                    try validateScalarSequence(decoded)
                    return decoded
                }
                if unit == 0x5C {
                    guard index < source.count else {
                        throw EluV1StrictCanonicalJSONError.malformed
                    }
                    let escape = source[index]
                    index += 1
                    switch escape {
                    case 0x22, 0x2F, 0x5C: decoded.append(escape)
                    case 0x62: decoded.append(0x08)
                    case 0x66: decoded.append(0x0C)
                    case 0x6E: decoded.append(0x0A)
                    case 0x72: decoded.append(0x0D)
                    case 0x74: decoded.append(0x09)
                    case 0x75: decoded.append(try parseHexQuad())
                    default: throw EluV1StrictCanonicalJSONError.malformed
                    }
                } else {
                    guard unit >= 0x20 else {
                        throw EluV1StrictCanonicalJSONError.malformed
                    }
                    decoded.append(unit)
                }
            }
            throw EluV1StrictCanonicalJSONError.malformed
        }

        private func parseHexQuad() throws -> UInt16 {
            guard index + 4 <= source.count else {
                throw EluV1StrictCanonicalJSONError.malformed
            }
            var value: UInt16 = 0
            for _ in 0 ..< 4 {
                let digit: UInt16
                switch source[index] {
                case 0x30 ... 0x39: digit = source[index] - 0x30
                case 0x41 ... 0x46: digit = source[index] - 0x41 + 10
                case 0x61 ... 0x66: digit = source[index] - 0x61 + 10
                default: throw EluV1StrictCanonicalJSONError.malformed
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        private func parseNumber() throws -> String {
            let start = index
            _ = consume(0x2D)
            guard index < source.count else {
                throw EluV1StrictCanonicalJSONError.malformed
            }
            if consume(0x30) {
                guard !(peek.map { (0x30 ... 0x39).contains($0) } ?? false) else {
                    throw EluV1StrictCanonicalJSONError.malformed
                }
            } else {
                guard let unit = peek, (0x31 ... 0x39).contains(unit) else {
                    throw EluV1StrictCanonicalJSONError.malformed
                }
                while peek.map({ (0x30 ... 0x39).contains($0) }) ?? false { index += 1 }
            }
            if consume(0x2E) {
                let fractionStart = index
                while peek.map({ (0x30 ... 0x39).contains($0) }) ?? false { index += 1 }
                guard index > fractionStart else {
                    throw EluV1StrictCanonicalJSONError.malformed
                }
            }
            if peek == 0x65 || peek == 0x45 {
                index += 1
                if peek == 0x2B || peek == 0x2D { index += 1 }
                let exponentStart = index
                while peek.map({ (0x30 ... 0x39).contains($0) }) ?? false { index += 1 }
                guard index > exponentStart else {
                    throw EluV1StrictCanonicalJSONError.malformed
                }
            }
            let token = String(decoding: source[start ..< index], as: UTF16.self)
            _ = try canonicalNumber(token)
            return token
        }

        private func parseLiteral(_ literal: String, value: Value) throws -> Value {
            let units = Array(literal.utf16)
            guard index + units.count <= source.count,
                  Array(source[index ..< index + units.count]) == units
            else {
                throw EluV1StrictCanonicalJSONError.malformed
            }
            index += units.count
            return value
        }

        private var peek: UInt16? {
            index < source.count ? source[index] : nil
        }

        private func consume(_ expected: UInt16) -> Bool {
            guard peek == expected else { return false }
            index += 1
            return true
        }

        private func require(_ expected: UInt16) throws {
            guard consume(expected) else {
                throw EluV1StrictCanonicalJSONError.malformed
            }
        }

        private func skipWhitespace() {
            while let unit = peek, unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D {
                index += 1
            }
        }
    }
}
