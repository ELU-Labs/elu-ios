import CryptoKit
import Foundation

enum EluV1FlagJSONError: Error, Equatable, Sendable {
    case emptyInput
    case payloadTooLarge
    case byteOrderMark
    case malformed
    case duplicateObjectKey
    case unpairedSurrogate
    case excessiveNesting
    case excessiveNodes
    case excessiveCollectionEntries
    case excessiveString
    case excessiveKey
    case unsafeInteger
    case unsupportedNumber
}

struct EluV1FlagJSONMember: Equatable, Sendable {
    let name: [UInt16]
    let value: EluV1FlagJSONValue

    init(name: [UInt16], value: EluV1FlagJSONValue) {
        self.name = name
        self.value = value
    }

    init(name: String, value: EluV1FlagJSONValue) {
        self.init(name: Array(name.utf16), value: value)
    }
}

/// The common flag JSON domain. Object member names remain decoded UTF-16
/// arrays for their entire lifetime so Swift's canonically-equivalent String
/// equality can never merge distinct wire keys.
indirect enum EluV1FlagJSONValue: Equatable, Sendable {
    case object([EluV1FlagJSONMember])
    case array([EluV1FlagJSONValue])
    case string([UInt16])
    case number(Double)
    case bool(Bool)
    case null

    var objectMembers: [EluV1FlagJSONMember]? {
        guard case let .object(members) = self else { return nil }
        return members
    }

    var stringUnits: [UInt16]? {
        guard case let .string(units) = self else { return nil }
        return units
    }

    var stringValue: String? {
        guard let units = stringUnits else { return nil }
        return String(decoding: units, as: UTF16.self)
    }

    var safeIntegerValue: Int64? {
        guard case let .number(value) = self,
              value.rounded(.towardZero) == value,
              abs(value) <= EluV1FlagJSON.maximumSafeInteger
        else {
            return nil
        }
        return Int64(exactly: value)
    }

    func property(units: [UInt16]) -> EluV1FlagJSONValue? {
        guard case let .object(members) = self else { return nil }
        return members.first(where: { $0.name == units })?.value
    }

    func property(_ name: String) -> EluV1FlagJSONValue? {
        property(units: Array(name.utf16))
    }
}

enum EluV1FlagJSON {
    static let maximumWireBytes = 1_048_576
    static let maximumCacheBytes = 4_194_304
    static let maximumDepth = 16
    static let maximumNodes = 4_096
    static let maximumCollectionEntries = 1_024
    static let maximumStringScalars = 65_536
    static let maximumKeyScalars = 256
    static let maximumSafeInteger: Double = 9_007_199_254_740_991

