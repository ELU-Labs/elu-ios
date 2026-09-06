import Foundation

enum EluMigrationSourceRejection: Error, Equatable, Sendable {
    case unsupportedSchema
    case unavailable
    case unreadable(EluLegacyStateKey)
    case queueUnreadable
    case valueTooLarge(EluLegacyStateKey)
    case invalidValue(EluLegacyStateKey)
    case invalidQueue
}

enum EluMigrationQuarantineReason: Equatable, Sendable {
    case priorQuarantine
    case oversizedCheckpoint
    case malformedCheckpoint
    case unsupportedCheckpointSchema
    case unknownCheckpointExtension
    case invalidCheckpoint
    case targetConflict
    case readBackMissing
    case readBackMismatch
}

/// The result of one coordinator run. Every case is a code with no
/// identifiers or values attached, so it can be reported as is.
enum EluMigrationOutcome: Equatable, Sendable {
    case completed(importedLegacyState: Bool)
    case alreadyComplete
    case sourceRejected(EluMigrationSourceRejection)
    case quarantined(EluMigrationQuarantineReason)
    case interrupted(atPhase: EluMigrationPhase)
}

struct EluMigrationRunReport: Equatable, Sendable {
    var outcome: EluMigrationOutcome
    var phaseBefore: EluMigrationPhase
    var phaseAfter: EluMigrationPhase
    var sourceReadCount: Int
}

enum EluMigrationMetric: Equatable, Sendable {
    case phaseEntered(EluMigrationPhase)
    case queuePrefixTruncated(retainedCount: Int)
    case outcome(EluMigrationOutcome)
}

protocol EluMigrationMetricsRecording: Sendable {
    func record(_ metric: EluMigrationMetric)
}

/// Points at which a test can make the coordinator fail as if the process
/// had been killed. Each one sits immediately before or after a durable
/// side effect.
enum EluMigrationFaultPoint: Equatable, Sendable {
    case beforeCheckpointWrite(EluMigrationPhase)
    case afterCheckpointWrite(EluMigrationPhase)
    case beforeTargetAdopt
    case afterTargetAdopt
    case beforeReadBack
}

protocol EluMigrationFaultInjecting: Sendable {
    func hit(_ point: EluMigrationFaultPoint) throws
}

enum EluMigrationCoordinatorError: Error, Equatable, Sendable {
    case faultInjected(EluMigrationFaultPoint)
}

