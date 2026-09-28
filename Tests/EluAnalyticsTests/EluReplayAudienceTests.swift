import Foundation
import XCTest
@testable import EluAnalytics

private final class NetworkAudiencePermission: @unchecked Sendable {
    private let lock = NSLock(); private var allowed = true
    var current: Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    func withdraw() { lock.lock(); allowed = false; lock.unlock() }
}

final class EluReplayAudienceTests: XCTestCase {
    func testNetworkFinalAdmissionWithdrawalRollsBackEventSessionAndHistory() async throws {
        let fault = DeliveryFault(); let h = try await make(fault: fault); defer { h.base.remove() }
        let before = try await h.queue.snapshot(), permission = NetworkAudiencePermission()
        let versions = try EluVersionContext(runtime: EluVersionComponent(name: "elu-ios", version: "0.2.0"),
            facade: EluVersionComponent(name: "elu-ios", version: "0.2.0"))
        let command = EluV1CaptureCommand(kind: .capture, name: "$network_request", occurredAt: h.base.now, properties: [:], versions: versions)
        let context = EluNetworkObservationContext(identityRevision: before.identity.revision,
            contextRevision: before.identity.contextRevision, sessionID: nil)
        fault.action = { if $0 == .beforeCommit { permission.withdraw() } }
        guard case .rejected(.authorityAbsent, _) = await h.queue.captureNetworkObservation(command, context: context, admissionGuard: { permission.current }) else {
            return XCTFail("Withdrawn completion passed final commit")
        }
        fault.action = nil
        XCTAssertEqual(try history(h), .unseen)
        let after = try await h.queue.snapshot(); XCTAssertEqual(before, after)
        await h.queue.close(); try await h.reopen(); XCTAssertEqual(try history(h), .unseen)
        await h.queue.close()
    }
    func testNetworkTransactionRollbackDoesNotConsumeCaptureHistory() async throws {
        let fault = DeliveryFault(); let h = try await make(fault: fault); defer { h.base.remove() }
        let before = try await h.queue.snapshot()
        let versions = try EluVersionContext(runtime: EluVersionComponent(name: "elu-ios", version: "0.2.0"),
            facade: EluVersionComponent(name: "elu-ios", version: "0.2.0"))
        let command = EluV1CaptureCommand(kind: .capture, name: "$network_request", occurredAt: h.base.now, properties: [:], versions: versions)
        let context = EluNetworkObservationContext(identityRevision: before.identity.revision,
            contextRevision: before.identity.contextRevision, sessionID: nil)
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        guard case .rejected(.storageProvenNotCommitted, _) = await h.queue.captureNetworkObservation(command, context: context, admissionGuard: { true }) else {
            return XCTFail("Expected transactional failure")
        }
        fault.action = nil
        XCTAssertEqual(try history(h), .unseen)
        let after = try await h.queue.snapshot(); XCTAssertEqual(before, after)
        await h.queue.close(); try await h.reopen(); XCTAssertEqual(try history(h), .unseen)
        await h.queue.close()
    }
    func testFirstNetworkObservationClaimsTheSameAtomicCaptureHistory() async throws {
        let h = try await make(); defer { h.base.remove() }
        let before = try await h.queue.snapshot()
        let versions = try EluVersionContext(runtime: EluVersionComponent(name: "elu-ios", version: "0.2.0"),
            facade: EluVersionComponent(name: "elu-ios", version: "0.2.0"))
        let command = EluV1CaptureCommand(kind: .capture, name: "$network_request", occurredAt: h.base.now, properties: [:], versions: versions)
        let context = EluNetworkObservationContext(identityRevision: before.identity.revision,
            contextRevision: before.identity.contextRevision, sessionID: nil)
        guard case .rejected = await h.queue.captureNetworkObservation(command, context: context, admissionGuard: { false }) else {
            return XCTFail("Denied completion admitted")
        }
        XCTAssertEqual(try history(h), .unseen)
        guard case let .accepted(_, snapshot) = await h.queue.captureNetworkObservation(command, context: context, admissionGuard: { true }) else {
            return XCTFail("Expected first network event")
        }
        XCTAssertTrue(try history(h).permits(XCTUnwrap(snapshot.identity.session)))
        try await enableReplay(h); _ = try await h.observe()
        await h.queue.close()
    }
    func testReplayCannotClaimHistoryBeforeAnAcceptedCapture() async throws {
        let h = try await make(); defer { h.base.remove() }
        try await enableReplay(h)
        do { _ = try await h.observe(); XCTFail("Replay claimed a session before capture") } catch {}
        XCTAssertEqual(try history(h), .unseen)
        let accounting = try await h.queue.nativeReplaySessionState(); XCTAssertNil(accounting.session)
        await h.queue.close()
    }

