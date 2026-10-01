import Foundation

struct EluEventPersonChanges: Equatable, Sendable {
    let set: [String: EluJSONValue]?
    let setOnce: [String: EluJSONValue]?
    var hasIntent: Bool { set != nil || setOnce != nil }
}

enum EluEventFilterFailure: Error, Equatable, Sendable {
    case dropped
    case invalid
    case withdrawn
    case unsupportedPersonChanges
}

struct EluFilteredEvent: Equatable, Sendable {
    let command: EluV1CaptureCommand
    let person: EluEventPersonChanges
}

/// Immutable setup policy. Customer code runs synchronously outside all locks
/// and transactions; only the detached JSON result crosses an actor boundary.
struct EluEventFilter: Sendable {
    let denylist: Set<[UInt16]>
    let beforeSend: (@Sendable (EluEvent) throws -> EluEvent?)?
    private let valid: Bool
    var active: Bool { !denylist.isEmpty || beforeSend != nil || !valid }

    init(propertyDenylist: [String] = [],
         beforeSend: (@Sendable (EluEvent) throws -> EluEvent?)? = nil) {
        valid = propertyDenylist.count <= 1_024 && propertyDenylist.allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.count <= 256
        }
        denylist = valid ? Set(propertyDenylist.map { Array($0.utf16) }) : []
        self.beforeSend = beforeSend
    }

    func apply(_ command: EluV1CaptureCommand, mergedProperties: [String: EluJSONValue],
               person: EluEventPersonChanges, allowsPersonChanges: Bool) throws -> EluFilteredEvent {
        guard valid else { throw EluEventFilterFailure.invalid }
        var mutable = mergedProperties.filter { !Self.protected($0.key) && !denylist.contains(Array($0.key.utf16)) }
        // Check the entire callback input before constructing Foundation values.
        var inputBudget = ProjectionBudget()
        try inputBudget.typed(.object(mutable), depth: 0)
        if let set = person.set { try inputBudget.typed(.object(set), depth: 0) }
        if let setOnce = person.setOnce { try inputBudget.typed(.object(setOnce), depth: 0) }
        var transformed = EluEvent(event: command.name, properties: Self.unbox(mutable),
            timestamp: command.occurredAt, set: person.set.map(Self.unbox), setOnce: person.setOnce.map(Self.unbox))
        if let beforeSend {
            do {
                guard let returned = try beforeSend(transformed) else { throw EluEventFilterFailure.dropped }
                transformed = returned
            } catch let failure as EluEventFilterFailure { throw failure }
            catch { throw EluEventFilterFailure.invalid }
        }
        guard EluFacadeJSON.identifier(transformed.event, maximumLength: 512) != nil,
              transformed.timestamp.timeIntervalSinceReferenceDate.isFinite else { throw EluEventFilterFailure.invalid }
        var budget = ProjectionBudget()
        mutable = try budget.properties(transformed.properties)
        let set = try transformed.set.map { try budget.properties($0) }
        let setOnce = try transformed.setOnce.map { try budget.properties($0) }
        let changes = EluEventPersonChanges(set: set, setOnce: setOnce)
        guard allowsPersonChanges || !changes.hasIntent else { throw EluEventFilterFailure.unsupportedPersonChanges }
        return EluFilteredEvent(command: EluV1CaptureCommand(kind: command.kind, name: transformed.event,
            occurredAt: transformed.timestamp, properties: mutable, versions: command.versions), person: changes)
    }

    private static func unbox(_ values: [String: EluJSONValue]) -> [String: Any] {
        values.mapValues(unboxValue)
    }
    private static func protected(_ key: String) -> Bool {
        EluFacadeJSON.isReservedKey(key) || ["distinct_id", "$user_id", "$anon_distinct_id", "$session_id", "$window_id", "$groups"].contains(key)
    }
    private static func unboxValue(_ value: EluJSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .integer(value): return value
        case let .number(value): return value
        case let .string(value): return value
        case let .array(values): return values.map(unboxValue)
        case let .object(values): return unbox(values)
        }
    }

    /// A scrubber's malformed replacement is refused in full, rather than
    /// partially projected or replaced by the unfiltered original event.
    private struct ProjectionBudget {
        var nodes = 4_096
        var bytes = 10 * 1_024 * 1_024
        var ancestors: Set<ObjectIdentifier> = []

        mutating func typed(_ value: EluJSONValue, depth: Int) throws {
            guard depth <= 16, nodes > 0, bytes >= 32 else { throw EluEventFilterFailure.invalid }
            nodes -= 1; bytes -= 32
            switch value {
            case .null, .bool, .integer: break
            case let .number(value): guard value.isFinite else { throw EluEventFilterFailure.invalid }
            case let .string(value): try charge(value)
            case let .array(values):
                guard values.count <= 1_024 else { throw EluEventFilterFailure.invalid }
                for value in values { try typed(value, depth: depth + 1) }
            case let .object(values):
                guard values.count <= 1_024 else { throw EluEventFilterFailure.invalid }
                for (key, value) in values {
                    guard EluFacadeJSON.isStorableKey(key) else { throw EluEventFilterFailure.invalid }
                    try charge(key); try typed(value, depth: depth + 1)
                }
            }
        }

        mutating func properties(_ value: [String: Any]) throws -> [String: EluJSONValue] {
            guard value.count <= 1_024 else { throw EluEventFilterFailure.invalid }
            var result: [String: EluJSONValue] = [:]
            for (key, member) in value {
                guard !EluEventFilter.protected(key) else { continue }
                guard EluFacadeJSON.isStorableKey(key) else { throw EluEventFilterFailure.invalid }
                try charge(key)
                result[key] = try project(member, depth: 1)
            }
            try EluJSONValue.object(result).validate()
            return result
        }
        mutating func charge(_ value: String) throws {
            // Conservative JSON escaping cost, checked without allocating a
            // serialized copy of a caller-controlled, potentially huge string.
            for _ in value.utf8 {
                guard bytes >= 6 else { throw EluEventFilterFailure.invalid }
                bytes -= 6
            }
        }
        mutating func project(_ value: Any, depth: Int) throws -> EluJSONValue {
            guard depth <= 16, nodes > 0, bytes >= 32 else { throw EluEventFilterFailure.invalid }
            nodes -= 1; bytes -= 32
            switch value {
            case is NSNull: return .null
            case let value as String:
                try charge(value); return .string(value)
            case let value as NSNumber:
                if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
                guard value.doubleValue.isFinite else { throw EluEventFilterFailure.invalid }
                return CFNumberIsFloatType(value) ? .number(value.doubleValue) : .integer(value.int64Value)
            case let value as Date:
                guard value.timeIntervalSinceReferenceDate.isFinite else { throw EluEventFilterFailure.invalid }
                let text = EluRFC3339.string(from: value); try charge(text); return .string(text)
            case let value as URL:
                let text = value.absoluteString; try charge(text); return .string(text)
            case let value as NSArray:
                guard value.count <= 1_024 else { throw EluEventFilterFailure.invalid }
                let id = ObjectIdentifier(value)
                guard ancestors.insert(id).inserted else { throw EluEventFilterFailure.invalid }
                defer { ancestors.remove(id) }
                var result: [EluJSONValue] = []
                for index in 0..<value.count { result.append(try project(value.object(at: index), depth: depth + 1)) }
                return .array(result)
            case let value as NSDictionary:
                guard value.count <= 1_024 else { throw EluEventFilterFailure.invalid }
                let id = ObjectIdentifier(value)
                guard ancestors.insert(id).inserted else { throw EluEventFilterFailure.invalid }
                defer { ancestors.remove(id) }
                var result: [String: EluJSONValue] = [:]
                for rawKey in value.allKeys {
                    guard let key = rawKey as? String, EluFacadeJSON.isStorableKey(key),
                          let member = value.object(forKey: rawKey) else { throw EluEventFilterFailure.invalid }
                    try charge(key); result[key] = try project(member, depth: depth + 1)
                }
                return .object(result)
            default: throw EluEventFilterFailure.invalid
            }
        }
    }
}

