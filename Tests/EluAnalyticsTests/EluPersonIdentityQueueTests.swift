import Foundation
import XCTest
@testable import EluAnalytics

final class EluPersonIdentityQueueTests: XCTestCase {
    private func versions() throws -> EluVersionContext {
        try .init(runtime: .init(name: "elu-ios", version: "0.2.0"), facade: .init(name: "Elu", version: "1"))
    }

    private func capture(_ h: PersonIdentityHarness, properties: [String: EluJSONValue] = [:]) async throws -> EluQueuedEvent {
        let result = await h.queue.capture(.init(kind: .capture, name: "person-probe", occurredAt: h.base.now,
            properties: properties, versions: try versions()))
        guard case let .accepted(.event(event), _) = result else { throw EluRuntimeQueueError.invalidState }
        return event
    }

    private func mutate(_ h: PersonIdentityHarness, _ change: EluRuntimeMutationTransition) async throws {
        _ = try await h.queue.applyOwnedMutation(change, versions: versions(), expectedGeneration: h.queue.snapshot().generation)
        try await h.native.publish()
    }

    func testOwnedMetadataCodecIsClosedCanonicalAndTyped() throws {
        let value = EluPersonIdentityState(deviceId: "device", processingEnabled: true)
        XCTAssertEqual(try EluPersonIdentityState.decode(value.encoded()), value)
        for text in ["{}", "{\"deviceId\":\"\",\"processingEnabled\":true}",
                     "{\"deviceId\":\"device\",\"processingEnabled\":1}",
                     "{\"deviceId\":\"device\",\"processingEnabled\":false,\"extra\":true}",
                     "{\"deviceId\":\"device\",\"processingEnabled\":false,\"processingEnabled\":true}"] {
            XCTAssertThrowsError(try EluPersonIdentityState.decode(Data(text.utf8)))
        }
    }

    func testModesAndAuthoritativePropertiesCannotBeSpoofedByForFlagsOrSuperproperties() async throws {
        for mode in [EluPersonProfilesMode.identifiedOnly, .always, .never] {
            let h = try await PersonIdentityHarness.make(mode: mode); defer { h.base.remove() }
            let original = try await h.queue.snapshot()
            let forged: [String: EluJSONValue] = ["$epp": .bool(true), "$device_id": .string("forged"),
                "$is_identified": .bool(true), "$process_person_profile": .bool(mode != .always)]
            _ = try await h.queue.registerStandaloneSuperProperties(forged)
            _ = try await h.queue.updateStandaloneFlagContext(.person(forged))
            try await h.native.publish()
            XCTAssertFalse(try h.person().processingEnabled)
            let event = try await capture(h, properties: forged)
            XCTAssertEqual(event.properties["$device_id"], .string(original.identity.anonymousId))
            XCTAssertEqual(event.properties["$is_identified"], .bool(false))
            XCTAssertEqual(event.properties["$process_person_profile"], .bool(mode == .always))
            XCTAssertNil(event.properties["$epp"])
            XCTAssertEqual(try h.person().processingEnabled, mode == .always)
            await h.queue.close()
        }
    }

    func testGroupProcessingBecomesStickyOnlyWithAnAcceptedEvent() async throws {
        for acceptEvent in [false, true] {
            let h = try await PersonIdentityHarness.make(); defer { h.base.remove() }
            try await mutate(h, .associateGroup(groupType: "company", groupKey: "group-a"))
            XCTAssertFalse(try h.person().processingEnabled)
            if acceptEvent {
                let event = try await capture(h)
                XCTAssertEqual(event.properties["$process_person_profile"], .bool(true))
            }
            _ = try await h.queue.updateStandaloneFlagContext(.resetGroups)
            try await h.native.publish()
            let event = try await capture(h)
            XCTAssertEqual(event.properties["$process_person_profile"], .bool(acceptEvent))
            await h.queue.close(); try await h.reopen()
            XCTAssertEqual(try h.person().processingEnabled, acceptEvent)
            await h.queue.close()
        }
    }

