import Foundation

enum EluJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([EluJSONValue])
    case object([String: EluJSONValue])

    private static let maximumDepth = 16
    private static let maximumNodes = 4_096
    private static let maximumCollectionCount = 1_024
    private static let maximumStringLength = 65_536
    private static let maximumKeyLength = 256

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: EluDynamicCodingKey.self) {
            var object: [String: EluJSONValue] = [:]
            object.reserveCapacity(container.allKeys.count)
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(EluJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var array: [EluJSONValue] = []
            if let count = container.count {
                array.reserveCapacity(count)
            }
            while !container.isAtEnd {
                array.append(try container.decode(EluJSONValue.self))
            }
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "JSON numbers must be finite"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .integer(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "JSON numbers must be finite"
                    )
                )
            }
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case let .object(values):
            var container = encoder.container(keyedBy: EluDynamicCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: EluDynamicCodingKey(key))
            }
        }
    }

    func validate() throws {
        var remainingNodes = Self.maximumNodes
        try validate(depth: 0, remainingNodes: &remainingNodes)
    }

    private func validate(depth: Int, remainingNodes: inout Int) throws {
        guard depth <= Self.maximumDepth, remainingNodes > 0 else {
            throw EluIdentityStateError.jsonValueTooLarge
        }
        remainingNodes -= 1

        switch self {
        case .null, .bool, .integer:
            return
        case let .number(value):
            guard value.isFinite else {
                throw EluIdentityStateError.invalidJSONNumber
            }
        case let .string(value):
            guard value.count <= Self.maximumStringLength else {
                throw EluIdentityStateError.jsonValueTooLarge
            }
        case let .array(values):
            guard values.count <= Self.maximumCollectionCount else {
                throw EluIdentityStateError.jsonValueTooLarge
            }
            for value in values {
                try value.validate(depth: depth + 1, remainingNodes: &remainingNodes)
            }
        case let .object(values):
            guard values.count <= Self.maximumCollectionCount else {
                throw EluIdentityStateError.jsonValueTooLarge
            }
            for (key, value) in values {
                guard !key.isEmpty, key.count <= Self.maximumKeyLength else {
                    throw EluIdentityStateError.invalidPropertyKey
                }
                try value.validate(depth: depth + 1, remainingNodes: &remainingNodes)
            }
        }
    }
}

struct EluDynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
