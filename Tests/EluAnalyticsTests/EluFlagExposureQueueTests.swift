import Foundation
import XCTest
@testable import EluAnalytics

final class EluFlagExposureQueueTests: XCTestCase {
    private func make(limits: EluRuntimeQueueLimits? = nil, fault: DeliveryFault? = nil) async throws -> NativeSessionHarness {
        let h = NativeSessionHarness(try await DeliveryHarness.make(limits: limits, fault: fault))
        try await h.publish()
        return h
    }
    private func versions() throws -> EluVersionContext {
        try .init(runtime: .init(name: "elu-ios", version: "0.2.0"), facade: .init(name: "Elu", version: "1"))
    }
    private func report(_ h: NativeSessionHarness, key: String = "flag", value: EluV1FlagValue? = .bool(true),
                        admissionGuard current: @escaping @Sendable () -> Bool = { true }) async throws -> EluV1CaptureResult {
        let identity = try await h.queue.snapshot().identity
        return await h.queue.captureFlagExposure(.init(kind: .capture, name: "$feature_flag_called", occurredAt: h.base.now,
            properties: ["$feature_flag": .string(key)], versions: try versions()),
            exposure: .init(anonymousId: identity.anonymousId, digest: try EluFlagExposureLedger.digest(key: key, value: value)),
            admissionGuard: current)
    }
    private func ledger(_ h: NativeSessionHarness) throws -> EluFlagExposureLedger {
        try .decode(h.bytes("SELECT metadata FROM flag_exposure_state"))
    }
    private func accepted(_ result: EluV1CaptureResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .accepted = result else { return XCTFail("Expected accepted exposure: \(result)", file: file, line: line) }
    }
    private func rejected(_ result: EluV1CaptureResult, _ reason: EluV1CaptureRejection,
                          file: StaticString = #filePath, line: UInt = #line) {
        guard case let .rejected(actual, _) = result else { return XCTFail("Unexpected acceptance", file: file, line: line) }
        XCTAssertEqual(actual, reason, file: file, line: line)
    }

    func testCodecIsClosedBoundedAndDistinguishesTypedValuesAndExactUTF16Keys() throws {
        let values: [EluV1FlagValue?] = [nil, .null, .bool(true), .string(Array("true".utf16)), .number(1), .string(Array("1".utf16))]
        let digests = try Set(values.map { try EluFlagExposureLedger.digest(key: "flag", value: $0) })
        XCTAssertEqual(digests.count, values.count)
        XCTAssertNotEqual(try EluFlagExposureLedger.digest(key: "é", value: .bool(true)),
                          try EluFlagExposureLedger.digest(key: "e\u{301}", value: .bool(true)))
        let ledger = EluFlagExposureLedger(anonymousId: "visitor", digests: digests)
        XCTAssertEqual(try EluFlagExposureLedger.decode(ledger.encoded()), ledger)
        for bad in ["{}", "{\"anonymousId\":\"visitor\",\"digests\":[],\"extra\":1}",
                    "{\"anonymousId\":\"visitor\",\"digests\":[],\"digests\":[]}",
                    "{\"anonymousId\":\"visitor\",\"digests\":[\"invalid\"]}"] {
            XCTAssertThrowsError(try EluFlagExposureLedger.decode(Data(bad.utf8)))
        }
        let full = EluFlagExposureLedger(anonymousId: "visitor", digests: Set((0..<4096).map { String(format: "%064x", $0) }))
        XCTAssertLessThan(try full.encoded().count, EluFlagExposureLedger.maximumBytes)
        var overflow = full; overflow.digests.insert(String(repeating: "f", count: 64))
        XCTAssertThrowsError(try overflow.encoded())
    }

    func testAcceptedExposureSurvivesAckReopenIdentifyAndConsentButResetClearsAtomically() async throws {
        let h = try await make(); defer { h.base.remove() }
        accepted(try await report(h)); let first = try ledger(h)
        rejected(try await report(h), .exposureAlreadyRecorded)
        let records = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
        let stream = try await h.queue.snapshot().streamId
        _ = try await h.queue.acknowledge(records.map { .init(streamId: stream, sequence: $0.sequence, kind: $0.kind, recordId: $0.recordId) })
        await h.queue.close(); try await h.reopen(); try await h.publish()
        XCTAssertEqual(try ledger(h), first); rejected(try await report(h), .exposureAlreadyRecorded)
        _ = try await h.queue.applyOwnedMutation(.identify(userId: "account-a", set: [:], setOnce: [:]),
            versions: versions(), expectedGeneration: h.queue.snapshot().generation)
        try await h.publish(); rejected(try await report(h), .exposureAlreadyRecorded)
        _ = try await h.queue.setOptedOut(true, expectedGeneration: h.queue.snapshot().generation)
        _ = try await h.queue.setOptedOut(false, expectedGeneration: h.queue.snapshot().generation)
        try await h.publish(); rejected(try await report(h), .exposureAlreadyRecorded)
        for rotateDevice in [false, true] {
            _ = try await h.queue.reset(expectedGeneration: h.queue.snapshot().generation, resetDeviceId: rotateDevice)
            XCTAssertTrue(try ledger(h).digests.isEmpty)
            try await h.publish(); accepted(try await report(h))
        }
        await h.queue.close()
    }