    func testAlwaysDoesNotPromoteOnOpenButAcceptedProcessingSurvivesModeChangeAndReopen() async throws {
        let h = try await PersonIdentityHarness.make(mode: .always); defer { h.base.remove() }
        XCTAssertFalse(try h.person().processingEnabled)
        await h.queue.close(); try await h.reopen(mode: .identifiedOnly)
        let anonymous = try await capture(h)
        XCTAssertEqual(anonymous.properties["$process_person_profile"], .bool(false))
        await h.queue.close(); try await h.reopen(mode: .always)
        _ = try await capture(h)
        await h.queue.close(); try await h.reopen(mode: .identifiedOnly)
        let promoted = try await capture(h)
        XCTAssertEqual(promoted.properties["$process_person_profile"], .bool(true))
        await h.queue.close(); try await h.reopen(mode: .never)
        let disabled = try await capture(h)
        XCTAssertEqual(disabled.properties["$process_person_profile"], .bool(false))
        XCTAssertTrue(try h.person().processingEnabled, "Local suppression must not erase previously accepted processing history")
        await h.queue.close()
    }

    func testPersonMutationPromotionAndKnownRollbackAreOneTransaction() async throws {
        let fault = DeliveryFault(), h = try await PersonIdentityHarness.make(fault: fault); defer { h.base.remove() }
        let before = try await h.queue.snapshot(), metadata = try h.person()
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { try await mutate(h, .setPersonProperties(set: ["tier": .string("paid")], setOnce: [:], unset: [])); XCTFail("Expected rollback") }
        catch {}
        fault.action = nil
        let after = try await h.queue.snapshot()
        XCTAssertEqual(after, before); XCTAssertEqual(try h.person(), metadata)
        try await mutate(h, .setPersonProperties(set: ["tier": .string("paid")], setOnce: [:], unset: []))
        XCTAssertTrue(try h.person().processingEnabled)
        await h.queue.close(); try await h.reopen()
        let event = try await capture(h)
        XCTAssertEqual(event.properties["$process_person_profile"], .bool(true))
        XCTAssertEqual(event.properties["$is_identified"], .bool(false))
        try await mutate(h, .identify(userId: "user-a", set: [:], setOnce: [:]))
        try await mutate(h, .linkAlias(aliasId: "alias-a"))
        let identified = try await capture(h)
        XCTAssertEqual(identified.properties["$is_identified"], .bool(true))
        XCTAssertEqual(identified.properties["$device_id"], event.properties["$device_id"])
        await h.queue.close()
    }

    func testNeverRejectsPersonMutationsWithoutChangingLocalIdentityOrQueuedHistory() async throws {
        let h = try await PersonIdentityHarness.make(); defer { h.base.remove() }
        try await mutate(h, .identify(userId: "existing-user", set: [:], setOnce: [:]))
        await h.queue.close(); try await h.reopen(mode: .never)
        let before = try await h.queue.snapshot(), metadata = try h.person()
        for operation in [EluRuntimeMutationTransition.identify(userId: "replacement", set: [:], setOnce: [:]),
                          .linkAlias(aliasId: "alias"), .setPersonProperties(set: ["tier": .string("paid")], setOnce: [:], unset: [])] {
            do { try await mutate(h, operation); XCTFail("Never allowed a person mutation") } catch {}
            let after = try await h.queue.snapshot(); XCTAssertEqual(after, before)
            XCTAssertEqual(try h.person(), metadata)
        }
        let event = try await capture(h)
        XCTAssertEqual(event.properties["$is_identified"], .bool(true))
        XCTAssertEqual(event.properties["$process_person_profile"], .bool(false))
        await h.queue.close()
    }

    func testEventQuotaAndRollbackCannotPromoteButAmbiguousCommittedEventDoes() async throws {
        let quota = try await PersonIdentityHarness.make(mode: .always, limits: .init(maximumBytes: 1)); defer { quota.base.remove() }
        guard case .rejected = await quota.base.capture() else { return XCTFail("Quota must reject") }
        XCTAssertFalse(try quota.person().processingEnabled)
        await quota.queue.close()
        for point in [EluRuntimeQueueFaultPoint.beforeCommit, .afterCommit] {
            let fault = DeliveryFault(), h = try await PersonIdentityHarness.make(mode: .always, fault: fault); defer { h.base.remove() }
            fault.action = { if $0 == point { throw EluRuntimeQueueError.faultInjected($0) } }
            guard case .rejected = await h.base.capture() else { return XCTFail("Expected rejected or ambiguous outcome") }
            fault.action = nil; await h.queue.close(); try await h.reopen()
            let committed = point == .afterCommit
            XCTAssertEqual(try h.person().processingEnabled, committed)
            let snapshot = try await h.queue.snapshot(); XCTAssertEqual(snapshot.queuedCount, committed ? 1 : 0)
            await h.queue.close()
        }
    }