    func testScreenExceptionAndLifecycleEventsConsumeTheSameFirstSessionEntitlement() async throws {
        for (kind, name) in [(EluEventKind.screen, "$screen"), (.exception, "$exception"), (.capture, "$app_opened")] {
            let h = try await make(); defer { h.base.remove() }
            let versions = try EluVersionContext(runtime: EluVersionComponent(name: "elu-ios", version: "0.2.0"),
                facade: EluVersionComponent(name: "elu-ios", version: "0.2.0"))
            let command = EluV1CaptureCommand(kind: kind, name: name, occurredAt: h.base.now, properties: [:], versions: versions)
            guard case let .accepted(_, snapshot) = await h.queue.capture(command) else { return XCTFail("Event rejected") }
            XCTAssertTrue(try history(h).permits(XCTUnwrap(snapshot.identity.session)))
            await h.queue.close()
        }
    }

    func testFirstCommittedCaptureClaimsHistoryBeforeReplayExists() async throws {
        let h = try await make(); defer { h.base.remove() }
        XCTAssertEqual(try history(h), .unseen)
        try await identify(h, "user-a")
        XCTAssertEqual(try history(h), .unseen, "Identity mutations do not consume a capture session")
        try await h.publish()
        let first = try await capture(h)
        XCTAssertTrue(try history(h).permits(XCTUnwrap(first.identity.session)))
        XCTAssertEqual(try h.base.schemaVersion(), 9, "History does not depend on replay storage")
        try await enableReplay(h)
        let observation = try await h.observe()
        XCTAssertEqual(observation.accounting.sessionId, first.identity.session?.id)
        await h.queue.close()
    }

    func testFirstUnrecordedSessionSurvivesRestartAndIdentify() async throws {
        let h = try await make(); defer { h.base.remove() }
        let first = try await capture(h)
        let original = try history(h)
        await h.queue.close(); try await h.reopen(); try await h.publish()
        try await identify(h, "user-a"); try await h.publish()
        _ = try await capture(h)
        XCTAssertEqual(try history(h), original)
        try await enableReplay(h)
        let observation = try await h.observe()
        XCTAssertEqual(observation.accounting.sessionId, first.identity.session?.id)
        await h.queue.close()
    }

    func testUnrecordedFirstSessionCannotRenewThroughConsentOrReset() async throws {
        for reset in [false, true] {
            let h = try await make(); defer { h.base.remove() }
            _ = try await capture(h)
            let first = try history(h)
            h.base.testClock.advance(1)
            if reset {
                _ = try await h.queue.reset(expectedGeneration: h.queue.snapshot().generation)
            } else {
                _ = try await h.queue.setOptedOut(true, expectedGeneration: h.queue.snapshot().generation)
                guard case .rejected = await h.base.capture() else { return XCTFail("Denied capture admitted") }
                await h.queue.close(); try await h.reopen()
                _ = try await h.queue.setOptedOut(false, expectedGeneration: h.queue.snapshot().generation)
            }
            try await h.publish()
            let later = try await capture(h)
            XCTAssertEqual(try history(h), first)
            XCTAssertFalse(first.permits(try XCTUnwrap(later.identity.session)))
            try await enableReplay(h)
            do { _ = try await h.observe(); XCTFail("Later session became a new device") } catch {}
            _ = try await capture(h) // Audience denial never denies ordinary events.
            await h.queue.close()
        }
    }

    func testAllDevicesCanCaptureLaterSessionButReturningRestrictionDeniesIt() async throws {
        let h = try await make(); defer { h.base.remove() }
        _ = try await capture(h)
        h.base.testClock.advance(1)
        _ = try await h.queue.reset(expectedGeneration: h.queue.snapshot().generation)
        try await configure(h, restricted: false)
        _ = try await capture(h)
        try await enableReplay(h)
        _ = try await h.observe()
        try await configure(h, restricted: true)
        do { _ = try await h.observe(); XCTFail("Restriction was ignored after policy refresh") } catch {}
        _ = try await capture(h)
        await h.queue.close()
    }

    func testTimeoutRotationDoesNotReclassifyAReturningDevice() async throws {
        let h = try await make(); defer { h.base.remove() }
        _ = try await capture(h)
        let first = try history(h)
        h.base.testClock.advance(1_801)
        try await configure(h)
        let later = try await capture(h)
        XCTAssertFalse(first.permits(try XCTUnwrap(later.identity.session)))
        XCTAssertEqual(try history(h), first)
        try await enableReplay(h)
        do { _ = try await h.observe(); XCTFail("Timed-out device became new") } catch {}
        await h.queue.close()
    }