    func testTwoConcurrentReportsCommitOneEventAndMarker() async throws {
        let h = try await make(); defer { h.base.remove() }
        async let a = report(h); async let b = report(h)
        let results = try await [a, b]
        XCTAssertEqual(results.filter { if case .accepted = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(try ledger(h).digests.count, 1)
        let snapshot = try await h.queue.snapshot(); XCTAssertEqual(snapshot.queuedCount, 1)
        await h.queue.close()
    }

    func testQuotaKnownRollbackAndFinalRevocationDoNotConsumeExposure() async throws {
        let fault = DeliveryFault(), h = try await make(limits: .init(maximumCount: 1), fault: fault)
        defer { h.base.remove() }
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        rejected(try await report(h), .storageProvenNotCommitted)
        XCTAssertTrue(try ledger(h).digests.isEmpty)
        fault.action = nil
        let current = ExposureCurrent()
        fault.action = { if $0 == .beforeCommit { current.withdraw() } }
        rejected(try await report(h, admissionGuard: { current.read() }), .authorityAbsent)
        XCTAssertTrue(try ledger(h).digests.isEmpty)
        fault.action = nil; accepted(try await report(h))
        rejected(try await report(h, key: "second"), .queueLimit)
        XCTAssertEqual(try ledger(h).digests.count, 1)
        let records = try await h.queue.peek(maximumCount: 1, maximumBytes: 1_000_000)
        let stream = try await h.queue.snapshot().streamId
        _ = try await h.queue.acknowledge(records.map { .init(streamId: stream, sequence: $0.sequence, kind: $0.kind, recordId: $0.recordId) })
        accepted(try await report(h, key: "second"))
        await h.queue.close()
    }

    func testAmbiguousCommitReopenDoesNotDuplicateAndResetRollbackKeepsLedger() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        fault.action = { if $0 == .afterCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        rejected(try await report(h), .storageOutcomeUnknown)
        fault.action = nil; await h.queue.close(); try await h.reopen(); try await h.publish()
        rejected(try await report(h), .exposureAlreadyRecorded)
        let before = try ledger(h)
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { _ = try await h.queue.reset(expectedGeneration: h.queue.snapshot().generation); XCTFail("Expected rollback") } catch {}
        fault.action = nil; XCTAssertEqual(try ledger(h), before)
        await h.queue.close()
    }

    func testSaturationPreservesHistoryAndOrdinaryAnalyticsUntilReset() async throws {
        let h = try await make(); defer { h.base.remove() }
        let visitor = try await h.queue.snapshot().identity.anonymousId
        let full = EluFlagExposureLedger(anonymousId: visitor, digests: Set((0..<4096).map { String(format: "%064x", $0) }))
        await h.queue.close()
        let hex = try full.encoded().map { String(format: "%02x", $0) }.joined()
        try h.base.sql("UPDATE flag_exposure_state SET metadata=X'\(hex)'")
        try await h.reopen(); try await h.publish()
        rejected(try await report(h), .exposureLedgerFull)
        accepted(await h.base.capture()); XCTAssertEqual(try ledger(h), full)
        _ = try await h.queue.reset(expectedGeneration: h.queue.snapshot().generation)
        try await h.publish(); accepted(try await report(h))
        await h.queue.close()
    }

    func testAll32PriorOwnedSchemasUpgradeAndReopenWithoutChangingQueueOrIdentity() async throws {
        for version in Array(1...16) + Array(25...40) {
            let base = version > 32 ? version - 32 : version > 24 ? version - 24 : version > 8 ? version - 8 : version
            let h = try await make(); defer { h.base.remove() }
            accepted(await h.base.capture())
            if base.isMultiple(of: 2) { try await h.queue.ensureFlagSchema() }
            if base >= 3 { try await h.queue.ensureReplaySchema() }
            if base >= 5 { try await h.queue.ensureReplayDeliverySchema() }
            if base >= 7 { try await h.queue.ensureNativeReplayAuthoritySchema() }
            let before = try await h.queue.snapshot(), records = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
            await h.queue.close()
            try h.base.sql("DROP TABLE flag_exposure_state; \(version < 33 ? "DROP TABLE person_identity_state;" : "") \(version < 25 ? "DROP TABLE native_diagnostics_state;" : "") \(version <= 8 ? "DROP TABLE capture_session_history;" : "") PRAGMA user_version=\(version)")
            try await h.reopen()
            XCTAssertEqual(try h.base.schemaVersion(), Int64(base + 40))
            let after = try await h.queue.snapshot(), restored = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
            XCTAssertEqual(after, before); XCTAssertEqual(records, restored)
            XCTAssertEqual(try ledger(h), .init(anonymousId: before.identity.anonymousId))
            await h.queue.close(); try await h.reopen()
            XCTAssertEqual(try h.base.schemaVersion(), Int64(base + 40)); await h.queue.close()
        }
    }

    func testMigrationRollbackAndCorruptStreamOrVisitorFailClosed() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        let before = try await h.queue.snapshot()
        await h.queue.close(); try h.base.sql("DROP TABLE flag_exposure_state; PRAGMA user_version=33")
        fault.action = { if $0 == .beforeExposureMigrationCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { try await h.reopen(); XCTFail("Expected migration refusal") } catch {}
        XCTAssertEqual(try h.base.schemaVersion(), 33)
        fault.action = nil; try await h.reopen()
        let after = try await h.queue.snapshot(); XCTAssertEqual(before, after)
        await h.queue.close()
        for sql in ["UPDATE flag_exposure_state SET stream_id='foreign'",
                    "UPDATE flag_exposure_state SET metadata=CAST('{\"anonymousId\":\"foreign\",\"digests\":[]}' AS BLOB)",
                    "DELETE FROM flag_exposure_state"] {
            let invalid = try await make(); defer { invalid.base.remove() }
            await invalid.queue.close(); try invalid.base.sql(sql)
            do { try await invalid.reopen(); XCTFail("Invalid durable ledger accepted") } catch {}
        }
    }
}

private final class ExposureCurrent: @unchecked Sendable {
    private let lock = NSLock(); private var current = true
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return current }
    func withdraw() { lock.lock(); current = false; lock.unlock() }
}