    /// Classifies an unambiguously declared future top-level envelope before
    /// applying the v1 depth/node/collection budgets. Future schemas own their
    /// semantic shape, so a valid bounded JSON document with schemaVersion > 1
    /// must be preserved even when its shape is not materializable as a v1 AST.
    static func declaresFutureTopLevelSchema(
        _ data: Data,
        maximumBytes: Int = maximumCacheBytes
    ) -> Bool {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              !data.starts(with: [0xEF, 0xBB, 0xBF]),
              String(data: data, encoding: .utf8) != nil,
              (try? JSONSerialization.jsonObject(with: data)) is NSDictionary
        else {
            return false
        }

        let bytes = [UInt8](data)
        var offset = 0
        skipWhitespace(bytes, offset: &offset)
        guard consume(0x7B, in: bytes, offset: &offset) else { return false }
        var keys = Set<[UInt16]>()
        let schemaVersionKey = Array("schemaVersion".utf16)
        var future = false
        while offset < bytes.count {
            skipWhitespace(bytes, offset: &offset)
            if consume(0x7D, in: bytes, offset: &offset) {
                skipWhitespace(bytes, offset: &offset)
                return offset == bytes.count && future
            }
            guard bytes[offset] == 0x22,
                  let keyEnd = jsonStringEnd(bytes, start: offset),
                  let key = try? JSONDecoder().decode(
                      String.self,
                      from: Data(bytes[offset ..< keyEnd])
                  ),
                  keys.insert(Array(key.utf16)).inserted
            else {
                return false
            }
            offset = keyEnd
            skipWhitespace(bytes, offset: &offset)
            guard consume(0x3A, in: bytes, offset: &offset) else { return false }
            skipWhitespace(bytes, offset: &offset)
            let valueStart = offset
            guard let valueEnd = topLevelValueEnd(bytes, start: valueStart) else { return false }
            offset = valueEnd
            if Array(key.utf16) == schemaVersionKey {
                let token = String(decoding: bytes[valueStart ..< valueEnd], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                future = Int64(token).map {
                    (2 ... 9_007_199_254_740_991).contains($0)
                } ?? false
            }
            skipWhitespace(bytes, offset: &offset)
            if consume(0x2C, in: bytes, offset: &offset) { continue }
            if consume(0x7D, in: bytes, offset: &offset) {
                skipWhitespace(bytes, offset: &offset)
                return offset == bytes.count && future
            }
            return false
        }
        return false
    }

    static func parse(
        _ data: Data,
        maximumBytes: Int = maximumWireBytes
    ) throws -> EluV1FlagJSONValue {
        guard !data.isEmpty else { throw EluV1FlagJSONError.emptyInput }
        guard data.count <= maximumBytes else { throw EluV1FlagJSONError.payloadTooLarge }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            throw EluV1FlagJSONError.byteOrderMark
        }
        do {
            let document = try EluV1StrictCanonicalJSON.parse(data)
            var remainingNodes = maximumNodes
            return try convert(document.value, depth: 0, remainingNodes: &remainingNodes)
        } catch let error as EluV1FlagJSONError {
            throw error
        } catch let error as EluV1StrictCanonicalJSONError {
            switch error {
            case .duplicateObjectKey: throw EluV1FlagJSONError.duplicateObjectKey
            case .unpairedSurrogate: throw EluV1FlagJSONError.unpairedSurrogate
            case .excessiveNesting: throw EluV1FlagJSONError.excessiveNesting
            case .unsupportedNumber: throw EluV1FlagJSONError.unsupportedNumber
            default: throw EluV1FlagJSONError.malformed
            }
        } catch {
            throw EluV1FlagJSONError.malformed
        }
    }

    static func canonicalData(
        for value: EluV1FlagJSONValue,
        maximumBytes: Int = maximumCacheBytes
    ) throws -> Data {
        var remainingNodes = maximumNodes
        try validate(value, depth: 0, remainingNodes: &remainingNodes)
        let data: Data
        do {
            data = try EluV1StrictCanonicalJSON.canonicalData(for: strictValue(value))
        } catch {
            throw EluV1FlagJSONError.malformed
        }
        guard data.count <= maximumBytes else { throw EluV1FlagJSONError.payloadTooLarge }
        return data
    }

