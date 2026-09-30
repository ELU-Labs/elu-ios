import Foundation
import SQLite3
import XCTest
@testable import EluAnalytics

final class EluNativeRasterSourceDenialTests: XCTestCase {
    func testActualSourceConflictMigratesDeniedStorageAndSurvivesFreshV2Owner() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        XCTAssertLessThan(try h.integer("PRAGMA user_version"), 128)
        let denial = try await h.conflict()
        XCTAssertNil(h.gate.witness(for: h.token))
        let changed = try await h.queue.persistConfigurationDenial(); XCTAssertTrue(changed)
        XCTAssertNil(h.gate.pendingDenial())
        XCTAssertFalse(h.gate.isCurrent(h.witness), "SQL settlement cannot resurrect the old source token")
        let ledger = try h.ledger(); XCTAssertTrue(ledger.conflicted)
        XCTAssertEqual(ledger.issuedAt, denial.issuedAt); XCTAssertEqual(ledger.semanticHash, denial.semanticHash)
        XCTAssertEqual(try h.integer("SELECT admission_enabled FROM replay_state"), 0)
        XCTAssertEqual(try h.integer("SELECT count(*) FROM replay_chunks"), 0)
        await h.close()
        let reopened = try await Rig.make(root: h.root, base: h.base, format: .v2)
        let result = await reopened.queue.submitCaptureAuthority(configData: reopened.base,
            effectivePrivacyStateData: Data("{}".utf8), sourceWitness: reopened.witness)
        guard case let .terminated(terminal) = result else { await reopened.close(); return XCTFail("restart bypassed denial") }
        XCTAssertEqual(terminal.reason, .conflict)
        XCTAssertEqual(try reopened.ledger(), ledger)
        await reopened.close()
    }

    func testDenialPreservesOriginalQueuedWireframeBytes() async throws {
        let original = try await SealedPolicyTestHarness.make(tuple: .v2)
        defer { original.base.remove() }
        let rows = try await original.base.queue.storedReplayRecords()
        XCTAssertEqual(rows.count, 1)
        await original.base.queue.close()
        let h = try await Rig.make(root: original.base.root, base: original.base.config)
        _ = try await h.conflict(); _ = try await h.queue.persistConfigurationDenial()
        let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, rows)
        await h.close()
        let reopened = try await Rig.make(root: h.root, base: h.base, format: .v2)
        let restored = try await reopened.queue.storedReplayRecords(); XCTAssertEqual(restored, rows)
        await reopened.close()
    }

    func testKnownRollbackKeepsOriginalReceiptForSameOwnerRetry() async throws {
        let fault = DeliveryFault(), h = try await Rig.make(fault: fault); defer { h.remove() }
        try await h.prepareStorage()
        let denial = try await h.conflict()
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { _ = try await h.queue.persistConfigurationDenial(); XCTFail("injected write succeeded") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .provenNotCommitted) }
        XCTAssertTrue(h.gate.pendingDenial() === denial)
        XCTAssertEqual(try h.integer("SELECT raster_source IS NULL FROM replay_state"), 1)
        fault.action = nil
        let settled = try await h.queue.persistConfigurationDenial(); XCTAssertTrue(settled)
        XCTAssertNil(h.gate.pendingDenial()); XCTAssertTrue(try h.ledger().conflicted)
        await h.close()
    }

    func testUnknownCommitKeepsReceiptAndOriginalInstallationQuarantined() async throws {
        let fault = DeliveryFault(), h = try await Rig.make(fault: fault); defer { h.remove() }
        try await h.prepareStorage()
        let denial = try await h.conflict()
        fault.action = { if $0 == .afterCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { _ = try await h.queue.persistConfigurationDenial(); XCTFail("unknown commit returned success") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ambiguousCommit) }
        XCTAssertTrue(h.gate.pendingDenial() === denial)
        fault.action = nil; await h.close()
        do {
            let replacement = try await h.openQueue()
            await replacement.close(); XCTFail("unknown denial released original installation")
        } catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
    }

    func testCloseDrainsAfterOriginalSourceCloseWithoutGrantingAReplacement() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.conflict()
        h.gate.close(); await h.source.close()
        XCTAssertNotNil(h.gate.pendingDenial())
        await h.queue.close()
        XCTAssertNil(h.gate.pendingDenial()); XCTAssertTrue(try h.ledger().conflicted)
        let reopened = try await h.openQueue(); await reopened.close()
    }

    func testFailedCloseRetainsUnsettledReceiptAndInstallation() async throws {
        let fault = DeliveryFault(), h = try await Rig.make(fault: fault); defer { h.remove() }
        try await h.prepareStorage(); let denial = try await h.conflict()
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        await h.close(); fault.action = nil
        XCTAssertTrue(h.gate.pendingDenial() === denial)
        do {
            let replacement = try await h.openQueue()
            await replacement.close(); XCTFail("failed restrictive close released original installation")
        } catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
    }

    func testNewerDurableWrapperDominatesAnOlderActualSourceDenial() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        try await h.prepareStorage(); await h.queue.close()
        let newerBase = try h.newerBase()
        let newer = try await Rig.make(root: h.root, base: newerBase)
        try await newer.queue.reconcileNativeRasterSource(XCTUnwrap(newer.witness))
        let ledger = try newer.ledger(); XCTAssertFalse(ledger.conflicted)
        await newer.close()
        h.queue = try await h.openQueue()
        _ = try await h.conflict(); _ = try await h.queue.persistConfigurationDenial()
        XCTAssertEqual(try h.ledger(), ledger); XCTAssertNil(h.gate.pendingDenial())
        await h.close()
    }

    func testForeignGateCannotConsumeOrClearOriginalReceipt() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        let denial = try await h.conflict()
        let foreign = EluV2ConfigAuthorityGate(siteKey: Rig.key, clock: h.clock)
        XCTAssertFalse(foreign.retainsDenial(denial)); foreign.acknowledgeDenial(denial)
        let foreignSite = EluV2ConfigAuthorityGate(siteKey: "elu_pk_test_bbbbbbbbbbbbbbbbbbbbbb",
            clock: h.clock, sourceDenials: h.source.denials)
        XCTAssertNil(foreignSite.pendingDenial()); XCTAssertFalse(foreignSite.retainsDenial(denial))
        XCTAssertTrue(h.gate.pendingDenial() === denial)
        _ = try await h.queue.persistConfigurationDenial(); await h.close()
    }

    func testDefaultV2AndMalformedNativeResponseNeverCreateDenialStorage() async throws {
        for format in [EluV2ConfigRequest.Format.v2, .nativeV3] {
            let h = try await Rig.make(format: format); defer { h.remove() }
            let before = try h.integer("PRAGMA user_version")
            await h.transport.replace(Data("{}".utf8))
            let result = await h.source.refresh(); XCTAssertEqual(result, .unavailable)
            XCTAssertNil(h.gate.pendingDenial())
            let changed = try await h.queue.persistConfigurationDenial(); XCTAssertFalse(changed)
            XCTAssertEqual(try h.integer("PRAGMA user_version"), before)
            await h.close()
        }
    }

    private final class Rig: @unchecked Sendable {
        static let key = "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa"
        let root: URL, base: Data, clock: EluV2ConfigClock, source: EluV2ConfigSource
        let gate: EluV2ConfigAuthorityGate, transport: SourceTransport
        let now: Date, fault: DeliveryFault?
        var queue: EluSQLiteRuntimeQueue!
        var witness: EluV2ConfigAuthorityWitness?
        let token = EluV2ConfigLifecycleToken()

        private init(root: URL, base: Data, format: EluV2ConfigRequest.Format, fault: DeliveryFault?) throws {
            self.root = root; self.fault = fault
            let positive = try nativeV3SourceRasterFixture(base: base)
            let parsed = try EluNativeV3ConfigParser.parse(positive)
            self.base = parsed.configV2Data
            let now = Date(timeIntervalSince1970: Double(parsed.base.issuedAt.floorUnixMilliseconds) / 1_000 + 1)
            self.now = now
            clock = EluV2ConfigClock(wallNow: { now }, continuousNow: { 1 }, floorTicks: { $0 }, floorNanoseconds: { $0 })
            transport = SourceTransport(format == .v2 ? self.base : positive)
            source = try EluV2ConfigSource(siteKey: Self.key, format: format, transport: transport, clock: clock)
            gate = EluV2ConfigAuthorityGate(siteKey: Self.key, clock: clock, sourceDenials: source.denials)
        }
        static func make(root: URL? = nil, base: Data? = nil,
                         format: EluV2ConfigRequest.Format = .nativeV3, fault: DeliveryFault? = nil) async throws -> Rig {
            let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let bytes = try base ?? Data(contentsOf: sourceRoot.appendingPathComponent("Conformance/V2/fixtures/config-enabled.json"))
            let h = try Rig(root: root ?? FileManager.default.temporaryDirectory.appendingPathComponent("elu-source-denial-" + UUID().uuidString),
                            base: bytes, format: format, fault: fault)
            h.queue = try await h.openQueue()
            let result = await h.source.refresh()
            guard case .document = result, let lease = await h.source.currentLease() else {
                await h.close(); throw EluRuntimeQueueError.sourceAuthorityUnavailable
            }
            h.gate.publish(token: h.token, lease: lease)
            h.witness = try XCTUnwrap(h.gate.witness(for: h.token))
            return h
        }
        func openQueue() async throws -> EluSQLiteRuntimeQueue {
            let now = now
            return try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root,
                exactConstructorSiteKey: Self.key, clock: { now }, continuousClock: { 1 },
                continuousBudgetConverter: { $0 }, nativeContinuousNanoseconds: { $0 },
                configurationGate: gate, faultInjector: fault)
        }
        func prepareStorage() async throws {
            try await queue.ensureReplaySchema(); try await queue.ensureReplayDeliverySchema()
            try await queue.ensureNativeReplayAuthoritySchema()
            try await queue.ensureNativeRasterSchema(source: XCTUnwrap(witness))
        }
        func conflict() async throws -> EluV2ConfigSourceDenial {
            await transport.replace(nativeV3SourceEnvelope(base))
            let result = await source.refresh(); XCTAssertEqual(result, .unavailable)
            return try XCTUnwrap(gate.pendingDenial())
        }
        func newerBase() throws -> Data {
            var value = try JSONSerialization.jsonObject(with: base) as! [String: Any]
            value["issuedAt"] = EluRFC3339.string(from: now)
            return try JSONSerialization.data(withJSONObject: value)
        }
        func close() async { gate.close(); await source.close(); await queue.close() }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func ledger() throws -> EluNativeRasterSourceLedger { try EluNativeRasterSourceLedger(read("SELECT raster_source FROM replay_state")) }
        func integer(_ sql: String) throws -> Int64 {
            try withStatement(sql) { sqlite3_column_int64($0, 0) }
        }
        private func read(_ sql: String) throws -> Data {
            try withStatement(sql) { statement in
                Data(bytes: try XCTUnwrap(sqlite3_column_blob(statement, 0)), count: Int(sqlite3_column_bytes(statement, 0)))
            }
        }
        private func withStatement<T>(_ sql: String, read: (OpaquePointer) throws -> T) throws -> T {
            let path = try root.appendingPathComponent(EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: Self.key))
                .appendingPathComponent("runtime-state-v1.sqlite3").path
            var database: OpaquePointer?, statement: OpaquePointer?
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw EluRuntimeQueueError.databaseUnavailable }
            defer { sqlite3_close(database) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw EluRuntimeQueueError.databaseUnavailable }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw EluRuntimeQueueError.corruptStorage }
            return try read(XCTUnwrap(statement))
        }
    }

    private actor SourceTransport: EluV2ConfigTransport {
        private var bytes: Data
        init(_ bytes: Data) { self.bytes = bytes }
        func replace(_ bytes: Data) { self.bytes = bytes }
        func fetch(_ request: EluV2ConfigRequest) async throws -> Data { bytes }
    }
}
