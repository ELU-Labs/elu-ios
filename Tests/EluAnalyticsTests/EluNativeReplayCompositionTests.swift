import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeReplayCompositionTests: XCTestCase {
    func testRuntimeForwardsColdSealedNativeRowWithoutSessionRootOrLedger() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let original = try await h.base.queue.storedReplayChunks()[0].prepared.body
        let runtime = try await open(h)
        let state = try await runtime.queueSnapshot(); XCTAssertNil(state.identity.session)
        let permission = try await runtime.currentSealedReplayDelivery(capabilities: h.proof)
        XCTAssertNotNil(permission); XCTAssertEqual(try h.base.schemaVersion(), 5)
        let sent = expectation(description: "original sealed request")
        let transport = CompositionTransport { sent.fulfill() }
        let installed = await runtime.installNativeReplayComposition(lifecycle: EluNativeReplayLifecycle(), capabilities: h.proof, transport: transport)
        let composition = try XCTUnwrap(installed)
        await fulfillment(of: [sent], timeout: 3)
        await composition.waitForCurrentDelivery()
        let body = await transport.firstBody(); XCTAssertEqual(body, original)
        await runtime.close()
        h.base.queue = try await h.base.reopen()
        let rows = try await h.base.queue.storedReplayChunks(); XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(try h.base.schemaVersion(), 5)
        await h.base.queue.close()
    }

    func testDefaultEmptyProofDoesNotCaptureOrDeliverAndRetiresUnsupportedGeneration() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let original = try await h.base.queue.storedReplayChunks(); XCTAssertEqual(original.count, 1)
        let runtime = try await open(h), transport = CompositionTransport {}
        let installed = await runtime.installNativeReplayComposition(lifecycle: EluNativeReplayLifecycle(), transport: transport)
        let composition = try XCTUnwrap(installed)
        await composition.reevaluate()
        let calls = await transport.count(); XCTAssertEqual(calls, 0)
        let state = try await runtime.queueSnapshot(); XCTAssertNil(state.identity.session)
        await runtime.close()
        h.base.queue = try await h.base.reopen()
        let retained = try await h.base.queue.storedReplayChunks(); XCTAssertTrue(retained.isEmpty)
        XCTAssertEqual(try h.base.schemaVersion(), 5)
        await h.base.queue.close()
    }

    func testRuntimeDoesNotAdoptSourceRenewalAcrossTimezoneObservation() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let zone = CompositionZone(), runtime = try await open(h, zone: zone)
        let entered = expectation(description: "original timezone observation")
        let release = DispatchSemaphore(value: 0)
        zone.once = { entered.fulfill(); release.wait() }
        let pending = Task { try await runtime.currentSealedReplayDelivery(capabilities: h.proof) }
        await fulfillment(of: [entered], timeout: 3)
        let original = try XCTUnwrap(h.base.witness)
        try h.publish(); XCTAssertFalse(h.base.gate.isCurrent(original))
        release.signal()
        let stale = try await pending.value; XCTAssertNil(stale)
        _ = await runtime.applyConfiguration(h.base.config, sourceWitness: h.base.witness)
        let next = try await runtime.currentSealedReplayDelivery(capabilities: h.proof); XCTAssertNotNil(next)
        await runtime.close()
    }

    func testRetainedRuntimeAuthorityCannotReviveAfterTimezoneMismatchOrSourceExpiry() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let zone = CompositionZone(), runtime = try await open(h, zone: zone)
        let first = try await runtime.currentSealedReplayDelivery(capabilities: h.proof), original = try XCTUnwrap(first)
        zone.value = "Europe/Paris"; XCTAssertFalse(original.isCurrent())
        zone.value = "America/Los_Angeles"; XCTAssertFalse(original.isCurrent())
        let next = try await runtime.currentSealedReplayDelivery(capabilities: h.proof), current = try XCTUnwrap(next)
        let wall = h.base.now; h.base.testClock.advance(601); h.base.testClock.set(wall)
        XCTAssertFalse(current.isCurrent())
        let expired = try await runtime.currentSealedReplayDelivery(capabilities: h.proof); XCTAssertNil(expired)
        await runtime.close()
    }

    func testDuplicateCancelledRuntimeCloseWaitsForPhysicalRefusalAndOriginalReceipt() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let runtime = try await open(h)
        let entered = expectation(description: "physical request is retained")
        let transport = CompositionTransport(held: true) { entered.fulfill() }
        let installed = await runtime.installNativeReplayComposition(lifecycle: EluNativeReplayLifecycle(), capabilities: h.proof, transport: transport)
        let composition = try XCTUnwrap(installed)
        await fulfillment(of: [entered], timeout: 3)
        let completion = CompositionCounter()
        let first = Task { await runtime.close(); completion.increment() }
        let second = Task { await runtime.close(); completion.increment() }
        first.cancel()
        let deadline = Date().addingTimeInterval(3)
        var waiters = await composition.registeredDeliveryWaitersForTesting()
        while waiters != 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
            waiters = await composition.registeredDeliveryWaitersForTesting()
        }
        XCTAssertEqual(waiters, 1); XCTAssertEqual(completion.value, 0)
        do { let duplicate = try await h.base.reopen(); await duplicate.close(); XCTFail("physical owner released") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
        await transport.releaseRefusal()
        await first.value; await second.value; XCTAssertEqual(completion.value, 2)
        h.base.queue = try await h.base.reopen()
        let rows = try await h.base.queue.storedReplayChunks(); XCTAssertEqual(rows.count, 1)
        let value = try await h.authority(), permission = try XCTUnwrap(value)
        guard case .idle = try await h.base.queue.claimNextReplay(permission) else { return XCTFail("original refusal lost") }
        await h.base.queue.close()
    }

    func testReevaluationAndPrivacySignalsDoNotReplaceWithdrawalListener() {
        let lifecycle = EluNativeReplayLifecycle(), attachment = UUID()
        let withdrawn = CompositionCounter(), wake = CompositionCounter(), privacy = CompositionCounter()
        lifecycle.observeWithdrawal { withdrawn.increment() }
        lifecycle.observeReevaluation { wake.increment() }
        lifecycle.observePrivacyChange { privacy.increment() }
        lifecycle.attached(attachment); XCTAssertEqual(withdrawn.value, 1)
        lifecycle.receive(.didActivate, attachment: attachment)
        lifecycle.receive(.sceneDidBackground, attachment: attachment)
        XCTAssertEqual(wake.value, 2); XCTAssertEqual(withdrawn.value, 1)
        lifecycle.receive(.timeZoneChanged, attachment: attachment)
        XCTAssertEqual(privacy.value, 1); XCTAssertEqual(withdrawn.value, 1)
        lifecycle.receive(.applicationWillResign, attachment: attachment)
        XCTAssertEqual(withdrawn.value, 2); XCTAssertEqual(wake.value, 3)
        lifecycle.close()
        lifecycle.receive(.didActivate, attachment: attachment)
        lifecycle.receive(.timeZoneChanged, attachment: attachment)
        XCTAssertEqual(wake.value, 3); XCTAssertEqual(privacy.value, 1)
    }

    func testNonclosingPassJoinWaitsForOriginalPhysicalRefusal() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
        let permission = try await h.deliveryAuthority()
        let entered = expectation(description: "pass already owns physical send")
        let transport = CompositionTransport(held: true) { entered.fulfill() }
        let coordinator = EluV2ReplayDeliveryCoordinator(queue: h.queue, transport: transport, wallNow: { h.now })
        let pass = Task { await coordinator.trigger(permission) }
        await fulfillment(of: [entered], timeout: 3)
        let completed = CompositionCounter()
        let joining = Task { let result = await coordinator.waitForCurrentPass(); completed.increment(); return result }
        let deadline = Date().addingTimeInterval(3)
        var waiters = await coordinator.registeredCloseWaiterCountForTesting()
        while waiters != 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
            waiters = await coordinator.registeredCloseWaiterCountForTesting()
        }
        XCTAssertEqual(waiters, 1); XCTAssertEqual(completed.value, 0)
        await transport.releaseRefusal()
        _ = await pass.value
        let outcome = await joining.value; XCTAssertEqual(outcome, .settled)
        let next = await coordinator.trigger(permission); XCTAssertEqual(next.stopped, .withdrawn)
        let rows = try await h.queue.storedReplayChunks(); XCTAssertEqual(rows.count, 1)
        _ = await coordinator.closeAndWait(); await h.queue.close()
    }

    func testPreparedOwnershipIsLocalAndRejectsForeignOrWithdrawnInvocation() async throws {
        let h = try await SealedPolicyTestHarness.make(clearSession: false), native = NativeSessionHarness(h.base)
        defer { h.base.remove() }
        try await native.update(rate: 1, cap: 60)
        let owner = EluNativeReplayAuthority(queue: h.base.queue, clock: { h.base.now })
        let other = EluNativeReplayAuthority(queue: h.base.queue, clock: { h.base.now })
        let source = try XCTUnwrap(h.base.witness)
        let prepared = try await owner.prepare(source: source, capabilities: h.proof, timeZoneIdentifier: h.zone)
        XCTAssertTrue(owner.ownsPrepared(prepared)); XCTAssertFalse(other.ownsPrepared(prepared))
        let wall = h.base.now
        h.base.testClock.set(wall.addingTimeInterval(-10))
        // Local identity checks must not consume the now-invalid persistable clock.
        XCTAssertTrue(owner.ownsPrepared(prepared)); XCTAssertFalse(other.ownsPrepared(prepared))
        h.base.testClock.set(wall); XCTAssertTrue(prepared.isCurrent())
        owner.withdraw(); XCTAssertFalse(owner.ownsPrepared(prepared))
        await owner.close(); await other.close(); await h.base.queue.close()
    }

    func testRuntimeCloseRetainsQuarantineWhenOriginalRefusalCannotBePersisted() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let runtime = try await open(h)
        let entered = expectation(description: "original physical request before durable corruption")
        let transport = CompositionTransport(held: true) { entered.fulfill() }
        let installed = await runtime.installNativeReplayComposition(lifecycle: EluNativeReplayLifecycle(), capabilities: h.proof, transport: transport)
        let composition = try XCTUnwrap(installed)
        await fulfillment(of: [entered], timeout: 3)
        // The original request is physically active; no queue transaction is
        // held. Corrupt its exact receipt metadata to force persistence failure.
        try h.base.sql("UPDATE replay_delivery SET metadata=X'00'")
        await transport.releaseRefusal()
        await composition.waitForCurrentDelivery()
        await runtime.close(); await runtime.close()
        let settlement = await runtime.nativeReplayCompositionSettlement
        XCTAssertEqual(settlement, .quarantined)
        do { let duplicate = try await h.base.reopen(); await duplicate.close(); XCTFail("unresolved refusal released installation") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
    }

    func testDeferredPublicActivationObservesInitialContextBeforeSendingOriginalRow() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let original = try await h.base.queue.storedReplayChunks()[0].prepared.body
        let runtime = try await open(h)
        let sent = expectation(description: "delivery after initial operations")
        let transport = CompositionTransport { sent.fulfill() }
        let installed = await runtime.installNativeReplayComposition(lifecycle: EluNativeReplayLifecycle(), capabilities: h.proof,
            deferredUntilActivation: true, transport: transport)
        let composition = try XCTUnwrap(installed)
        await composition.reevaluate()
        let before = await transport.count(); XCTAssertEqual(before, 0)
        _ = await runtime.registerSuperProperties(["initial_context": .string("accepted first")])
        await composition.reevaluate()
        let pending = await transport.count(); XCTAssertEqual(pending, 0)
        await runtime.activateNativeReplayComposition()
        await fulfillment(of: [sent], timeout: 3)
        await composition.waitForCurrentDelivery()
        let body = await transport.firstBody(); XCTAssertEqual(body, original)
        await runtime.close()
    }

    func testRetainedSealedAuthorityCannotOutliveRuntimeWhileCompositionRetainsQueue() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        var runtime: EluStandaloneRuntime? = try await open(h)
        let value = try await runtime?.currentSealedReplayDelivery(capabilities: h.proof)
        let authority = try XCTUnwrap(value); XCTAssertTrue(authority.isCurrent())
        // Keep the composition (and its queue) alive independently so the
        // assertion cannot pass merely because the SQLite actor was destroyed.
        let composition = await runtime?.installNativeReplayComposition(lifecycle: EluNativeReplayLifecycle(),
            capabilities: h.proof, deferredUntilActivation: true, transport: CompositionTransport {})
        weak var original = runtime
        runtime = nil
        let deadline = Date().addingTimeInterval(3)
        while original != nil && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNil(original); XCTAssertFalse(authority.isCurrent())
        _ = await composition?.closeAndWait()
    }

    func testRuntimeDestructionCannotScheduleAuthorityCleanupBehindHeldQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("elu-runtime-deinit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = CompositionDeinitClock()
        var runtime: EluStandaloneRuntime? = try await EluStandaloneRuntime.make(rootDirectoryURL: root,
            siteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", transport: CompositionEventTransport(), clock: { clock.read() })
        let queue = try XCTUnwrap(Mirror(reflecting: try XCTUnwrap(runtime)).children.first { $0.label == "queue" }?.value as? EluSQLiteRuntimeQueue)
        weak var authority = Mirror(reflecting: try XCTUnwrap(runtime)).children.first { $0.label == "nativeAuthority" }?.value as? EluNativeReplayAuthority
        weak var original = runtime
        XCTAssertNotNil(authority)
        let entered = expectation(description: "actual queue actor is held in its original clock")
        let release = DispatchSemaphore(value: 0)
        clock.once = { entered.fulfill(); release.wait() }
        let operation = Task { try await queue.registerStandaloneSuperProperties(["held": .bool(true)]) }
        await fulfillment(of: [entered], timeout: 3)
        let reads = clock.readCount
        // The held queue prevents any newly-created cleanup task from finishing.
        // Its strong authority capture therefore makes the old destructor fail
        // synchronously here; there is no sleep-based absence assertion.
        runtime = nil
        XCTAssertNil(original)
        XCTAssertNil(authority, "destruction must not create a task retaining the original authority")
        XCTAssertEqual(clock.readCount, reads, "destruction must not observe clocks")
        release.signal()
        _ = try await operation.value
        await queue.close()
    }

    private func open(_ h: SealedPolicyTestHarness, zone: CompositionZone = CompositionZone()) async throws -> EluStandaloneRuntime {
        await h.base.queue.close()
        let runtime = try await EluStandaloneRuntime.make(rootDirectoryURL: h.base.root,
            siteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", limits: h.base.limits,
            transport: CompositionEventTransport(), configurationGate: h.base.gate,
            clock: { h.base.now }, continuousClock: { h.base.testClock.ticks() },
            continuousBudgetConverter: { $0 }, nativeContinuousNanoseconds: { $0 },
            timeZoneIdentifier: { zone.read() }, flushDelayNanoseconds: 600_000_000_000)
        _ = await runtime.applyConfiguration(h.base.config, sourceWitness: h.base.witness)
        return runtime
    }
}

