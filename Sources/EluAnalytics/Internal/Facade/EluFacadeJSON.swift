import Foundation

/// Projects the untyped values customer code passes to the `Elu` facade onto
/// the JSON domain the ELU runtime persists, and removes the property names
/// the runtime derives for itself.
///
/// The projection follows JSON serialization rather than rejecting the call:
/// a value JSON cannot carry is dropped from an object and becomes null in an
/// array, exactly as a browser would serialize it. That keeps one unsupported
/// value from discarding a whole event.
enum EluFacadeJSON {
    /// Prefix of the version properties the runtime stamps on every record.
    /// The queue rejects any record that tries to set them, so they are
    /// removed here and the removal is counted.
    static let reservedPropertyPrefix = "$elu_"

    static let maximumKeyLength = 256
    static let maximumProperties = 1_024
    static let maximumDepth = 16

    static func isReservedKey(_ key: String) -> Bool {
        key.hasPrefix(reservedPropertyPrefix)
    }

    /// The projected properties plus the number of reserved names removed.
    /// A key the queue cannot store at all is removed as invalid input.
    static func properties(
        _ properties: [String: Any]?
    ) -> (properties: [String: EluJSONValue], reserved: Int, invalid: Int) {
        guard let properties, !properties.isEmpty else { return ([:], 0, 0) }
        var projected: [String: EluJSONValue] = [:]
        projected.reserveCapacity(properties.count)
        var reserved = 0
        var invalid = 0
        for (key, value) in properties {
            guard !isReservedKey(key) else {
                reserved += 1
                continue
            }
            guard isStorableKey(key), let projectedValue = self.value(value, depth: 0) else {
                invalid += 1
                continue
            }
            guard projected.count < maximumProperties else {
                invalid += 1
                continue
            }
            projected[key] = projectedValue
        }
        return (projected, reserved, invalid)
    }

    static func isStorableKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.count <= maximumKeyLength
    }

    /// A non-empty identifier the queue accepts as an event name, distinct id,
    /// group type, or group key.
    static func identifier(_ value: String, maximumLength: Int) -> String? {
        guard !value.isEmpty, value.unicodeScalars.count <= maximumLength else { return nil }
        return value
    }

    static func value(_ value: Any, depth: Int = 0) -> EluJSONValue? {
        guard depth <= maximumDepth else { return nil }
        switch value {
        case is NSNull:
            return .null
        case let text as String:
            return .string(text)
        case let number as NSNumber:
            return self.number(number)
        case let date as Date:
            return .string(EluRFC3339.string(from: date))
        case let url as URL:
            return .string(url.absoluteString)
        case let array as [Any]:
            // A member JSON cannot carry becomes null so the remaining members
            // keep their positions.
            return .array(array.map { self.value($0, depth: depth + 1) ?? .null })
        case let object as [String: Any]:
            var members: [String: EluJSONValue] = [:]
            members.reserveCapacity(object.count)
            for (key, member) in object {
                guard isStorableKey(key),
                      let projected = self.value(member, depth: depth + 1)
                else {
                    continue
                }
                members[key] = projected
            }
            return .object(members)
        default:
            return nil
        }
    }

    private static func number(_ number: NSNumber) -> EluJSONValue? {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        if CFNumberIsFloatType(number) {
            let value = number.doubleValue
            guard value.isFinite else { return nil }
            return .number(value)
        }
        return .integer(number.int64Value)
    }

    /// Projects a stored flag value onto the untyped domain the facade
    /// returns: a string is the variant, a boolean is the enabled state, a
    /// number is enabled when it is non-zero, and an explicit null is
    /// disabled. A key absent from the snapshot has no value at all and never
    /// reaches this projection.
    static func flagValue(_ value: EluV1FlagValue) -> Any {
        switch value {
        case let .string(units): return String(decoding: units, as: UTF16.self)
        case let .bool(flag): return flag
        case let .number(number): return number != 0
        case .null: return false
        }
    }

    /// True when a stored flag value reports the flag as enabled: a non-empty
    /// variant and a non-zero number are enabled, an explicit null is not.
    static func flagIsEnabled(_ value: EluV1FlagValue) -> Bool {
        switch value {
        case let .string(units): return !units.isEmpty
        case let .bool(flag): return flag
        case let .number(number): return number != 0
        case .null: return false
        }
    }

    /// Projects a flag payload onto the untyped domain, using Foundation's
    /// JSON representation so customer code reads it the way it reads any
    /// other decoded JSON.
    static func payload(_ value: EluV1FlagJSONValue) -> Any? {
        switch value {
        case .null:
            return NSNull()
        case let .bool(flag):
            return flag
        case let .number(number):
            return number
        case let .string(units):
            return String(decoding: units, as: UTF16.self)
        case let .array(values):
            return values.map { payload($0) ?? NSNull() }
        case let .object(members):
            var object: [String: Any] = [:]
            object.reserveCapacity(members.count)
            for member in members {
                object[String(decoding: member.name, as: UTF16.self)] =
                    payload(member.value) ?? NSNull()
            }
            return object
        }
    }

    /// The exposure ledger key for one reported flag value. A read that found
    /// no value and a read that found one are reported separately.
    static func exposureKey(_ key: String, value: EluV1FlagValue?) -> String {
        guard let value else { return key + "\u{0}" }
        switch value {
        case let .bool(flag): return key + "\u{0}b:\(flag)"
        case let .string(units): return key + "\u{0}s:" + String(decoding: units, as: UTF16.self)
        case let .number(number): return key + "\u{0}n:\(number)"
        case .null: return key + "\u{0}null"
        }
    }
}