    func testConsentBeforeAnyCaptureLeavesFirstSessionAvailable() async throws {
        let h = try await make(); defer { h.base.remove() }
        _ = try await h.queue.setOptedOut(true, expectedGeneration: h.queue.snapshot().generation)
        guard case .rejected = await h.base.capture() else { return XCTFail("Denied capture admitted") }
        await h.queue.close(); try await h.reopen()
        _ = try await h.queue.setOptedOut(false, expectedGeneration: h.queue.snapshot().generation)
        try await h.publish()
        XCTAssertEqual(try history(h), .unseen)
        _ = try await capture(h)
        try await enableReplay(h); _ = try await h.observe()
        await h.queue.close()
    }

    func testQueueRejectionAndTransactionRollbackDoNotConsumeHistory() async throws {
        for point in [EluRuntimeQueueFaultPoint.afterRecordInsert(0), .beforeStateUpdate, .beforeCommit] {
            let fault = DeliveryFault(); let h = try await make(fault: fault); defer { h.base.remove() }
            fault.action = { if $0 == point { throw EluRuntimeQueueError.faultInjected($0) } }
            guard case .rejected(.storageProvenNotCommitted, _) = await h.base.capture() else {
                return XCTFail("Injected rollback was not surfaced")
            }
            fault.action = nil
            XCTAssertEqual(try history(h), .unseen)
            let snapshot = try await h.queue.snapshot(); XCTAssertNil(snapshot.identity.session)
            XCTAssertEqual(snapshot.nextSequence, 0)
            _ = try await capture(h)
            try await enableReplay(h); _ = try await h.observe()
            await h.queue.close()
        }
        let base = try await DeliveryHarness.make(limits: EluRuntimeQueueLimits(maximumBytes: 1))
        let h = NativeSessionHarness(base); defer { base.remove() }
        try await configure(h)
        guard case .rejected(.queueLimit, _) = await base.capture() else { return XCTFail("Expected queue limit") }
        XCTAssertEqual(try history(h), .unseen)
        await h.queue.close()
    }