private struct CompositionEventTransport: EluV1BatchHTTPTransport {
    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse {
        throw EluV1BoundTransportError.staleAuthority
    }
}
private final class CompositionCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
private final class CompositionZone: @unchecked Sendable {
    private let lock = NSLock(); private var stored = "America/Los_Angeles"
    private var callback: (@Sendable () -> Void)?
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    var once: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }
    func read() -> String? {
        lock.lock(); let original = stored, action = callback; callback = nil; lock.unlock()
        action?(); return original
    }
}
private actor CompositionTransport: EluV2ReplayHTTPTransport {
    private var bodies: [Data] = []
    private let held: Bool
    private let entered: @Sendable () -> Void
    private var waiter: CheckedContinuation<Void, Never>?
    init(held: Bool = false, entered: @escaping @Sendable () -> Void) { self.held = held; self.entered = entered }
    func count() -> Int { bodies.count }
    func firstBody() -> Data? { bodies.first }
    func releaseRefusal() { let current = waiter; waiter = nil; current?.resume() }
    func send(_ dispatch: EluV2ReplayDispatch) async throws -> EluV1BatchHTTPResponse {
        guard let use = dispatch.takePhysicalUse() else { throw EluV1BoundTransportError.occupied }
        defer { use.settle() }
        guard await use.revalidate(), use.beginOnce() else { throw EluV1BoundTransportError.staleAuthority }
        bodies.append(use.request.body)
        if held {
            await withCheckedContinuation { waiter = $0; entered() }
            return EluV1BatchHTTPResponse(status: 401, headers: [:], body: Data())
        }
        let request = try EluV2ReplayPreparedRequest(use.request.body, captureProtocolGeneration: "replay-v2-1")
        let response = EluV1BatchHTTPResponse(status: 200, headers: [:], body: Data("{\"schemaVersion\":2,\"requestId\":\"\(request.requestId)\",\"replayId\":\"\(request.replayId)\",\"chunkId\":\"\(request.chunkId)\",\"sequence\":\(request.sequence),\"result\":\"accepted\"}".utf8))
        entered(); return response
    }
}

private final class CompositionDeinitClock: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var reads = 0
    var once: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read() -> Date {
        lock.lock(); reads += 1; let action = callback; callback = nil; lock.unlock()
        action?()
        return Date(timeIntervalSince1970: 1_785_888_090)
    }
}