    static func hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ value: EluV1FlagJSONValue) throws -> String {
        hash(try canonicalData(for: value))
    }

    static func string(_ value: String) throws -> EluV1FlagJSONValue {
        let result = EluV1FlagJSONValue.string(Array(value.utf16))
        var remainingNodes = maximumNodes
        try validate(result, depth: 0, remainingNodes: &remainingNodes)
        return result
    }

    static func safeInteger(_ value: Int64) throws -> EluV1FlagJSONValue {
        guard value >= -9_007_199_254_740_991, value <= 9_007_199_254_740_991 else {
            throw EluV1FlagJSONError.unsafeInteger
        }
        return .number(Double(value))
    }

    static func object(_ pairs: [(String, EluV1FlagJSONValue)]) throws -> EluV1FlagJSONValue {
        var seen = Set<[UInt16]>()
        var members: [EluV1FlagJSONMember] = []
        members.reserveCapacity(pairs.count)
        for (name, value) in pairs {
            let units = Array(name.utf16)
            guard seen.insert(units).inserted else {
                throw EluV1FlagJSONError.duplicateObjectKey
            }
            members.append(EluV1FlagJSONMember(name: units, value: value))
        }
        members.sort { $0.name.lexicographicallyPrecedes($1.name) }
        let result = EluV1FlagJSONValue.object(members)
        var remainingNodes = maximumNodes
        try validate(result, depth: 0, remainingNodes: &remainingNodes)
        return result
    }

    static func fromLegacy(_ value: EluJSONValue) throws -> EluV1FlagJSONValue {
        switch value {
        case .null:
            return .null
        case let .bool(value):
            return .bool(value)
        case let .integer(value):
            return try safeInteger(value)
        case let .number(value):
            guard value.isFinite else { throw EluV1FlagJSONError.unsupportedNumber }
            if abs(value) > maximumSafeInteger,
               try canonicalBinary64SpellsInteger(value)
            {
                throw EluV1FlagJSONError.unsafeInteger
            }
            return .number(value == 0 ? 0 : value)
        case let .string(value):
            return try string(value)
        case let .array(values):
            return .array(try values.map { try fromLegacy($0) })
        case let .object(values):
            return try object(values.map { ($0.key, try fromLegacy($0.value)) })
        }
    }

    static func fromLegacyObject(
        _ values: [String: EluJSONValue]
    ) throws -> EluV1FlagJSONValue {
        try object(values.map { ($0.key, try fromLegacy($0.value)) })
    }

    private static func convert(
        _ value: EluV1StrictCanonicalJSON.Value,
        depth: Int,
        remainingNodes: inout Int
    ) throws -> EluV1FlagJSONValue {
        guard depth <= maximumDepth else { throw EluV1FlagJSONError.excessiveNesting }
        guard remainingNodes > 0 else { throw EluV1FlagJSONError.excessiveNodes }
        remainingNodes -= 1

        switch value {
        case let .object(members):
            guard members.count <= maximumCollectionEntries else {
                throw EluV1FlagJSONError.excessiveCollectionEntries
            }
            var converted: [EluV1FlagJSONMember] = []
            converted.reserveCapacity(members.count)
            for member in members {
                guard try scalarCount(member.name) <= maximumKeyScalars else {
                    throw EluV1FlagJSONError.excessiveKey
                }
                converted.append(
                    EluV1FlagJSONMember(
                        name: member.name,
                        value: try convert(
                            member.value,
                            depth: depth + 1,
                            remainingNodes: &remainingNodes
                        )
                    )
                )
            }
            return .object(converted)

        case let .array(values):
            guard values.count <= maximumCollectionEntries else {
                throw EluV1FlagJSONError.excessiveCollectionEntries
            }
            var converted: [EluV1FlagJSONValue] = []
            converted.reserveCapacity(values.count)
            for child in values {
                converted.append(
                    try convert(child, depth: depth + 1, remainingNodes: &remainingNodes)
                )
            }
            return .array(converted)

        case let .string(units):
            guard try scalarCount(units) <= maximumStringScalars else {
                throw EluV1FlagJSONError.excessiveString
            }
            return .string(units)

        case let .number(token):
            guard let value = Double(token), value.isFinite else {
                throw EluV1FlagJSONError.unsupportedNumber
            }
            // Match the JavaScript projection after binary64 normalization.
            // Fractional/exponent aliases that round onto a fixed-form unsafe
            // integer are rejected, while valid scientific-form binary64
            // boundaries (for example max finite) remain representable.
            if abs(value) > maximumSafeInteger,
               try canonicalBinary64SpellsInteger(value)
            {
                throw EluV1FlagJSONError.unsafeInteger
            }
            return .number(value == 0 ? 0 : value)

        case let .bool(value):
            return .bool(value)
        case .null:
            return .null
        }
    }

    private static func validate(
        _ value: EluV1FlagJSONValue,
        depth: Int,
        remainingNodes: inout Int
    ) throws {
        guard depth <= maximumDepth else { throw EluV1FlagJSONError.excessiveNesting }
        guard remainingNodes > 0 else { throw EluV1FlagJSONError.excessiveNodes }
        remainingNodes -= 1
        switch value {
        case let .object(members):
            guard members.count <= maximumCollectionEntries else {
                throw EluV1FlagJSONError.excessiveCollectionEntries
            }
            var names = Set<[UInt16]>()
            for member in members {
                guard names.insert(member.name).inserted else {
                    throw EluV1FlagJSONError.duplicateObjectKey
                }
                guard try scalarCount(member.name) <= maximumKeyScalars else {
                    throw EluV1FlagJSONError.excessiveKey
                }
                try validate(member.value, depth: depth + 1, remainingNodes: &remainingNodes)
            }
        case let .array(values):
            guard values.count <= maximumCollectionEntries else {
                throw EluV1FlagJSONError.excessiveCollectionEntries
            }
            for child in values {
                try validate(child, depth: depth + 1, remainingNodes: &remainingNodes)
            }
        case let .string(units):
            guard try scalarCount(units) <= maximumStringScalars else {
                throw EluV1FlagJSONError.excessiveString
            }
        case let .number(value):
            guard value.isFinite else { throw EluV1FlagJSONError.unsupportedNumber }
            if abs(value) > maximumSafeInteger,
               try canonicalBinary64SpellsInteger(value)
            {
                throw EluV1FlagJSONError.unsafeInteger
            }
        case .bool, .null:
            break
        }
    }

    private static func strictValue(
        _ value: EluV1FlagJSONValue
    ) -> EluV1StrictCanonicalJSON.Value {
        switch value {
        case let .object(members):
            return .object(members.map {
                EluV1StrictCanonicalJSON.Member(
                    name: $0.name,
                    value: strictValue($0.value)
                )
            })
        case let .array(values):
            return .array(values.map(strictValue))
        case let .string(units):
            return .string(units)
        case let .number(value):
            return .number(value == 0 ? "0" : String(value))
        case let .bool(value):
            return .bool(value)
        case .null:
            return .null
        }
    }

    private static func scalarCount(_ units: [UInt16]) throws -> Int {
        var count = 0
        var index = 0
        while index < units.count {
            switch units[index] {
            case 0xD800 ... 0xDBFF:
                guard index + 1 < units.count,
                      (0xDC00 ... 0xDFFF).contains(units[index + 1])
                else {
                    throw EluV1FlagJSONError.unpairedSurrogate
                }
                index += 2
            case 0xDC00 ... 0xDFFF:
                throw EluV1FlagJSONError.unpairedSurrogate
            default:
                index += 1
            }
            count += 1
        }
        return count
    }

    private static func canonicalBinary64SpellsInteger(_ value: Double) throws -> Bool {
        let normalized: Data
        do {
            normalized = try EluV1StrictCanonicalJSON.canonicalData(
                for: .number(String(value))
            )
        } catch {
            throw EluV1FlagJSONError.unsupportedNumber
        }
        let bytes = [UInt8](normalized)
        let digits = bytes.first == 0x2D ? bytes.dropFirst() : bytes[...]
        return !digits.isEmpty && digits.allSatisfy { (0x30 ... 0x39).contains($0) }
    }

    private static func skipWhitespace(_ bytes: [UInt8], offset: inout Int) {
        while offset < bytes.count,
              bytes[offset] == 0x20 || bytes[offset] == 0x09
                || bytes[offset] == 0x0A || bytes[offset] == 0x0D
        {
            offset += 1
        }
    }

    private static func consume(_ byte: UInt8, in bytes: [UInt8], offset: inout Int) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    private static func jsonStringEnd(_ bytes: [UInt8], start: Int) -> Int? {
        guard start < bytes.count, bytes[start] == 0x22 else { return nil }
        var offset = start + 1
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]
            if !escaped, byte == 0x22 { return offset + 1 }
            if !escaped, byte < 0x20 { return nil }
            if !escaped, byte == 0x5C { escaped = true } else { escaped = false }
            offset += 1
        }
        return nil
    }

    private static func topLevelValueEnd(_ bytes: [UInt8], start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        if bytes[start] == 0x22 { return jsonStringEnd(bytes, start: start) }
        if bytes[start] != 0x7B, bytes[start] != 0x5B {
            var offset = start
            while offset < bytes.count, bytes[offset] != 0x2C, bytes[offset] != 0x7D {
                offset += 1
            }
            return offset > start ? offset : nil
        }

        var closers: [UInt8] = [bytes[start] == 0x7B ? 0x7D : 0x5D]
        var offset = start + 1
        while offset < bytes.count, let expected = closers.last {
            let byte = bytes[offset]
            if byte == 0x22 {
                guard let end = jsonStringEnd(bytes, start: offset) else { return nil }
                offset = end
                continue
            }
            if byte == 0x7B { closers.append(0x7D) }
            else if byte == 0x5B { closers.append(0x5D) }
            else if byte == 0x7D || byte == 0x5D {
                guard byte == expected else { return nil }
                closers.removeLast()
            }
            offset += 1
        }
        return closers.isEmpty ? offset : nil
    }
}