    func testResetPreservesDeviceConsentHistoryAndBacklogWhileExplicitResetRotatesDevice() async throws {
        let h = try await PersonIdentityHarness.make(); defer { h.base.remove() }
        try await mutate(h, .identify(userId: "user-a", set: [:], setOnce: [:]))
        _ = try await capture(h)
        _ = try await h.queue.setOptedOut(true, expectedGeneration: h.queue.snapshot().generation)
        let before = try await h.queue.snapshot(), oldDevice = try h.person().deviceId
        let history = try h.native.bytes("SELECT metadata FROM capture_session_history")
        let records = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
        let reset = try await h.queue.reset(expectedGeneration: before.generation)
        XCTAssertNotEqual(reset.identity.anonymousId, before.identity.anonymousId)
        XCTAssertTrue(reset.identity.optedOut); XCTAssertNil(reset.identity.userId); XCTAssertNil(reset.identity.session)
        XCTAssertEqual(try h.person().deviceId, oldDevice); XCTAssertFalse(try h.person().processingEnabled)
        XCTAssertEqual(reset.streamId, before.streamId); XCTAssertEqual(reset.nextSequence, before.nextSequence)
        XCTAssertEqual(try h.native.bytes("SELECT metadata FROM capture_session_history"), history)
        let retained = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000); XCTAssertEqual(retained, records)
        await h.queue.close(); try await h.reopen()
        XCTAssertEqual(try h.person().deviceId, oldDevice)
        let rotated = try await h.queue.reset(expectedGeneration: h.queue.snapshot().generation, resetDeviceId: true)
        XCTAssertEqual(try h.person().deviceId, rotated.identity.anonymousId)
        XCTAssertNotEqual(try h.person().deviceId, oldDevice); XCTAssertTrue(rotated.identity.optedOut)
        await h.queue.close(); try await h.reopen()
        XCTAssertEqual(try h.person().deviceId, rotated.identity.anonymousId)
        await h.queue.close()
    }

    func testResetRollbackAndDeviceGeneratorCollisionPreserveOriginalMetadata() async throws {
        let fault = DeliveryFault(), h = try await PersonIdentityHarness.make(fault: fault); defer { h.base.remove() }
        let metadata = try h.person(), original = try await h.queue.snapshot()
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { _ = try await h.queue.reset(expectedGeneration: original.generation, resetDeviceId: true); XCTFail("Expected rollback") } catch {}
        fault.action = nil
        XCTAssertEqual(try h.person(), metadata)
        _ = try await h.queue.reset(expectedGeneration: original.generation)
        let beforeCollision = try await h.queue.snapshot()
        h.identifiers.force(metadata.deviceId)
        do { _ = try await h.queue.reset(expectedGeneration: beforeCollision.generation, resetDeviceId: true); XCTFail("Old device reused") } catch {}
        let after = try await h.queue.snapshot(); XCTAssertEqual(after, beforeCollision)
        XCTAssertEqual(try h.person().deviceId, metadata.deviceId)
        await h.queue.close()
    }

    func testEverySupportedPriorSchemaUpgradesWithoutInferringAnonymousProfileHistory() async throws {
        for version in Array(1...16) + Array(25...32) {
            let base = version > 24 ? version - 24 : version > 8 ? version - 8 : version
            let h = try await PersonIdentityHarness.make(); defer { h.base.remove() }
            _ = try await h.queue.updateStandaloneFlagContext(.person(["tier": .string("not-proof")]))
            _ = try await h.queue.registerStandaloneSuperProperties(["$epp": .bool(true)])
            try await h.native.publish(); _ = try await capture(h)
            if base.isMultiple(of: 2) { try await h.queue.ensureFlagSchema() }
            if base >= 3 { try await h.queue.ensureReplaySchema() }
            if base >= 5 { try await h.queue.ensureReplayDeliverySchema() }
            if base >= 7 { try await h.queue.ensureNativeReplayAuthoritySchema() }
            let before = try await h.queue.snapshot(), records = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
            await h.queue.close()
            try h.base.sql("DROP TABLE person_identity_state; \(version < 25 ? "DROP TABLE native_diagnostics_state;" : "") \(version <= 8 ? "DROP TABLE capture_session_history;" : "") PRAGMA user_version=\(version)")
            try await h.reopen()
            XCTAssertEqual(try h.base.schemaVersion(), Int64(base + 32))
            let after = try await h.queue.snapshot(), restored = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
            XCTAssertEqual(after, before); XCTAssertEqual(restored, records)
            XCTAssertEqual(try h.person(), .init(deviceId: before.identity.anonymousId))
            await h.queue.close(); try await h.reopen()
            XCTAssertEqual(try h.base.schemaVersion(), Int64(base + 32))
            await h.queue.close()
        }
    }

    func testPersonMigrationRollbackLeavesOldSchemaAndRecordsRecoverable() async throws {
        let fault = DeliveryFault(), h = try await PersonIdentityHarness.make(fault: fault); defer { h.base.remove() }
        _ = try await capture(h); let before = try await h.queue.snapshot()
        await h.queue.close(); try h.base.sql("DROP TABLE person_identity_state; PRAGMA user_version=25")
        fault.action = { if $0 == .beforePersonIdentityMigrationCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { try await h.reopen(); XCTFail("Migration fault ignored") } catch {}
        XCTAssertEqual(try h.base.schemaVersion(), 25)
        XCTAssertEqual(try h.native.integer("SELECT count(*) FROM sqlite_master WHERE name='person_identity_state'"), 0)
        fault.action = nil; try await h.reopen()
        let restored = try await h.queue.snapshot(); XCTAssertEqual(restored, before)
        XCTAssertEqual(try h.base.schemaVersion(), 33)
        await h.queue.close()
    }

    func testWrongStreamAndMalformedSingletonFailClosed() async throws {
        for sql in ["UPDATE person_identity_state SET stream_id='foreign-stream'",
                    "UPDATE person_identity_state SET metadata=CAST('{\"deviceId\":\"device\",\"processingEnabled\":1}' AS BLOB)",
                    "DELETE FROM person_identity_state"] {
            let h = try await PersonIdentityHarness.make(); defer { h.base.remove() }
            await h.queue.close(); try h.base.sql(sql)
            do { try await h.reopen(); XCTFail("Invalid device/profile metadata accepted") } catch {}
        }
    }
}

