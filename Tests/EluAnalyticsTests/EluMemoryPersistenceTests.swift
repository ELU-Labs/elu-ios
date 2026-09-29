import Darwin
import Foundation
import XCTest
@testable import EluAnalytics

final class EluMemoryPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_888_090)
    private let siteKey = "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa"

    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("elu-memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false)
        return value
    }
    private func open(_ directory: URL, mode: EluPersistenceMode = .memory,
                      fault: (any EluRuntimeQueueFaultInjecting)? = nil) async throws -> EluSQLiteRuntimeQueue {
        let now = now
        return try await EluSQLiteRuntimeQueue.open(directoryURL: directory, persistence: mode,
            clock: { now }, faultInjector: fault)
    }
    private func versions() throws -> EluVersionContext {
        try .init(runtime: .init(name: "elu-ios", version: "0.2.0"), facade: .init(name: "Elu", version: "1"))
    }
    private func files(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { result[path] = try Data(contentsOf: url) }
        }
        return result
    }

    private func analyticsFiles(_ directory: URL) throws -> [String: Data] {
        try files(directory).filter {
            ![EluExplicitConsentStore.filename, ".explicit-consent-v1.tmp"].contains(URL(fileURLWithPath: $0.key).lastPathComponent)
        }
    }

    func testPersistentDefaultAndExistingInitializerFormsRemain() {
        XCTAssertEqual(EluSetupOptions().persistence, .persistent)
        XCTAssertEqual(EluSetupOptions(configHost: URL(string: "https://elu.dev")!, apiHost: nil).persistence, .persistent)
        var options = EluSetupOptions(performance: .init())
        options.persistence = .memory
        XCTAssertEqual(options.persistence, .memory)
    }

    func testPublicOptionsReachOriginalContextAndProductionStack() async throws {
        let box = MemoryContextBox()
        let core = EluCore(backendFactory: .init(make: { _, context in box.save(context); return nil }))
        var options = EluSetupOptions(); options.persistence = .memory
        core.setConsent(optedOut: true)
        core.setup(siteKey: siteKey, options: options)
        XCTAssertTrue(core.isOptedOut()) // Joins the setup queue without networking.
        XCTAssertEqual(box.read()?.persistence, .memory)
        XCTAssertEqual(box.read()?.initialConsent?.optedOut, true)

        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let stack = try await EluStandaloneStack.make(rootDirectoryURL: root, siteKey: siteKey,
            configHost: URL(string: "https://elu.dev")!, persistence: .memory)
        let original = await stack.runtime.currentSnapshot
        let intent = UUID(); stack.runtime.acceptConsentIntent(intent, optedOut: true)
        let denied = await stack.runtime.setOptedOut(true, intent: intent)
        XCTAssertEqual(denied?.identity.optedOut, true)
        XCTAssertEqual(denied?.identity.anonymousId, original.identity.anonymousId)
        stack.close(); await stack.settled()
        XCTAssertTrue(try files(root).keys.allSatisfy { $0.hasSuffix("/.runtime-state-v1.lock") || $0.hasSuffix("/" + EluExplicitConsentStore.filename) })
    }

    func testMemoryUsesAtomicQueueTransactionsAndDropsAnalyticsOnReopen() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fault = DeliveryFault(), queue = try await open(root, fault: fault)
        let initial = try await queue.snapshot()
        let mutation = EluRuntimeMutationTransition.setPersonProperties(set: ["private": .string("not-on-disk")], setOnce: [:], unset: [])
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { _ = try await queue.applyMutation(mutation, versions: versions(), expectedGeneration: initial.generation); XCTFail("Expected SQL rollback") }
        catch {}
        let rolledBack = try await queue.snapshot(); XCTAssertEqual(rolledBack, initial)
        fault.action = nil
        _ = try await queue.applyMutation(mutation, versions: versions(), expectedGeneration: initial.generation)
        _ = try await queue.registerStandaloneSuperProperties(["private": .string("not-on-disk")])
        _ = try await queue.updateStandaloneFlagContext(.person(["tier": .string("private")]))
        let populated = try await queue.snapshot(); XCTAssertEqual(populated.queuedCount, 1)
        XCTAssertEqual(try files(root).keys.sorted(), [".runtime-state-v1.lock"])
        await queue.close()
        let reopened = try await open(root)
        let fresh = try await reopened.snapshot()
        XCTAssertEqual(fresh.queuedCount, 0); XCTAssertEqual(fresh.nextSequence, 0)
        XCTAssertNotEqual(fresh.streamId, populated.streamId)
        XCTAssertNotEqual(fresh.identity.anonymousId, populated.identity.anonymousId)
        XCTAssertNil(fresh.identity.session); XCTAssertTrue(fresh.identity.superProperties.isEmpty)
        XCTAssertTrue(fresh.flagContext.personProperties.isEmpty)
        XCTAssertEqual(try files(root).keys.sorted(), [".runtime-state-v1.lock"])
        await reopened.close()
    }

    func testMemoryDoesNotOpenOrAlterExistingAnalyticsAndCannotInferGrant() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let durable = try await open(root, mode: .persistent)
        let initial = try await durable.snapshot()
        _ = try await durable.applyMutation(.setPersonProperties(set: ["private": .string("old")], setOnce: [:], unset: []),
            versions: versions(), expectedGeneration: initial.generation)
        let old = try await durable.snapshot(); XCTAssertFalse(old.identity.optedOut)
        await durable.close()
        let before = try analyticsFiles(root)
        let memory = try await open(root)
        let denied = try await memory.snapshot()
        XCTAssertTrue(denied.identity.optedOut); XCTAssertEqual(denied.queuedCount, 0)
        XCTAssertNotEqual(denied.identity.anonymousId, old.identity.anonymousId)
        XCTAssertEqual(try analyticsFiles(root), before)
        await memory.close(); XCTAssertEqual(try analyticsFiles(root), before)
        XCTAssertTrue(try XCTUnwrap(EluExplicitConsentStore(directoryURL: root).load()).effectiveOptedOut)
        // An unsupported or corrupt old store also stays entirely unopened.
        let oldDatabase = root.appendingPathComponent("runtime-state-v1.sqlite3")
        try Data("unrecognized store".utf8).write(to: oldDatabase)
        let invalidBefore = try files(root), ignored = try await open(root)
        let invalid = try await ignored.snapshot(); XCTAssertTrue(invalid.identity.optedOut)
        await ignored.close(); XCTAssertEqual(try files(root), invalidBefore)
    }

    func testExplicitConsentSurvivesBothModesAndResetWithoutPersistingMemoryIdentity() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var queue = try await open(root)
        let start = try await queue.snapshot(); XCTAssertFalse(start.identity.optedOut)
        _ = try await queue.setOptedOut(true, expectedGeneration: start.generation)
        _ = try await queue.reset(expectedGeneration: queue.snapshot().generation, resetDeviceId: true)
        await queue.close()
        XCTAssertEqual(try files(root).keys.sorted(), [".runtime-state-v1.lock", EluExplicitConsentStore.filename].sorted())
        queue = try await open(root, mode: .persistent)
        var snapshot = try await queue.snapshot(); XCTAssertTrue(snapshot.identity.optedOut)
        _ = try await queue.setOptedOut(false, expectedGeneration: snapshot.generation)
        await queue.close()
        let before = try analyticsFiles(root)
        queue = try await open(root)
        snapshot = try await queue.snapshot(); XCTAssertFalse(snapshot.identity.optedOut)
        XCTAssertNotEqual(snapshot.identity.anonymousId, start.identity.anonymousId)
        await queue.close(); XCTAssertEqual(try analyticsFiles(root), before)
        let choice = try XCTUnwrap(EluExplicitConsentStore(directoryURL: root).load())
        XCTAssertEqual(choice, .init(optedOut: false, settled: true))
        XCTAssertFalse(String(decoding: choice.bytes, as: UTF8.self).contains(snapshot.identity.anonymousId))
    }

    func testSameCanonicalLeaseExcludesOtherModeAndAliasUntilClose() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("owned"), alias = root.appendingPathComponent("alias")
        let memory = try await open(owned)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: owned)
        for candidate in [owned, alias] {
            do { let other = try await open(candidate, mode: .persistent); await other.close(); XCTFail("Concurrent mode acquired original lease") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
        }
        await memory.close()
        let persistent = try await open(owned, mode: .persistent)
        do { let other = try await open(owned); await other.close(); XCTFail("Memory bypassed persistent lease") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
        await persistent.close()
    }

    func testReconciledGrantCannotReviveLaterPersistentDatabaseDenial() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var queue = try await open(root, mode: .persistent)
        _ = try await queue.applyMutation(.setPersonProperties(set: ["retained": .bool(true)], setOnce: [:], unset: []),
            versions: versions(), expectedGeneration: queue.snapshot().generation)
        _ = try await queue.setOptedOut(false, expectedGeneration: queue.snapshot().generation)
        let sidecar = root.appendingPathComponent(EluExplicitConsentStore.filename)
        let previousGrant = try Data(contentsOf: sidecar)
        _ = try await queue.setOptedOut(true, expectedGeneration: queue.snapshot().generation)
        let denied = try await queue.snapshot()
        let backlog = try await queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
        await queue.close()
        // The real denial transaction above supplies the prior owned DB shape.
        // Restore only the stale sidecar, as a version unaware of that file
        // would leave it. This does not claim execution of that old binary.
        try previousGrant.write(to: sidecar)
        queue = try await open(root, mode: .persistent)
        let reopened = try await queue.snapshot()
        XCTAssertTrue(reopened.identity.optedOut)
        XCTAssertEqual(reopened.identity.anonymousId, denied.identity.anonymousId)
        let retained = try await queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
        XCTAssertEqual(retained, backlog)
        XCTAssertEqual(try EluExplicitConsentStore(directoryURL: root).load(),
            .init(optedOut: true, settled: false, persistentReconciled: true))
        await queue.close()
        queue = try await open(root, mode: .persistent)
        let again = try await queue.snapshot(); XCTAssertEqual(again, reopened)
        await queue.close()
    }

    func testUnreconciledExplicitMemoryGrantStillReplacesPersistentDenialThroughBarrier() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var queue = try await open(root, mode: .persistent)
        _ = try await queue.setOptedOut(true, expectedGeneration: queue.snapshot().generation)
        let denied = try await queue.snapshot(); await queue.close()
        let oldAnalytics = try analyticsFiles(root)
        queue = try await open(root, mode: .memory)
        _ = try await queue.setOptedOut(false, expectedGeneration: queue.snapshot().generation)
        await queue.close(); XCTAssertEqual(try analyticsFiles(root), oldAnalytics)
        XCTAssertEqual(try EluExplicitConsentStore(directoryURL: root).load(),
            .init(optedOut: false, settled: true, persistentReconciled: false))
        queue = try await open(root, mode: .persistent)
        let granted = try await queue.snapshot()
        XCTAssertFalse(granted.identity.optedOut)
        XCTAssertEqual(granted.identity.anonymousId, denied.identity.anonymousId)
        XCTAssertEqual(granted.identity.contextRevision, denied.identity.contextRevision + 1)
        XCTAssertEqual(try EluExplicitConsentStore(directoryURL: root).load(),
            .init(optedOut: false, settled: true, persistentReconciled: true))
        await queue.close()
    }

    func testConsentFaultsDenyAndRetainOriginalLeaseRatherThanReleaseAnUnsettledGrant() async throws {
        for point in [EluRuntimeQueueFaultPoint.beforeConsentIntentWrite, .afterConsentIntentWrite,
                      .beforeCommit, .afterCommit, .beforeConsentSettlementWrite, .afterConsentSettlementWrite] {
            // This test deliberately quarantines the original connection/lease until
            // process exit. Retain its namespace; unlinking it is not resource cleanup.
            let root = try directory()
            let fault = DeliveryFault(), queue = try await open(root, fault: fault)
            _ = try await queue.setOptedOut(true, expectedGeneration: queue.snapshot().generation)
            let generation = try await queue.snapshot().generation
            fault.action = { if $0 == point { throw EluRuntimeQueueError.faultInjected($0) } }
            do { _ = try await queue.setOptedOut(false, expectedGeneration: generation); XCTFail("Unsettled grant succeeded") } catch {}
            do { _ = try await queue.snapshot(); XCTFail("Poisoned queue remained usable") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, .poisoned) }
            await queue.close()
            do { let next = try await open(root); await next.close(); XCTFail("Failed owner released its installation") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
            XCTAssertTrue(try XCTUnwrap(EluExplicitConsentStore(directoryURL: root).load()).effectiveOptedOut)
        }
    }

    func testSupersededGrantLeavesDenialAndSuccessorCanSettle() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fault = DeliveryFault(), current = MemoryConsentCurrent(), queue = try await open(root, fault: fault)
        _ = try await queue.setOptedOut(true, expectedGeneration: queue.snapshot().generation)
        let generation = try await queue.snapshot().generation
        fault.action = { if $0 == .afterConsentIntentWrite { current.withdraw() } }
        do { _ = try await queue.setOptedOut(false, expectedGeneration: generation, admissionGuard: { current.read() }); XCTFail("Stale grant settled") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        fault.action = nil
        let denied = try await queue.snapshot(); XCTAssertTrue(denied.identity.optedOut)
        XCTAssertTrue(try XCTUnwrap(EluExplicitConsentStore(directoryURL: root).load()).effectiveOptedOut)
        _ = try await queue.setOptedOut(true, expectedGeneration: denied.generation)
        await queue.close()
    }

    func testPartialConsentWriteAndMalformedOrLinkedRecordsNeverGrant() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".explicit-consent-v1.tmp"))
        let pending = try await open(root), snapshot = try await pending.snapshot()
        XCTAssertTrue(snapshot.identity.optedOut)
        _ = try await pending.setOptedOut(false, expectedGeneration: snapshot.generation)
        await pending.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".explicit-consent-v1.tmp").path))
        let record = root.appendingPathComponent(EluExplicitConsentStore.filename)
        for body in ["{}", "{\"schemaVersion\":1,\"optedOut\":0,\"settled\":true}", String(repeating: "x", count: 129)] {
            try Data(body.utf8).write(to: record)
            do { let bad = try await open(root); await bad.close(); XCTFail("Malformed consent opened") } catch {}
        }
        try FileManager.default.removeItem(at: record)
        let foreign = root.appendingPathComponent("foreign"); try Data("private".utf8).write(to: foreign)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: foreign)
        do { let bad = try await open(root); await bad.close(); XCTFail("Consent symlink opened") } catch {}
        XCTAssertEqual(try Data(contentsOf: foreign), Data("private".utf8))
    }

    func testInterruptedPendingReplacementKeepsRestrictiveInodeOverOlderGrant() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = EluExplicitConsentStore(directoryURL: root)
        try store.save(.init(optedOut: false, settled: true))
        let pending = root.appendingPathComponent(".explicit-consent-v1.tmp")
        try Data().write(to: pending)
        let inode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: pending.path)[.systemFileNumber] as? NSNumber)
        var checks = 0
        XCTAssertThrowsError(try store.save(.init(optedOut: false, settled: true), ifCurrent: {
            checks += 1; return checks == 1
        })) { XCTAssertEqual($0 as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        let retained = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: pending.path)[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(retained, inode)
        XCTAssertTrue(try XCTUnwrap(store.load()).effectiveOptedOut)
        try store.save(.init(optedOut: true, settled: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(try store.load(), .init(optedOut: true, settled: true))
    }

    func testProductionMemorySQLKeepsReplayFlagsAndExposureOnlyForCurrentOwner() async throws {
        let root = try directory()
        var settled = false
        defer { if settled { try? FileManager.default.removeItem(at: root) } }
        let clock = DeliveryClock(), key = siteKey
        let gate = EluV2ConfigAuthorityGate(siteKey: key, clock: .init(wallNow: { clock.read() }, continuousNow: { clock.ticks() }, floorTicks: { $0 }, floorNanoseconds: { $0 }))
        let queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root, exactConstructorSiteKey: key,
            persistence: .memory, clock: { clock.read() }, continuousClock: { clock.ticks() }, continuousBudgetConverter: { $0 },
            anonymousIdGenerator: { "anon-storage" }, sessionIdGenerator: { "session-storage" }, configurationGate: gate)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let config = try Data(contentsOf: source.appendingPathComponent("Conformance/V2/fixtures/config-enabled.json"))
        let h = DeliveryHarness(root: root, queue: queue, gate: gate, limits: try .init(), config: config, testClock: clock, fault: nil)
        try await h.install(); _ = try await h.append()
        let count = try await h.count(); XCTAssertEqual(count, 1)
        try await populateFlagsAndExposure(h)
        let version = try versions()
        XCTAssertTrue(try files(root).keys.allSatisfy { $0.hasSuffix("/.runtime-state-v1.lock") })
        await queue.close()
        let fresh = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root, exactConstructorSiteKey: key, persistence: .memory)
        let reopened = try await fresh.snapshot(); XCTAssertEqual(reopened.queuedCount, 0); XCTAssertNil(reopened.identity.session)
        let cached = await fresh.readFlagProjection(versions: version)
        XCTAssertNil(cached)
        try await fresh.ensureReplaySchema()
        let replay = try await fresh.replayInventory(); XCTAssertEqual(replay.replayCount, 0)
        let diagnostics = try await fresh.diagnosticsContinuity(); XCTAssertNil(diagnostics.epoch)
        await fresh.close()
        settled = true
    }

    private func populateFlagsAndExposure(_ h: DeliveryHarness) async throws {
        // DeliveryHarness activates replay only. Use the flag client's actual lazy
        // schema activation before attempting a durable flag request/cache write.
        try await h.queue.ensureFlagSchema()
        let authorization = await h.queue.submitFlagConfig(h.config, sourceWitness: h.witness)
        guard case .allowed = authorization else {
            XCTFail("Expected current flag authority, got \(authorization)")
            throw EluRuntimeQueueError.invalidState
        }
        let version = try versions()
        let begun = await h.queue.beginFlagReload(requestId: "memory-flags", versions: version)
        guard case let .begun(request) = begun else {
            XCTFail("Expected durable flag request, got \(begun)")
            throw EluRuntimeQueueError.invalidState
        }
        let requestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: request.request.canonicalData) as? [String: Any])
        let identity = try XCTUnwrap(requestJSON["identity"] as? [String: Any])
        let responseData = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestId": requestJSON["requestId"]!,
            "contextRevision": requestJSON["contextRevision"]!, "identityRevision": identity["revision"]!,
            "flagsRevision": "memory", "evaluatedAt": EluRFC3339.string(from: h.now),
            "expiresAt": EluRFC3339.string(from: h.now.addingTimeInterval(60)),
            "flags": ["flag": true], "payloads": ["flag": ["private": "only-in-memory"]]])
        let response = try EluV1FlagCodec.decodeResponse(responseData, for: request.request)
        let result = await h.queue.commitFlagReload(token: request.token, response: response); XCTAssertEqual(result, .updated)
        guard case .hit = await h.queue.readFlagCache(versions: version) else { throw EluRuntimeQueueError.invalidState }
        let command = EluV1CaptureCommand(kind: .capture, name: "$feature_flag_called", occurredAt: h.now,
            properties: ["$feature_flag": .string("flag")], versions: try versions())
        let exposure = EluFlagExposureRequest(anonymousId: "anon-storage", digest: try EluFlagExposureLedger.digest(key: "flag", value: .bool(true)))
        guard case .accepted = await h.queue.captureFlagExposure(command, exposure: exposure, admissionGuard: { true }) else {
            throw EluRuntimeQueueError.invalidState
        }
        guard case .rejected(.exposureAlreadyRecorded, _) = await h.queue.captureFlagExposure(command, exposure: exposure, admissionGuard: { true }) else {
            throw EluRuntimeQueueError.invalidState
        }
    }

    func testMemoryConsentRoundTripRetiresDormantPrivacyStateEvenWhenFinalBitMatches() async throws {
        let h = try await DeliveryHarness.make()
        // An unexpected throw must preserve the still-owned database and evidence.
        var settled = false
        defer { if settled { h.remove() } }
        try await h.install(); _ = try await h.append()
        try await populateFlagsAndExposure(h)
        let opened = try await h.queue.reconcileDiagnosticsContinuity(options: .init(enabled: true), admissionGuard: { true })
        XCTAssertTrue(opened)
        let before = try await h.queue.snapshot()
        XCTAssertFalse(before.identity.optedOut); XCTAssertNotNil(before.identity.session)
        let backlog = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
        XCTAssertFalse(backlog.isEmpty)
        let probe = NativeSessionHarness(h)
        let metadataQueries = ["SELECT metadata FROM capture_session_history", "SELECT metadata FROM person_identity_state", "SELECT metadata FROM flag_exposure_state"]
        let retained = try metadataQueries.map { try probe.bytes($0) }
        let activeDiagnostics = try await h.queue.diagnosticsContinuity(); XCTAssertNotNil(activeDiagnostics.epoch)
        await h.queue.close()
        let analyticsBefore = try analyticsFiles(h.root)
        let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: siteKey)
        let ownedDirectory = h.root.appendingPathComponent(namespace)
        let consent = EluExplicitConsentStore(directoryURL: ownedDirectory)
        XCTAssertNil(try consent.load()) // Existing false Boolean never proved an explicit choice.
        let memory = try await open(ownedDirectory)
        let initiallyDenied = try await memory.snapshot(); XCTAssertTrue(initiallyDenied.identity.optedOut)
        _ = try await memory.setOptedOut(true, expectedGeneration: memory.snapshot().generation)
        _ = try await memory.setOptedOut(false, expectedGeneration: memory.snapshot().generation)
        await memory.close()
        XCTAssertEqual(try analyticsFiles(h.root), analyticsBefore)
        XCTAssertEqual(try consent.load(), .init(optedOut: false, settled: true, persistentReconciled: false))

        h.queue = try await h.reopen()
        let after = try await h.queue.snapshot()
        XCTAssertFalse(after.identity.optedOut); XCTAssertNil(after.identity.session)
        XCTAssertEqual(after.identity.anonymousId, before.identity.anonymousId)
        XCTAssertEqual(after.identity.revision, before.identity.revision)
        XCTAssertEqual(after.identity.contextRevision, before.identity.contextRevision + 1)
        let resumed = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
        XCTAssertEqual(resumed, backlog)
        let replayCount = try await h.count(); XCTAssertEqual(replayCount, 0)
        let diagnostic = try await h.queue.diagnosticsContinuity(); XCTAssertNil(diagnostic.epoch)
        // Even after current flags authority is restored, the old cache witness
        // cannot be reused across the cross-mode consent barrier.
        _ = await h.queue.submitFlagConfig(h.config, sourceWitness: h.witness)
        let version = try versions(), flagCache = await h.queue.readFlagProjection(versions: version)
        XCTAssertNil(flagCache)
        XCTAssertEqual(try metadataQueries.map { try probe.bytes($0) }, retained)
        XCTAssertEqual(try consent.load(), .init(optedOut: false, settled: true, persistentReconciled: true))
        await h.queue.close(); h.queue = try await h.reopen()
        let again = try await h.queue.snapshot(); XCTAssertEqual(again, after) // Barrier settles once.
        await h.queue.close()
        settled = true
    }

    func testPersistentPrivacyBarrierFailureNeverMarksConsentReconciledOrReleasesLease() async throws {
        for point in [EluRuntimeQueueFaultPoint.beforeCommit, .afterCommit] {
            let fault = DeliveryFault(), h = try await DeliveryHarness.make(fault: fault)
            // Failed privacy settlement deliberately retains the original SQLite
            // connection and lease until process exit; do not unlink their files.
            try await h.install(); _ = try await h.append()
            await h.queue.close()
            let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: siteKey)
            let ownedDirectory = h.root.appendingPathComponent(namespace)
            let memory = try await open(ownedDirectory)
            _ = try await memory.setOptedOut(false, expectedGeneration: memory.snapshot().generation)
            await memory.close()
            fault.action = { if $0 == point { throw EluRuntimeQueueError.faultInjected($0) } }
            do { let unexpected = try await h.reopen(); await unexpected.close(); XCTFail("Unsettled privacy barrier opened") } catch {}
            XCTAssertEqual(try EluExplicitConsentStore(directoryURL: ownedDirectory).load(),
                .init(optedOut: false, settled: true, persistentReconciled: false))
            do { let next = try await open(ownedDirectory); await next.close(); XCTFail("Unsettled barrier released original lease") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
        }
    }

    func testSeparateSiteAndCanonicalAPIBaseNeverShareExplicitConsent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let policy = try EluEndpointPolicy(apiHost: URL(string: "https://analytics.example.test/a"))
        let otherPolicy = try EluEndpointPolicy(apiHost: URL(string: "https://analytics.example.test/b"))
        let first = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root, exactConstructorSiteKey: siteKey,
            endpointPolicy: policy, persistence: .memory, limits: .init())
        _ = try await first.setOptedOut(true, expectedGeneration: first.snapshot().generation)
        await first.close()
        for (key, selected) in [(siteKey, otherPolicy), (siteKey, .cloud), ("elu_pk_other_site", policy)] {
            let isolated = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root, exactConstructorSiteKey: key,
                endpointPolicy: selected, persistence: .memory, limits: .init())
            let snapshot = try await isolated.snapshot(); XCTAssertFalse(snapshot.identity.optedOut)
            await isolated.close()
        }
        let normalized = try EluEndpointPolicy(apiHost: URL(string: "https://ANALYTICS.example.test/a/"))
        let restored = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root, exactConstructorSiteKey: siteKey,
            endpointPolicy: normalized, persistence: .memory, limits: .init())
        let denied = try await restored.snapshot(); XCTAssertTrue(denied.identity.optedOut)
        await restored.close()
    }

    #if os(macOS)
    func testAbruptProcessDeathDropsMemoryAnalyticsButRetainsOnlySettledExplicitConsent() async throws {
        for point in ["pending", "applied", "denied", "granted"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            try runAbruptChild(root, point: point)
            let queue = try await open(root)
            let state = try await queue.snapshot()
            XCTAssertEqual(state.queuedCount, 0); XCTAssertEqual(state.nextSequence, 0)
            XCTAssertNil(state.identity.session); XCTAssertTrue(state.identity.superProperties.isEmpty)
            XCTAssertEqual(state.identity.optedOut, point != "granted")
            XCTAssertTrue(try files(root).keys.allSatisfy { [".runtime-state-v1.lock", EluExplicitConsentStore.filename].contains($0) })
            await queue.close()
        }
    }

    /// This child deliberately bypasses defer, deinit and SQLite close.
    func testMemoryAbruptExitChild() async throws {
        guard let path = ProcessInfo.processInfo.environment["ELU_MEMORY_TEST_DIRECTORY"],
              let point = ProcessInfo.processInfo.environment["ELU_MEMORY_TEST_POINT"] else { return }
        let fault = DeliveryFault(), queue = try await open(URL(fileURLWithPath: path), fault: fault)
        _ = try await queue.registerStandaloneSuperProperties(["private": .string("memory-child")])
        _ = try await queue.applyMutation(.setPersonProperties(set: ["private": .string("memory-child")], setOnce: [:], unset: []),
            versions: versions(), expectedGeneration: queue.snapshot().generation)
        _ = try await queue.setOptedOut(true, expectedGeneration: queue.snapshot().generation)
        if point == "denied" { Darwin._exit(73) }
        fault.action = { value in
            if point == "pending" && value == .afterConsentIntentWrite || point == "applied" && value == .beforeConsentSettlementWrite {
                Darwin._exit(73)
            }
        }
        _ = try await queue.setOptedOut(false, expectedGeneration: queue.snapshot().generation)
        if point == "granted" { Darwin._exit(73) }
        XCTFail("Abrupt exit point not reached")
    }

    private func runAbruptChild(_ directory: URL, point: String) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "EluAnalyticsTests.EluMemoryPersistenceTests/testMemoryAbruptExitChild", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["ELU_MEMORY_TEST_DIRECTORY"] = directory.path
        environment["ELU_MEMORY_TEST_POINT"] = point
        child.environment = environment
        // The selected child has no external workers; bounded output avoids a
        // held pipe, and the original PID is reaped on every termination path.
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        let deadline = Date().addingTimeInterval(20)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning { child.terminate() }
        let killDeadline = Date().addingTimeInterval(2)
        while child.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .exit)
        XCTAssertEqual(child.terminationStatus, 73)
    }
    #endif
}

private final class MemoryConsentCurrent: @unchecked Sendable {
    private let lock = NSLock(); private var current = true
    func withdraw() { lock.lock(); current = false; lock.unlock() }
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return current }
}

private final class MemoryContextBox: @unchecked Sendable {
    private let lock = NSLock(); private var context: EluRuntimeBackendContext?
    func save(_ value: EluRuntimeBackendContext) { lock.lock(); context = value; lock.unlock() }
    func read() -> EluRuntimeBackendContext? { lock.lock(); defer { lock.unlock() }; return context }
}