    func testAmbiguousCommittedCaptureKeepsTheOriginalFirstSessionOnReopen() async throws {
        let fault = DeliveryFault(); let h = try await make(fault: fault); defer { h.base.remove() }
        fault.action = { if $0 == .afterCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        guard case .rejected(.storageOutcomeUnknown, _) = await h.base.capture() else {
            return XCTFail("Expected ambiguous committed outcome")
        }
        fault.action = nil
        let original = try history(h); XCTAssertEqual(original.status, .recorded)
        await h.queue.close(); try await h.reopen(); try await h.publish()
        _ = try await capture(h)
        XCTAssertEqual(try history(h), original)
        try await enableReplay(h); _ = try await h.observe()
        await h.queue.close()
    }

    func testConcurrentCaptureCannotClaimTwoFirstSessions() async throws {
        let h = try await make(); defer { h.base.remove() }
        async let a = h.base.capture(); async let b = h.base.capture()
        guard case let .accepted(_, first) = await a, case let .accepted(_, second) = await b else {
            return XCTFail("Expected serialized captures")
        }
        XCTAssertEqual(first.identity.session?.id, second.identity.session?.id)
        XCTAssertTrue(try history(h).permits(XCTUnwrap(first.identity.session)))
        let snapshot = try await h.queue.snapshot(); XCTAssertEqual(snapshot.nextSequence, 2)
        await h.queue.close()
    }

    func testUnknownOwnedHistoryPreservesEventsAndAllDevicesPolicy() async throws {
        let h = try await make(); defer { h.base.remove() }
        _ = try await capture(h)
        let before = try await h.queue.snapshot()
        await h.queue.close()
        try h.base.sql("DROP TABLE capture_session_history; PRAGMA user_version=1")
        try await h.reopen(); try await h.publish()
        let reopened = try await h.queue.snapshot(); XCTAssertEqual(reopened, before)
        XCTAssertEqual(try history(h), .unknown)
        _ = try await capture(h)
        try await enableReplay(h)
        do { _ = try await h.observe(); XCTFail("Missing old history was treated as new") } catch {}
        try await configure(h, restricted: false)
        _ = try await h.observe()
        await h.queue.close()
    }

    func testHistoryMigrationRollsBackWithoutChangingOriginalStore() async throws {
        let fault = DeliveryFault(); let h = try await make(fault: fault); defer { h.base.remove() }
        _ = try await capture(h)
        let before = try await h.queue.snapshot()
        await h.queue.close()
        try h.base.sql("DROP TABLE capture_session_history; PRAGMA user_version=1")
        fault.action = { if $0 == .beforeCaptureHistoryMigrationCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { try await h.reopen(); XCTFail("Expected migration rollback") } catch {}
        XCTAssertEqual(try h.base.schemaVersion(), 1)
        XCTAssertEqual(try h.integer("SELECT count(*) FROM sqlite_master WHERE name='capture_session_history'"), 0)
        fault.action = nil
        try await h.reopen()
        let after = try await h.queue.snapshot(); XCTAssertEqual(after, before)
        XCTAssertEqual(try history(h), .unknown)
        await h.queue.close()
    }

    func testEverySupportedOldSchemaRetainsRecordsAndMigratesToUnknownHistory() async throws {
        for version in 1...8 {
            let h = try await make(); defer { h.base.remove() }
            _ = try await capture(h)
            if version.isMultiple(of: 2) { try await h.queue.ensureFlagSchema() }
            if version >= 3 { try await h.queue.ensureReplaySchema() }
            if version >= 5 { try await h.queue.ensureReplayDeliverySchema() }
            if version >= 7 { try await h.queue.ensureNativeReplayAuthoritySchema() }
            XCTAssertEqual(try h.base.schemaVersion(), Int64(version + 8))
            let before = try await h.queue.snapshot()
            let records = try await h.queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            await h.queue.close()
            try h.base.sql("DROP TABLE capture_session_history; PRAGMA user_version=\(version)")
            try await h.reopen()
            XCTAssertEqual(try h.base.schemaVersion(), Int64(version + 8))
            XCTAssertEqual(try history(h), .unknown)
            let after = try await h.queue.snapshot(); XCTAssertEqual(after, before)
            let reopenedRecords = try await h.queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(reopenedRecords, records)
            await h.queue.close()
        }
    }

    func testHistoryCodecRejectsAmbiguousOrMalformedClaims() throws {
        for body in ["{}", "{\"sessionId\":null,\"sessionStartedAt\":null,\"status\":\"recorded\"}",
                     "{\"sessionId\":\"s\",\"sessionStartedAt\":null,\"status\":\"unseen\"}",
                     "{\"extra\":true,\"sessionId\":null,\"sessionStartedAt\":null,\"status\":\"unseen\"}"] {
            XCTAssertThrowsError(try EluCaptureSessionHistory.decode(Data(body.utf8)))
        }
        XCTAssertEqual(try EluCaptureSessionHistory.decode(EluCaptureSessionHistory.unseen.encoded()), .unseen)
    }

    private func make(fault: DeliveryFault? = nil) async throws -> NativeSessionHarness {
        let h = NativeSessionHarness(try await DeliveryHarness.make(fault: fault))
        // The delivery fixture pins its first anonymous/session generators.
        // Reopen with the ordinary generators so reset can rotate identity.
        await h.queue.close(); try await h.reopen()
        try await configure(h)
        return h
    }

    private func configure(_ h: NativeSessionHarness, restricted: Bool = true) async throws {
        h.base.testClock.advance(0.001)
        var value = try JSONSerialization.jsonObject(with: h.base.config) as! [String: Any]
        value["replayAudience"] = restricted ? "new-devices" : nil
        value["issuedAt"] = EluRFC3339.string(from: h.base.now)
        value["expiresAt"] = EluRFC3339.string(from: h.base.now.addingTimeInterval(600))
        h.base.config = try JSONSerialization.data(withJSONObject: value)
        try await h.publish()
    }

    private func enableReplay(_ h: NativeSessionHarness) async throws {
        try await h.queue.ensureReplaySchema()
        try await h.queue.ensureReplayDeliverySchema()
        try await h.queue.ensureNativeReplayAuthoritySchema()
    }

    private func capture(_ h: NativeSessionHarness) async throws -> EluRuntimeQueueSnapshot {
        guard case let .accepted(_, snapshot) = await h.base.capture() else { throw EluRuntimeQueueError.invalidState }
        return snapshot
    }

    private func identify(_ h: NativeSessionHarness, _ user: String) async throws {
        let versions = try EluVersionContext(runtime: EluVersionComponent(name: "elu-ios", version: "0.2.0"),
            facade: EluVersionComponent(name: "elu-ios", version: "0.2.0"))
        _ = try await h.queue.applyOwnedMutation(.identify(userId: user, set: [:], setOnce: [:]), versions: versions,
            expectedGeneration: h.queue.snapshot().generation)
    }

    private func history(_ h: NativeSessionHarness) throws -> EluCaptureSessionHistory {
        try EluCaptureSessionHistory.decode(h.bytes("SELECT metadata FROM capture_session_history"))
    }
}