private final class PersonIdentityIdentifiers: @unchecked Sendable {
    private let lock = NSLock(); private var next = 0; private var forced: String?
    func force(_ value: String) { lock.lock(); forced = value; lock.unlock() }
    func read() -> String {
        lock.lock(); defer { lock.unlock() }
        if let forced { return forced }
        next += 1; return "person-anonymous-\(next)"
    }
}

private final class PersonIdentityHarness: @unchecked Sendable {
    let native: NativeSessionHarness
    let identifiers = PersonIdentityIdentifiers()
    var base: DeliveryHarness { native.base }
    var queue: EluSQLiteRuntimeQueue { base.queue }
    init(_ base: DeliveryHarness) { native = NativeSessionHarness(base) }
    static func make(mode: EluPersonProfilesMode = .identifiedOnly, limits: EluRuntimeQueueLimits? = nil,
                     fault: DeliveryFault? = nil) async throws -> PersonIdentityHarness {
        let h = PersonIdentityHarness(try await DeliveryHarness.make(limits: limits, fault: fault))
        await h.queue.close(); try await h.reopen(mode: mode); return h
    }
    func reopen(mode: EluPersonProfilesMode = .identifiedOnly) async throws {
        let clock = base.testClock, ids = identifiers
        base.queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: base.root,
            exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", personProfiles: mode, limits: base.limits,
            clock: { clock.read() }, continuousClock: { clock.ticks() }, continuousBudgetConverter: { $0 },
            anonymousIdGenerator: { ids.read() }, sessionIdGenerator: { "person-session-\(UUID().uuidString)" },
            configurationGate: base.gate, faultInjector: base.fault)
        if !(try await queue.snapshot()).identity.optedOut { try await native.publish() }
    }
    func person() throws -> EluPersonIdentityState {
        try .decode(native.bytes("SELECT metadata FROM person_identity_state"))
    }
}
