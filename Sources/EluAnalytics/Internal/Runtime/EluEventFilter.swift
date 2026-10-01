import Foundation

struct EluEventPersonChanges: Equatable, Sendable {
    let set: [String: EluJSONValue]?
    let setOnce: [String: EluJSONValue]?
    var hasIntent: Bool { self.set != nil || setOnce != nil }
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
               person: EluEventPersonChanges, allowsPersonChanges: Bool, mutationProjection: Bool = false) throws -> EluFilteredEvent {
        guard valid else { throw EluEventFilterFailure.invalid }
        var mutable = mergedProperties.filter { (mutationProjection || !Self.protected($0.key)) && !denylist.contains(Array($0.key.utf16)) }
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
        if !mutationProjection {
            guard EluFacadeJSON.identifier(transformed.event, maximumLength: 512) != nil,
                  transformed.timestamp.timeIntervalSinceReferenceDate.isFinite else { throw EluEventFilterFailure.invalid }
        }
        var budget = ProjectionBudget()
        mutable = try budget.properties(transformed.properties)
        let set = try transformed.set.map { try budget.properties($0) }
        let setOnce = try transformed.setOnce.map { try budget.properties($0) }
        let changes = EluEventPersonChanges(set: set, setOnce: setOnce)
        guard allowsPersonChanges || !changes.hasIntent else { throw EluEventFilterFailure.unsupportedPersonChanges }
        return EluFilteredEvent(command: EluV1CaptureCommand(kind: command.kind, name: mutationProjection ? command.name : transformed.event,
            occurredAt: mutationProjection ? command.occurredAt : transformed.timestamp, properties: mutable, versions: command.versions), person: changes)
    }

    /// Mutation envelopes are projections only: their name, clock and identity
    /// targets are not event records and cannot be replaced by customer code.
    /// A missing result is a deliberate no-op, not an unfiltered fallback.
    func applyMutation(_ transition: EluRuntimeMutationTransition, identity: EluIdentityState,
                       occurredAt: Date, versions: EluVersionContext) throws -> EluRuntimeMutationTransition? {
        guard active else { return transition }
        func project(_ name: String, _ properties: [String: EluJSONValue],
                     person: EluEventPersonChanges = .init(set: nil, setOnce: nil)) throws -> EluFilteredEvent {
            var merged = identity.superProperties
            merged.merge(properties) { _, new in new }
            return try apply(.init(kind: .capture, name: name, occurredAt: occurredAt,
                properties: properties, versions: versions), mergedProperties: merged,
                person: person, allowsPersonChanges: true, mutationProjection: true)
        }
        func object(_ value: EluJSONValue?) throws -> [String: EluJSONValue]? {
            guard let value else { return nil }
            if case .null = value { return nil }
            guard case let .object(map) = value else { throw EluEventFilterFailure.invalid }
            // Nested mutation maps obey the same protected-name rules as an
            // ordinary caller's person properties, after the hook has finished.
            return map.filter { !Self.protected($0.key) }
        }
        func person(_ set: [String: EluJSONValue], _ once: [String: EluJSONValue]) throws -> EluRuntimeMutationTransition? {
            let value = try project("$set", ["$set": .object(set), "$set_once": .object(once)])
            let next = try object(value.command.properties["$set"]), nextOnce = try object(value.command.properties["$set_once"])
            guard !(next ?? [:]).isEmpty || !(nextOnce ?? [:]).isEmpty else { return nil }
            return .setPersonProperties(set: next ?? [:], setOnce: nextOnce ?? [:], unset: [])
        }
        func group(_ type: String, _ key: String, _ set: [String: EluJSONValue]?) throws -> EluRuntimeMutationTransition? {
            let changed = identity.groups[type] != key
            guard changed || set != nil else { return nil }
            var properties: [String: EluJSONValue] = ["$group_type": .string(type), "$group_key": .string(key)]
            if let set { properties["$group_set"] = .object(set) }
            let value = try project("$groupidentify", properties)
            let next = try object(value.command.properties["$group_set"])
            if let next {
                return changed ? .group(groupType: type, groupKey: key, set: next, setOnce: [:], unset: [])
                    : .setGroupProperties(groupType: type, groupKey: key, set: next, setOnce: [:], unset: [])
            }
            return changed ? .associateGroup(groupType: type, groupKey: key) : nil
        }
        switch transition {
        case let .identify(userId, set, setOnce):
            if identity.userId == userId {
                guard !set.isEmpty || !setOnce.isEmpty else { return nil }
                return try person(set, setOnce)
            }
            let value = try project("$identify", ["distinct_id": .string(userId),
                "$anon_distinct_id": .string(identity.userId ?? identity.anonymousId)],
                person: .init(set: set, setOnce: setOnce))
            return .identify(userId: userId, set: value.person.set ?? [:], setOnce: value.person.setOnce ?? [:])
        case let .linkAlias(aliasId):
            guard let canonical = identity.userId else { throw EluEventFilterFailure.invalid }
            _ = try project("$create_alias", ["alias": .string(aliasId), "distinct_id": .string(canonical)])
            return transition
        case let .setPersonProperties(set, setOnce, unset):
            // The released unset operation is not a legacy event projection.
            guard unset.isEmpty else { return transition }
            return try person(set, setOnce)
        case let .associateGroup(type, key): return try group(type, key, nil)
        case let .group(type, key, set, setOnce, unset), let .setGroupProperties(type, key, set, setOnce, unset):
            // Public group supplies a set map only. Do not silently erase typed
            // internal set-once/unset operations that have no legacy envelope.
            guard setOnce.isEmpty, unset.isEmpty else { return transition }
            return try group(type, key, set)
        }
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
    private let continuationAdmission: @Sendable () -> Bool
    private let lock = NSLock()
    private var original: (UUID, EluV1CaptureCommand, [String: EluJSONValue])?
    private var current: (@Sendable () -> Bool)?
    private var outcome: Result<EluFilteredEvent, EluEventFilterFailure>?
    private var continuation: (@Sendable () -> Bool)?
    private var acceptedWarning: (EluV1CaptureResult, EluEventFilterAttempt)?

    init(person: EluEventPersonChanges = .init(set: nil, setOnce: nil), allowsPersonChanges: Bool = false,
         continuationAdmission: @escaping @Sendable () -> Bool = { true }) {
        self.person = person; self.allowsPersonChanges = allowsPersonChanges
        self.continuationAdmission = continuationAdmission
    }

    func apply(owner: UUID, command: EluV1CaptureCommand, mergedProperties: [String: EluJSONValue],
               isCurrent: @escaping @Sendable () -> Bool,
               continuationIsCurrent: (@Sendable () -> Bool)? = nil,
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
        continuation = continuationIsCurrent
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

    /// The queue can emit at most one bypassed warning for this consumed rate
    /// attempt. Retain its accepted result for the same Runtime, never a retry
    /// of the rejected outer event or a second independent queue owner.
    func warningAttempt() -> EluEventFilterAttempt {
        EluEventFilterAttempt(allowsPersonChanges: allowsPersonChanges, continuationAdmission: continuationAdmission)
    }
    func retainWarning(_ result: EluV1CaptureResult, attempt: EluEventFilterAttempt) {
        guard case .accepted = result else { return }
        lock.lock(); defer { lock.unlock() }
        if acceptedWarning == nil { acceptedWarning = (result, attempt) }
    }
    func takeWarning() -> (EluV1CaptureResult, EluEventFilterAttempt)? {
        lock.lock(); defer { lock.unlock() }
        let value = acceptedWarning; acceptedWarning = nil; return value
    }

    /// The callback's original source/intent survives its own context commit,
    /// but cannot be reused after a new external intent or source replacement.
    func mayContinuePersonMutation() -> Bool {
        lock.lock(); let validate = continuation; lock.unlock()
        return validate?() == true && continuationAdmission()
    }

    func acceptedPersonChanges() -> EluEventPersonChanges {
        lock.lock(); defer { lock.unlock() }
        if let outcome, case let .success(value) = outcome { return value.person }
        return person
    }
}