/// One original submit may renew authority or retry storage. The lock protects
/// only this memo; arbitrary customer code is never called while it is held.
final class EluEventFilterAttempt: @unchecked Sendable {
    let person: EluEventPersonChanges
    let allowsPersonChanges: Bool
    private let lock = NSLock()
    private var original: (UUID, EluV1CaptureCommand, [String: EluJSONValue])?
    private var current: (@Sendable () -> Bool)?
    private var outcome: Result<EluFilteredEvent, EluEventFilterFailure>?

    init(person: EluEventPersonChanges = .init(set: nil, setOnce: nil), allowsPersonChanges: Bool = false) {
        self.person = person; self.allowsPersonChanges = allowsPersonChanges
    }

    func apply(owner: UUID, command: EluV1CaptureCommand, mergedProperties: [String: EluJSONValue],
               isCurrent: @escaping @Sendable () -> Bool,
               body: () throws -> EluFilteredEvent) throws -> EluFilteredEvent {
        lock.lock()
        if let original {
            let result = outcome, retainedCurrent = current
            let matches = original.0 == owner && original.1 == command && original.2 == mergedProperties
            lock.unlock()
            guard matches, let result, retainedCurrent?() == true, isCurrent() else { throw EluEventFilterFailure.withdrawn }
            return try result.get()
        }
        original = (owner, command, mergedProperties); current = isCurrent
        lock.unlock()
        let result: Result<EluFilteredEvent, EluEventFilterFailure>
        do {
            guard isCurrent() else { throw EluEventFilterFailure.withdrawn }
            let value = try body()
            guard isCurrent() else { throw EluEventFilterFailure.withdrawn }
            result = .success(value)
        } catch let failure as EluEventFilterFailure { result = .failure(failure) }
        catch { result = .failure(.invalid) }
        lock.lock(); outcome = result; lock.unlock()
        return try result.get()
    }

    func acceptedPersonChanges() -> EluEventPersonChanges {
        lock.lock(); defer { lock.unlock() }
        if let outcome, case let .success(value) = outcome { return value.person }
        return person
    }
}