/// Drives one migration from a former storage layout into the runtime.
///
/// The coordinator serializes every read and write through this actor. It
/// reads the source in one pass, persists what it read as an `importing`
/// checkpoint, and then advances the checkpoint through `committed`,
/// `verified`, and `complete`, writing the whole document atomically at each
/// step. A run that stops anywhere resumes from the persisted phase; the
/// source is never read again once a checkpoint exists, the target adopts a
/// checkpoint id at most once, and nothing in the source is ever modified.
actor EluMigrationCoordinator {
    private let source: any EluLegacyStateSource
    private let target: any EluMigrationTarget
    private let store: any EluMigrationCheckpointStore
    private let supportedSourceSchemaVersions: ClosedRange<Int>
    private let clock: @Sendable () -> Date
    private let checkpointIdGenerator: @Sendable () -> String
    private let streamIdGenerator: @Sendable () -> String
    private let metrics: (any EluMigrationMetricsRecording)?
    private let faultInjector: (any EluMigrationFaultInjecting)?

    private var sourceReadCount = 0
    private var initialPhase = EluMigrationPhase.unseen
    private var currentPhase = EluMigrationPhase.unseen

    init(
        source: any EluLegacyStateSource,
        target: any EluMigrationTarget,
        store: any EluMigrationCheckpointStore,
        supportedSourceSchemaVersions: ClosedRange<Int> = 1 ... 1,
        clock: @escaping @Sendable () -> Date = { Date() },
        checkpointIdGenerator: @escaping @Sendable () -> String = {
            "checkpoint_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        },
        streamIdGenerator: @escaping @Sendable () -> String = {
            "stream_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        },
        metrics: (any EluMigrationMetricsRecording)? = nil,
        faultInjector: (any EluMigrationFaultInjecting)? = nil
    ) {
        self.source = source
        self.target = target
        self.store = store
        self.supportedSourceSchemaVersions = supportedSourceSchemaVersions
        self.clock = clock
        self.checkpointIdGenerator = checkpointIdGenerator
        self.streamIdGenerator = streamIdGenerator
        self.metrics = metrics
        self.faultInjector = faultInjector
    }

    /// Advances the migration as far as it can and reports where it stopped.
    /// It never throws: I/O and injected failures surface as `interrupted`
    /// with the last durable phase, and the next run resumes from there.
    func run() -> EluMigrationRunReport {
        sourceReadCount = 0
        initialPhase = .unseen
        currentPhase = .unseen
        let outcome: EluMigrationOutcome
        do {
            outcome = try advance()
        } catch {
            // The phase recorded here is the last one written durably, so
            // the next run resumes from what is actually on disk.
            outcome = .interrupted(atPhase: currentPhase)
        }
        metrics?.record(.outcome(outcome))
        return EluMigrationRunReport(
            outcome: outcome,
            phaseBefore: initialPhase,
            phaseAfter: currentPhase,
            sourceReadCount: sourceReadCount
        )
    }

    private func advance() throws -> EluMigrationOutcome {
        if try store.hasQuarantinedDocument() {
            return .quarantined(.priorQuarantine)
        }

        var checkpoint: EluMigrationCheckpoint
        switch try store.load() {
        case let .unreadable(defect):
            try store.quarantine()
            return .quarantined(Self.quarantineReason(for: defect))
        case let .loaded(existing):
            checkpoint = existing
            initialPhase = existing.phase
            currentPhase = existing.phase
        case .missing:
            switch try importFromSource() {
            case let .rejected(rejection):
                return .sourceRejected(rejection)
            case let .imported(imported):
                checkpoint = imported
                currentPhase = imported.phase
                metrics?.record(.phaseEntered(imported.phase))
                try faultInjector?.hit(.afterCheckpointWrite(imported.phase))
            }
        }

        if initialPhase == .complete {
            return .alreadyComplete
        }

        while checkpoint.phase != .complete {
            let quarantine: EluMigrationQuarantineReason?
            switch checkpoint.phase {
            case .unseen:
                throw EluMigrationCheckpointError.invalidPhase
            case .importing:
                quarantine = try commit(&checkpoint)
            case .committed:
                quarantine = try verify(&checkpoint)
            case .verified:
                try complete(&checkpoint)
                quarantine = nil
            case .complete:
                quarantine = nil
            }
            if let quarantine {
                return .quarantined(quarantine)
            }
        }
        return .completed(importedLegacyState: checkpoint.snapshot != nil)
    }

    // MARK: - Phase transitions

    private func commit(
        _ checkpoint: inout EluMigrationCheckpoint
    ) throws -> EluMigrationQuarantineReason? {
        try faultInjector?.hit(.beforeTargetAdopt)
        do {
            _ = try target.adopt(checkpoint)
        } catch EluMigrationTargetError.checkpointConflict {
            try store.quarantine()
            return .targetConflict
        }
        try faultInjector?.hit(.afterTargetAdopt)

        var next = checkpoint
        next.phase = .committed
        next.committedAt = clock()
        try write(next, into: &checkpoint)
        return nil
    }

    private func verify(
        _ checkpoint: inout EluMigrationCheckpoint
    ) throws -> EluMigrationQuarantineReason? {
        guard let snapshot = checkpoint.snapshot else {
            throw EluMigrationCheckpointError.invalidPhase
        }
        try faultInjector?.hit(.beforeReadBack)
        guard let readBack = try target.readBack() else {
            try store.quarantine()
            return .readBackMissing
        }
        guard readBack.checkpointId == checkpoint.checkpointId,
              readBack.identity == snapshot.identity,
              readBack.context == snapshot.context,
              readBack.stream == snapshot.stream,
              readBack.importedQueueRecordCount == snapshot.queuePrefix.records.count
        else {
            try store.quarantine()
            return .readBackMismatch
        }

        var next = checkpoint
        next.phase = .verified
        next.verifiedAt = clock()
        try write(next, into: &checkpoint)
        return nil
    }

    private func complete(
        _ checkpoint: inout EluMigrationCheckpoint
    ) throws {
        var next = checkpoint
        next.phase = .complete
        next.completedAt = clock()
        try write(next, into: &checkpoint)
    }

    /// Persists `next` and only then publishes it as the current checkpoint.
    /// The after-write fault fires once the document is durable, so a run
    /// interrupted there reports the phase that is actually on disk.
    private func write(
        _ next: EluMigrationCheckpoint,
        into checkpoint: inout EluMigrationCheckpoint
    ) throws {
        try faultInjector?.hit(.beforeCheckpointWrite(next.phase))
        try store.save(next)
        checkpoint = next
        currentPhase = next.phase
        metrics?.record(.phaseEntered(next.phase))
        try faultInjector?.hit(.afterCheckpointWrite(next.phase))
    }

    private func writeInitial(_ checkpoint: EluMigrationCheckpoint) throws {
        try faultInjector?.hit(.beforeCheckpointWrite(checkpoint.phase))
        try store.save(checkpoint)
    }

    // MARK: - Source import

    private enum ImportResult {
        case imported(EluMigrationCheckpoint)
        case rejected(EluMigrationSourceRejection)
    }

    private func importFromSource() throws -> ImportResult {
        let descriptor = source.descriptor
        guard supportedSourceSchemaVersions.contains(descriptor.schemaVersion),
              EluIdentityState.valid(descriptor.sourceSchema, maximumLength: 128)
        else {
            return .rejected(.unsupportedSchema)
        }
        let sourceRecord = try EluMigrationSourceRecord(descriptor: descriptor)

        let anonymousId: String?
        do {
            anonymousId = try readString(.anonymousId, maximumLength: 256)
        } catch let rejection as EluMigrationSourceRejection {
            return .rejected(rejection)
        }

        let now = clock()
        guard let anonymousId else {
            // No identity to carry over. Record the witness so later runs
            // and the runtime know the source was inspected and found empty.
            let witness = try EluMigrationCheckpoint(
                checkpointId: checkpointIdGenerator(),
                phase: .complete,
                source: sourceRecord,
                snapshot: nil,
                importedAt: now,
                committedAt: now,
                verifiedAt: now,
                completedAt: now
            )
            try writeInitial(witness)
            return .imported(witness)
        }

        let snapshot: EluMigrationSnapshot
        do {
            snapshot = try readSnapshot(anonymousId: anonymousId)
        } catch let rejection as EluMigrationSourceRejection {
            return .rejected(rejection)
        }

        let checkpoint = try EluMigrationCheckpoint(
            checkpointId: checkpointIdGenerator(),
            phase: .importing,
            source: sourceRecord,
            snapshot: snapshot,
            importedAt: now
        )
        try writeInitial(checkpoint)
        return .imported(checkpoint)
    }

    private func readSnapshot(anonymousId: String) throws -> EluMigrationSnapshot {
        let userId = try readString(.userId, maximumLength: 512)
        let optedOut = try readBool(.optedOut) ?? false
        let identity: EluMigrationIdentitySnapshot
        do {
            identity = try EluMigrationIdentitySnapshot(
                anonymousId: anonymousId,
                userId: userId,
                optedOut: optedOut
            )
        } catch {
            throw EluMigrationSourceRejection.invalidValue(.anonymousId)
        }

        let context: EluMigrationContextSnapshot
        do {
            context = try EluMigrationContextSnapshot(
                superProperties: readPropertyMap(.superProperties),
                groups: readStringMap(.groups),
                flagPersonProperties: readPropertyMap(.flagPersonProperties),
                flagGroupProperties: readGroupedPropertyMap(.flagGroupProperties)
            )
        } catch let rejection as EluMigrationSourceRejection {
            throw rejection
        } catch {
            throw EluMigrationSourceRejection.invalidValue(.superProperties)
        }

        let stream: EluMigrationStreamSnapshot
        do {
            let streamId = try readString(.streamId, maximumLength: 256) ?? streamIdGenerator()
            let nextSequence = try readInteger(.nextSequence) ?? 0
            stream = try EluMigrationStreamSnapshot(streamId: streamId, nextSequence: nextSequence)
        } catch let rejection as EluMigrationSourceRejection {
            throw rejection
        } catch {
            throw EluMigrationSourceRejection.invalidValue(.streamId)
        }

        let queuePrefix = try readQueuePrefix()
        do {
            return try EluMigrationSnapshot(
                identity: identity,
                context: context,
                stream: stream,
                queuePrefix: queuePrefix
            )
        } catch {
            throw EluMigrationSourceRejection.invalidValue(.anonymousId)
        }
    }

    private func readQueuePrefix() throws -> EluMigrationQueuePrefix {
        let maximumRecords = EluMigrationQueuePrefix.maximumRecords
        let maximumBytes = EluMigrationQueuePrefix.maximumBytes
        let records: [EluLegacyQueuedRecord]
        do {
            records = try source.readQueuedRecords(
                maximumCount: maximumRecords + 1,
                maximumBytes: maximumBytes + EluMigrationQueuedRecord.maximumPayloadBytes
            )
        } catch {
            throw EluMigrationSourceRejection.queueUnreadable
        }
        sourceReadCount += 1

        var retained: [EluMigrationQueuedRecord] = []
        var retainedBytes = 0
        var truncated = false
        var previousPosition: Int64?
        for record in records {
            if let previousPosition, record.position <= previousPosition {
                throw EluMigrationSourceRejection.invalidQueue
            }
            previousPosition = record.position
            guard let converted = try? EluMigrationQueuedRecord(
                position: record.position,
                payload: record.payload
            ) else {
                throw EluMigrationSourceRejection.invalidQueue
            }
            if retained.count >= maximumRecords || retainedBytes + converted.payload.count > maximumBytes {
                truncated = true
                break
            }
            retained.append(converted)
            retainedBytes += converted.payload.count
        }
        if truncated {
            metrics?.record(.queuePrefixTruncated(retainedCount: retained.count))
        }
        do {
            return try EluMigrationQueuePrefix(records: retained, truncated: truncated)
        } catch {
            throw EluMigrationSourceRejection.invalidQueue
        }
    }

    // MARK: - Typed source reads

    private func readValue(_ key: EluLegacyStateKey) throws -> EluLegacyStateValue? {
        let value: EluLegacyStateValue?
        do {
            value = try source.readValue(for: key, maximumBytes: key.maximumBytes)
        } catch EluLegacyStateSourceError.unavailable {
            throw EluMigrationSourceRejection.unavailable
        } catch {
            throw EluMigrationSourceRejection.unreadable(key)
        }
        sourceReadCount += 1
        return value
    }

    private func readString(_ key: EluLegacyStateKey, maximumLength: Int) throws -> String? {
        guard let value = try readValue(key) else { return nil }
        guard case let .string(string) = value else {
            throw EluMigrationSourceRejection.invalidValue(key)
        }
        guard string.utf8.count <= key.maximumBytes else {
            throw EluMigrationSourceRejection.valueTooLarge(key)
        }
        guard EluIdentityState.valid(string, maximumLength: maximumLength) else {
            throw EluMigrationSourceRejection.invalidValue(key)
        }
        return string
    }

    private func readBool(_ key: EluLegacyStateKey) throws -> Bool? {
        guard let value = try readValue(key) else { return nil }
        guard case let .bool(flag) = value else {
            throw EluMigrationSourceRejection.invalidValue(key)
        }
        return flag
    }

    private func readInteger(_ key: EluLegacyStateKey) throws -> Int64? {
        guard let value = try readValue(key) else { return nil }
        guard case let .integer(number) = value, number >= 0 else {
            throw EluMigrationSourceRejection.invalidValue(key)
        }
        return number
    }

    private func readObject(_ key: EluLegacyStateKey) throws -> [String: EluJSONValue]? {
        guard let value = try readValue(key) else { return nil }
        guard case let .json(json) = value, case let .object(object) = json else {
            throw EluMigrationSourceRejection.invalidValue(key)
        }
        do {
            try json.validate()
        } catch {
            throw EluMigrationSourceRejection.invalidValue(key)
        }
        try enforceEncodedSize(of: object, key: key)
        return object
    }

    private func readPropertyMap(_ key: EluLegacyStateKey) throws -> [String: EluJSONValue] {
        try readObject(key) ?? [:]
    }

    private func readStringMap(_ key: EluLegacyStateKey) throws -> [String: String] {
        guard let object = try readObject(key) else { return [:] }
        var result: [String: String] = [:]
        result.reserveCapacity(object.count)
        for (name, value) in object {
            guard case let .string(string) = value else {
                throw EluMigrationSourceRejection.invalidValue(key)
            }
            result[name] = string
        }
        return result
    }

    private func readGroupedPropertyMap(
        _ key: EluLegacyStateKey
    ) throws -> [String: [String: EluJSONValue]] {
        guard let object = try readObject(key) else { return [:] }
        var result: [String: [String: EluJSONValue]] = [:]
        result.reserveCapacity(object.count)
        for (name, value) in object {
            guard case let .object(nested) = value else {
                throw EluMigrationSourceRejection.invalidValue(key)
            }
            result[name] = nested
        }
        return result
    }

    private func enforceEncodedSize(of object: [String: EluJSONValue], key: EluLegacyStateKey) throws {
        let encoded: Data
        do {
            encoded = try EluStateCoding.encoder().encode(object)
        } catch {
            throw EluMigrationSourceRejection.invalidValue(key)
        }
        guard encoded.count <= key.maximumBytes else {
            throw EluMigrationSourceRejection.valueTooLarge(key)
        }
    }

    private static func quarantineReason(
        for defect: EluMigrationCheckpointDefect
    ) -> EluMigrationQuarantineReason {
        switch defect {
        case .oversized:
            return .oversizedCheckpoint
        case .malformed:
            return .malformedCheckpoint
        case .unsupportedSchemaVersion:
            return .unsupportedCheckpointSchema
        case .unknownRecordExtension:
            return .unknownCheckpointExtension
        case .invalid:
            return .invalidCheckpoint
        }
    }
}
