import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import EluAnalytics

final class EluNativeReplayCompositionTests: XCTestCase {
    func testLocalControlNeverReportsDesiredStateAsPhysicalRecording() {
        let control = EluNativeReplayLocalControl(), probe = ReplayLocalProbe()
        let original = control.token(), id = UUID()
        XCTAssertFalse(control.isRecording())
        control.install(id: id, token: original, stop: { probe.stop() }, recording: { probe.isRecording() })
        XCTAssertFalse(control.isRecording())
        probe.begin()
        XCTAssertTrue(control.isRecording())
        control.setEnabled(false)
        XCTAssertFalse(control.isRecording())
        XCTAssertEqual(probe.stops(), 1)
        control.setEnabled(true)
        XCTAssertFalse(control.permits(original), "An earlier collector cannot resume after stop/start")
        XCTAssertFalse(control.isRecording())
        let next = ReplayLocalProbe(), nextID = UUID()
        next.begin()
        control.install(id: nextID, token: control.token(), stop: { next.stop() }, recording: { next.isRecording() })
        control.remove(id: id)
        XCTAssertTrue(control.isRecording(), "Old completion cannot clear the new original")
        control.remove(id: nextID)
        XCTAssertFalse(control.isRecording())
    }

    func testStartRacingOriginalStopCallbackCannotReportOldCollectorActive() {
        let control = EluNativeReplayLocalControl(), probe = ReplayLocalProbe()
        probe.begin()
        control.install(id: UUID(), token: control.token(), stop: {
            // Reentrant start models a newer call before the original stop
            // callback physically freezes its still-active collector.
            control.setEnabled(true)
            XCTAssertTrue(probe.isRecording())
            XCTAssertFalse(control.isRecording())
            probe.stop()
        }, recording: { probe.isRecording() })
        XCTAssertTrue(control.isRecording())
        control.setEnabled(false)
        XCTAssertFalse(control.isRecording())
    }

    func testLocalStopBeforeCollectorInstallAndDuringStatusCannotEscape() {
        let control = EluNativeReplayLocalControl(), probe = ReplayLocalProbe()
        let old = control.token()
        control.setEnabled(false); control.setEnabled(true)
        probe.begin()
        control.install(id: UUID(), token: old, stop: { probe.stop() }, recording: { probe.isRecording() })
        XCTAssertEqual(probe.stops(), 1)
        XCTAssertFalse(control.isRecording())
        control.install(id: UUID(), token: control.token(), stop: {}, recording: {
            control.setEnabled(false)
            return true
        })
        XCTAssertFalse(control.isRecording(), "Recheck original local generation after the physical observation")
    }

    func testLocalStopBeforeCompositionKeepsColdSealedDeliveryAndDoesNotGrantCapture() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let original = try await h.base.queue.storedReplayChunks()[0].prepared.body
        let runtime = try await open(h)
        runtime.setNativeReplayRecordingEnabled(false)
        XCTAssertFalse(runtime.nativeReplayIsRecording())
        let sent = expectation(description: "sealed delivery after local stop")
        let transport = CompositionTransport { sent.fulfill() }
        let installed = await runtime.installNativeReplayComposition(lifecycle: EluNativeReplayLifecycle(), capabilities: h.proof, transport: transport)
        let composition = try XCTUnwrap(installed)
        await fulfillment(of: [sent], timeout: 3)
        await composition.waitForCurrentDelivery()
        let body = await transport.firstBody(); XCTAssertEqual(body, original)
        XCTAssertFalse(runtime.nativeReplayIsRecording())
        runtime.setNativeReplayRecordingEnabled(true)
        await composition.reevaluate()
        XCTAssertFalse(runtime.nativeReplayIsRecording(), "Start cannot supply a current UIKit root")
        await runtime.close()
        XCTAssertFalse(runtime.nativeReplayIsRecording())
    }

    func testRuntimeForwardsColdSealedNativeRowWithoutSessionRootOrLedger() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let original = try await h.base.queue.storedReplayChunks()[0].prepared.body
        let runtime = try await open(h)
        let state = try await runtime.queueSnapshot(); XCTAssertNil(state.identity.session)
        let permission = try await runtime.currentSealedReplayDelivery(capabilities: h.proof)
        XCTAssertNotNil(permission); XCTAssertEqual(try h.base.schemaVersion(), 53)
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
        XCTAssertEqual(try h.base.schemaVersion(), 53)
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
        XCTAssertEqual(try h.base.schemaVersion(), 53)
        await h.base.queue.close()
    }

    func testProductionCapabilitiesDeliverOriginalColdV2BytesOnlyAfterActivation() async throws {
        let h = try await SealedPolicyTestHarness.make(tuple: .v2); defer { h.base.remove() }
        let rows = try await h.base.queue.storedReplayChunks()
        let original = try XCTUnwrap(rows.first).prepared
        XCTAssertEqual(original.codec, "elu-native-wireframe-v2")
        let runtime = try await open(h)
        let state = try await runtime.queueSnapshot(); XCTAssertNil(state.identity.session)
        let sent = expectation(description: "original v2 sealed bytes")
        let transport = CompositionTransport { sent.fulfill() }
        let installed = await runtime.installNativeReplayComposition(lifecycle: EluNativeReplayLifecycle(),
            capabilities: EluStandaloneRuntime.readbackProvenReplayCapabilities,
            deferredUntilActivation: true, transport: transport)
        let composition = try XCTUnwrap(installed)
        await composition.reevaluate()
        let before = await transport.count(); XCTAssertEqual(before, 0)
        XCTAssertFalse(runtime.nativeReplayIsRecording(), "Local format support supplies no current root/session")
        await runtime.activateNativeReplayComposition()
        await fulfillment(of: [sent], timeout: 3)
        await composition.waitForCurrentDelivery()
        let body = await transport.firstBody(); XCTAssertEqual(body, original.body)
        XCTAssertFalse(runtime.nativeReplayIsRecording())
        await runtime.close()
        h.base.queue = try await h.base.reopen()
        let remaining = try await h.base.queue.storedReplayChunks(); XCTAssertTrue(remaining.isEmpty)
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

    #if canImport(UIKit)
    @MainActor func testSameWindowRootReplacementAndViewportChangeStartNewStreamsAutomatically() async throws {
        let f = try await makeUIKitFixture()
        do {
            try await waitUIKit("initial authorized frame reaches delivery", diagnostics: { await f.captureDiagnostics() }) { await f.transport.count() == 1 }
            let first = try await f.transport.requests()[0], ledger = try await f.queue.nativeReplaySessionState()
            f.h.base.testClock.advance(1)
            let replacement = UIViewController()
            replacement.view = UIView(frame: f.window.bounds)
            f.window.rootViewController = replacement
            try await waitUIKit("replacement frame reaches delivery") { await f.transport.count() >= 2 }
            let second = try await f.transport.requests()[1]
            XCTAssertNotEqual(second.replayId, first.replayId)
            XCTAssertEqual(second.sessionId, first.sessionId); XCTAssertEqual(second.sequence, 0)
            f.h.base.testClock.advance(1)
            replacement.view.bounds.size = CGSize(width: replacement.view.bounds.height, height: replacement.view.bounds.width)
            try await waitUIKit("changed viewport reaches delivery") { await f.transport.count() >= 3 }
            let third = try await f.transport.requests()[2], after = try await f.queue.nativeReplaySessionState()
            XCTAssertEqual(Set([first.replayId, second.replayId, third.replayId]).count, 3)
            XCTAssertEqual(third.sessionId, first.sessionId); XCTAssertEqual(third.sequence, 0)
            XCTAssertEqual(after.session?.samplingHash, ledger.session?.samplingHash)
            XCTAssertEqual(after.session?.firstStartAt, ledger.session?.firstStartAt)
            XCTAssertEqual(after.session?.maximumDurationSeconds, ledger.session?.maximumDurationSeconds)
            XCTAssertGreaterThanOrEqual(after.session?.elapsedFloorMicroseconds ?? 0, 2_000_000)
            let result = await f.close(); XCTAssertEqual(result, .settled)
        } catch { _ = await f.close(); throw error }
    }

    @MainActor func testMissingRootObserverRecoversWithoutConfigurationOrLocalStart() async throws {
        let f = try await makeUIKitFixture()
        do {
            try await waitUIKit("initial authorized frame reaches delivery", diagnostics: { await f.captureDiagnostics() }) { await f.transport.count() == 1 }
            let first = try await f.transport.requests()[0]
            f.h.base.testClock.advance(1); f.window.rootViewController = nil
            try await waitUIKit("original capture settles and missing-root observation begins") { await f.composition.isObservingRootForTesting() }
            XCTAssertFalse(f.runtime.nativeReplayIsRecording())
            let between = try await f.queue.nativeReplaySessionState(); XCTAssertNil(between.session?.activeEpoch)
            let replacement = UIViewController(); replacement.view = UIView(frame: f.window.bounds)
            f.window.rootViewController = replacement
            try await waitUIKit("replacement frame reaches delivery") { await f.transport.count() >= 2 }
            let next = try await f.transport.requests()[1]
            XCTAssertNotEqual(next.replayId, first.replayId); XCTAssertEqual(next.sessionId, first.sessionId)
            let observing = await f.composition.isObservingRootForTesting(); XCTAssertFalse(observing)
            let result = await f.close(); XCTAssertEqual(result, .settled)
        } catch { _ = await f.close(); throw error }
    }

    @MainActor func testRootObservationCannotRestartAfterLocalStopExpiryOrConsent() async throws {
        for mode in ["local-stop", "expiry", "consent"] {
            let f = try await makeUIKitFixture()
            do {
                try await waitUIKit("initial authorized frame reaches delivery", diagnostics: { await f.captureDiagnostics() }) { await f.transport.count() == 1 }
                f.window.rootViewController = nil
                try await waitUIKit("original capture settles and missing-root observation begins") { await f.composition.isObservingRootForTesting() }
                if mode == "local-stop" {
                    f.runtime.setNativeReplayRecordingEnabled(false)
                    await f.composition.reevaluate()
                } else if mode == "expiry" { f.h.base.testClock.advance(601) }
                else {
                    let intent = UUID(); f.runtime.acceptConsentIntent(intent, optedOut: true)
                    let denied = await f.runtime.setOptedOut(true, intent: intent)
                    XCTAssertEqual(denied?.identity.optedOut, true)
                }
                try await waitUIKit("root observation stops after \(mode)") { !(await f.composition.isObservingRootForTesting()) }
                f.window.rootViewController = f.controller
                await f.composition.reevaluate()
                XCTAssertFalse(f.runtime.nativeReplayIsRecording())
                let count = await f.transport.count(); XCTAssertEqual(count, 1, mode)
                let observing = await f.composition.isObservingRootForTesting(); XCTAssertFalse(observing)
                let result = await f.close(); XCTAssertEqual(result, .settled)
            } catch { _ = await f.close(); throw error }
        }
    }

    @MainActor func testReplacementCannotStartBeforeOriginalAccountingTransactionSettles() async throws {
        let fault = DeliveryFault(), f = try await makeUIKitFixture(fault: fault)
        let release = DispatchSemaphore(value: 0), once = CompositionOnce()
        do {
            try await waitUIKit("initial authorized frame reaches delivery", diagnostics: { await f.captureDiagnostics() }) { await f.transport.count() == 1 }
            await f.composition.waitForCurrentDelivery()
            let entered = expectation(description: "original stop owns accounting transaction")
            fault.action = { point in
                if point == .beforeCommit, once.take() { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
            }
            f.h.base.testClock.advance(1)
            let replacement = UIViewController(); replacement.view = UIView(frame: f.window.bounds)
            f.window.rootViewController = replacement
            await fulfillment(of: [entered], timeout: 3)
            let count = await f.transport.count(), observing = await f.composition.isObservingRootForTesting()
            XCTAssertEqual(count, 1); XCTAssertFalse(observing)
            XCTAssertFalse(f.runtime.nativeReplayIsRecording())
            fault.action = nil; release.signal()
            try await waitUIKit("replacement frame reaches delivery") { await f.transport.count() >= 2 }
            let result = await f.close(); XCTAssertEqual(result, .settled)
        } catch { fault.action = nil; release.signal(); _ = await f.close(); throw error }
    }

    @MainActor func testUnknownRootStopQuarantinesWithoutObserverOrReplacement() async throws {
        let fault = DeliveryFault(), f = try await makeUIKitFixture(fault: fault), once = CompositionOnce()
        do {
            try await waitUIKit("initial authorized frame reaches delivery", diagnostics: { await f.captureDiagnostics() }) { await f.transport.count() == 1 }
            await f.composition.waitForCurrentDelivery()
            fault.action = { point in
                if point == .afterCommit, once.take() { throw EluRuntimeQueueError.faultInjected(point) }
            }
            let replacement = UIViewController(); replacement.view = UIView(frame: f.window.bounds)
            f.window.rootViewController = replacement
            try await waitUIKit("original accounting commit reaches injected ambiguity") { once.wasTaken() }
            fault.action = nil
            let result = await f.close(); XCTAssertEqual(result, .quarantined)
            let count = await f.transport.count(), observing = await f.composition.isObservingRootForTesting()
            XCTAssertEqual(count, 1); XCTAssertFalse(observing)
            XCTAssertFalse(f.runtime.nativeReplayIsRecording())
            // close() preserves the actual quarantined directory/lease.
        } catch { fault.action = nil; _ = await f.close(); throw error }
    }

    @MainActor func testRefusedRecordingSettlesAndDoesNotLoopNewRecordingsUntilSourceRenews() async throws {
        let f = try await makeUIKitFixture(transport: CompositionTransport(refuse: true) {})
        do {
            try await waitUIKit("initial frame reaches delivery", diagnostics: { await f.captureDiagnostics() }) { await f.transport.count() == 1 }
            await f.composition.waitForCurrentDelivery()
            let first = try await f.transport.requests()[0]
            // The refused head is held, so the next chunk of that recording is not
            // stored. The run settles without quarantining capture.
            f.h.base.testClock.advance(10)
            try await waitUIKit("held recording stops capture", diagnostics: { await f.captureDiagnostics() }) {
                guard !f.runtime.nativeReplayIsRecording() else { return false }
                return !(await f.composition.hasCaptureAfterEvaluationForTesting())
            }
            let stored = try await f.queue.storedReplayChunks()
            XCTAssertEqual(stored.map(\.prepared.replayId), [first.replayId]); XCTAssertEqual(stored.map(\.prepared.sequence), [0])
            // Events and reevaluations in the same source, identity and session
            // never start a new recording behind an endpoint that refuses.
            for index in 0 ..< 3 {
                guard case .accepted = await f.runtime.capture("after-refusal-\(index)") else { return XCTFail("event capture") }
                await f.composition.reevaluate()
                let started = await f.composition.hasCaptureAfterEvaluationForTesting()
                XCTAssertFalse(started, "reevaluation \(index) started a new recording")
            }
            await f.composition.waitForCurrentDelivery()
            let sends = await f.transport.count(); XCTAssertEqual(sends, 1)
            XCTAssertFalse(f.runtime.nativeReplayIsRecording())
            let unchanged = try await f.queue.storedReplayChunks(); XCTAssertEqual(unchanged, stored)
            // A renewed source is a new capture context, so one new recording starts.
            try f.h.publish()
            _ = await f.runtime.applyConfiguration(f.h.base.config, sourceWitness: f.h.base.witness)
            await f.composition.reevaluate()
            try await waitUIKit("renewed source starts one recording", diagnostics: { await f.captureDiagnostics() }) { await f.transport.count() >= 2 }
            let next = try await f.transport.requests()[1]
            XCTAssertNotEqual(next.replayId, first.replayId)
            XCTAssertEqual(next.sessionId, first.sessionId); XCTAssertEqual(next.sequence, 0)
            let result = await f.close(); XCTAssertEqual(result, .settled)
        } catch { _ = await f.close(); throw error }
    }

    @MainActor func testBackgroundTerminateRelaunchInsideIdleTimeoutRecordsNewReplay() async throws {
        let f = try await makeUIKitFixture()
        var relaunched: CompositionUIKitFixture?
        do {
            try await waitUIKit("initial frame reaches delivery", diagnostics: { await f.captureDiagnostics() }) { await f.transport.count() == 1 }
            f.h.base.testClock.advance(10)
            try await waitUIKit("second chunk reaches delivery", diagnostics: { await f.captureDiagnostics() }) { await f.transport.count() >= 2 }
            let old = try await f.transport.requests()
            XCTAssertEqual(Set(old.map(\.replayId)).count, 1); XCTAssertEqual(old.map(\.sequence).prefix(2), [0, 1])
            _ = await f.runtime.markBackgrounded(at: f.h.base.now)
            try await waitUIKit("background settles capture", diagnostics: { await f.captureDiagnostics() }) {
                guard !f.runtime.nativeReplayIsRecording() else { return false }
                return try await f.queue.nativeReplaySessionState().session?.activeEpoch == nil
            }
            let delivered = try await f.transport.requests()
            let closed = await f.close(keepingStore: true); XCTAssertEqual(closed, .settled)
            // The system ends the suspended app; it is opened again inside the idle timeout.
            // The closed time counts toward the 60 s budget, so keep the gap short.
            f.h.base.testClock.advance(5)
            let next = try await makeUIKitFixture(relaunching: f.h); relaunched = next
            try await waitUIKit("relaunched recording reaches delivery", diagnostics: { await next.captureDiagnostics() }) { await next.transport.count() >= 1 }
            let first = try await next.transport.requests()[0]
            XCTAssertFalse(delivered.contains { $0.replayId == first.replayId })
            XCTAssertEqual(first.sessionId, old[0].sessionId); XCTAssertEqual(first.sequence, 0)
            let lastEnd = try delivered.map { try EluNativeReplayCaptureClock.milliseconds($0.endedAt) }.max() ?? 0
            XCTAssertGreaterThan(try EluNativeReplayCaptureClock.milliseconds(first.startedAt), lastEnd)
            XCTAssertTrue(next.runtime.nativeReplayIsRecording())
            let ledger = try await next.queue.nativeReplaySessionState().session
            XCTAssertEqual(ledger?.sessionId, old[0].sessionId); XCTAssertEqual(ledger?.interrupted, false)
            let result = await next.close(); XCTAssertEqual(result, .settled)
        } catch {
            if let relaunched { _ = await relaunched.close() }
            _ = await f.close(); throw error
        }
    }

    @MainActor func testAppUpdateRelaunchBindsNewVersionsToNewReplayOnly() async throws {
        let f = try await makeUIKitFixture(transport: CompositionTransport(unsent: true) {})
        var relaunched: CompositionUIKitFixture?
        do {
            try await waitUIKit("initial chunk is stored", diagnostics: { await f.captureDiagnostics() }) {
                try await f.queue.storedReplayChunks().count == 1
            }
            _ = await f.runtime.markBackgrounded(at: f.h.base.now)
            try await waitUIKit("background settles capture", diagnostics: { await f.captureDiagnostics() }) {
                guard !f.runtime.nativeReplayIsRecording() else { return false }
                return try await f.queue.nativeReplaySessionState().session?.activeEpoch == nil
            }
            let stored = try await f.queue.storedReplayChunks()
            let closed = await f.close(keepingStore: true); XCTAssertEqual(closed, .settled)
            f.h.base.testClock.advance(5)
            let updated = try EluVersionContext(runtime: .init(name: "elu-ios", version: "9.0.0"), facade: .init(name: "elu-ios", version: "9.0.0"))
            let next = try await makeUIKitFixture(relaunching: f.h, versions: updated); relaunched = next
            let oldIds = Set(stored.map(\.prepared.replayId))
            try await waitUIKit("stored chunks and the new recording reach delivery", diagnostics: { await next.captureDiagnostics() }) {
                let requests = try await next.transport.requests()
                return oldIds.isSubset(of: Set(requests.map(\.replayId))) && requests.contains { !oldIds.contains($0.replayId) }
            }
            let bodies = await next.transport.allBodies()
            for row in stored {
                XCTAssertTrue(bodies.contains(row.prepared.body), "stored chunk delivered with its exact bytes")
                XCTAssertNotEqual(try runtimeVersion(row.prepared.body), "9.0.0")
            }
            let fresh = try bodies.map { try EluV2ReplayPreparedRequest($0, captureProtocolGeneration: "replay-v2-1") }
                .filter { !oldIds.contains($0.replayId) }
            XCTAssertEqual(Set(fresh.map(\.replayId)).count, 1); XCTAssertEqual(fresh.first?.sequence, 0)
            XCTAssertEqual(fresh.first?.sessionId, stored.first?.prepared.sessionId)
            for request in fresh { XCTAssertEqual(try runtimeVersion(request.body), "9.0.0") }
            let result = await next.close(); XCTAssertEqual(result, .settled)
        } catch {
            if let relaunched { _ = await relaunched.close() }
            _ = await f.close(); throw error
        }
    }

    @MainActor func testLocalStopDoesNotPersistAcrossRelaunch() async throws {
        let f = try await makeUIKitFixture()
        var relaunched: CompositionUIKitFixture?
        do {
            try await waitUIKit("initial frame reaches delivery", diagnostics: { await f.captureDiagnostics() }) { await f.transport.count() == 1 }
            let first = try await f.transport.requests()[0]
            f.runtime.setNativeReplayRecordingEnabled(false)
            await f.composition.reevaluate()
            try await waitUIKit("local stop settles capture", diagnostics: { await f.captureDiagnostics() }) {
                guard !f.runtime.nativeReplayIsRecording() else { return false }
                return try await f.queue.nativeReplaySessionState().session?.activeEpoch == nil
            }
            let closed = await f.close(keepingStore: true); XCTAssertEqual(closed, .settled)
            f.h.base.testClock.advance(5)
            // No start call: the local stop belonged only to the ended runtime.
            let next = try await makeUIKitFixture(relaunching: f.h); relaunched = next
            try await waitUIKit("relaunched recording reaches delivery", diagnostics: { await next.captureDiagnostics() }) { await next.transport.count() >= 1 }
            let request = try await next.transport.requests()[0]
            XCTAssertNotEqual(request.replayId, first.replayId)
            XCTAssertEqual(request.sessionId, first.sessionId); XCTAssertEqual(request.sequence, 0)
            XCTAssertTrue(next.runtime.nativeReplayIsRecording())
            let result = await next.close(); XCTAssertEqual(result, .settled)
        } catch {
            if let relaunched { _ = await relaunched.close() }
            _ = await f.close(); throw error
        }
    }

    private func runtimeVersion(_ body: Data) throws -> String? {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let versions = (root["chunk"] as? [String: Any])?["versions"] as? [String: Any]
        return (versions?["runtime"] as? [String: Any])?["version"] as? String
    }

    /// `relaunching` opens a new runtime on that fixture's kept store, as the app does after it was ended.
    @MainActor private func makeUIKitFixture(fault: DeliveryFault? = nil,
                                             transport: CompositionTransport = CompositionTransport {},
                                             relaunching store: SealedPolicyTestHarness? = nil,
                                             versions: EluVersionContext? = nil) async throws -> CompositionUIKitFixture {
        let h: SealedPolicyTestHarness
        if let store { h = store } else {
            h = try await SealedPolicyTestHarness.make(seed: false, fault: fault)
            try h.changeConfig { root in
                var privacy = root["privacy"] as! [String: Any], replay = privacy["replay"] as! [String: Any]
                replay["sampleRate"] = 1; replay["minimumDurationSeconds"] = 0; replay["maximumDurationSeconds"] = 60
                privacy["replay"] = replay; root["privacy"] = privacy
            }
        }
        try h.publish()
        let window = try EluUIKitTestHost.window(), previous = window.rootViewController, controller = UIViewController()
        controller.view = UIView(frame: window.bounds); window.rootViewController = controller
        let runtime = try await open(h, versions: versions)
        guard case .accepted = await runtime.capture("continuity-anchor") else {
            await runtime.close(); window.rootViewController = previous
            throw EluRuntimeQueueError.invalidState
        }
        let queue = try XCTUnwrap(Mirror(reflecting: runtime).children.first { $0.label == "queue" }?.value as? EluSQLiteRuntimeQueue)
        let lifecycle = EluNativeReplayLifecycle(windowInventoryForTesting: EluUIKitTestHost.inventory(for: window))
        lifecycle.attached(UUID()); runtime.bindNativeLifecycle(lifecycle)
        let installed = await runtime.installNativeReplayComposition(lifecycle: lifecycle, capabilities: h.proof,
            deferredUntilActivation: true, transport: transport)
        let composition = try XCTUnwrap(installed)
        let fixture = CompositionUIKitFixture(h: h, runtime: runtime, queue: queue, lifecycle: lifecycle,
            composition: composition, transport: transport, window: window, previous: previous, controller: controller)
        do {
            // This hostless fixture supplies only its original real window. The
            // composition still selects/checks the key window and attached root.
            // Default UIApplication discovery is not covered by this fixture.
            window.windowLevel = .normal; window.alpha = 1
            window.makeKeyAndVisible()
            window.setNeedsLayout(); window.layoutIfNeeded(); controller.view.layoutIfNeeded()
            CATransaction.flush()
            try await waitUIKit("initial key window and attached controller become discoverable", diagnostics: {
                EluUIKitTestHost.readinessDiagnostics(window: window, controller: controller) +
                    ";lifecycleReadiness=\(lifecycle.observeRootReadiness())"
            }) {
                UIApplication.shared.applicationState == .active && window.isKeyWindow && !window.isHidden &&
                    window.alpha == 1 && window.windowLevel == .normal && window.rootViewController === controller &&
                    controller.viewIfLoaded?.window === window && lifecycle.observeRootReadiness() == .available
            }
            XCTAssertTrue(window.isKeyWindow); XCTAssertTrue(controller.viewIfLoaded?.window === window)
            XCTAssertEqual(UIApplication.shared.applicationState, .active)
            XCTAssertEqual(lifecycle.observeRootReadiness(), .available)
            await composition.activate()
            return fixture
        } catch { _ = await fixture.close(); throw error }
    }

    @MainActor private func waitUIKit(_ stage: String, diagnostics: (() async -> String)? = nil,
                                      _ predicate: () async throws -> Bool) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < 6_000_000_000 {
            if try await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let facts = await diagnostics?()
        throw CompositionUIKitWaitFailure(stage: stage, diagnostics: facts)
    }
    #endif

    private func open(_ h: SealedPolicyTestHarness, zone: CompositionZone = CompositionZone(),
                      versions: EluVersionContext? = nil) async throws -> EluStandaloneRuntime {
        await h.base.queue.close()
        let runtime = try await EluStandaloneRuntime.make(rootDirectoryURL: h.base.root,
            siteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", versions: versions, limits: h.base.limits,
            transport: CompositionEventTransport(), configurationGate: h.base.gate,
            clock: { h.base.now }, continuousClock: { h.base.testClock.ticks() },
            continuousBudgetConverter: { $0 }, nativeContinuousNanoseconds: { $0 },
            timeZoneIdentifier: { zone.read() }, flushDelayNanoseconds: 600_000_000_000, faultInjector: h.base.fault)
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
    /// Every send gets a non-retryable refusal, so each recording's head is held.
    private let refuse: Bool
    /// Every send ends without a response, so each chunk stays stored and pending.
    private let unsent: Bool
    private let entered: @Sendable () -> Void
    private var waiter: CheckedContinuation<Void, Never>?
    init(held: Bool = false, refuse: Bool = false, unsent: Bool = false, entered: @escaping @Sendable () -> Void) {
        self.held = held; self.refuse = refuse; self.unsent = unsent; self.entered = entered
    }
    func count() -> Int { bodies.count }
    func firstBody() -> Data? { bodies.first }
    func allBodies() -> [Data] { bodies }
    func requests() throws -> [EluV2ReplayPreparedRequest] {
        try bodies.map { try EluV2ReplayPreparedRequest($0, captureProtocolGeneration: "replay-v2-1") }
    }
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
        if refuse {
            entered(); return EluV1BatchHTTPResponse(status: 400, headers: [:], body: Data("{}".utf8))
        }
        if unsent { entered(); throw CancellationError() }
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

private final class ReplayLocalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var stopCount = 0
    func begin() { lock.lock(); active = true; lock.unlock() }
    func stop() { lock.lock(); active = false; stopCount += 1; lock.unlock() }
    func isRecording() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
    func stops() -> Int { lock.lock(); defer { lock.unlock() }; return stopCount }
}

#if canImport(UIKit)
private struct CompositionUIKitWaitFailure: Error, CustomStringConvertible {
    let stage: String
    let diagnostics: String?
    var description: String {
        "Timed out waiting for UIKit fixture phase: \(stage)" + (diagnostics.map { ";" + $0 } ?? "")
    }
}
@MainActor private final class CompositionUIKitFixture {
    let h: SealedPolicyTestHarness
    let runtime: EluStandaloneRuntime
    let queue: EluSQLiteRuntimeQueue
    let lifecycle: EluNativeReplayLifecycle
    let composition: EluNativeReplayComposition
    let transport: CompositionTransport
    let window: UIWindow
    let previous: UIViewController?
    let controller: UIViewController
    init(h: SealedPolicyTestHarness, runtime: EluStandaloneRuntime, queue: EluSQLiteRuntimeQueue,
         lifecycle: EluNativeReplayLifecycle, composition: EluNativeReplayComposition, transport: CompositionTransport,
         window: UIWindow, previous: UIViewController?, controller: UIViewController) {
        self.h = h; self.runtime = runtime; self.queue = queue; self.lifecycle = lifecycle
        self.composition = composition; self.transport = transport; self.window = window
        self.previous = previous; self.controller = controller
    }
    /// Failure-only observations of the original owners. No prepare/start,
    /// configuration publication, identity values, payloads or authority grant.
    func captureDiagnostics() async -> String {
        let phase: Int
        switch await runtime.currentPhase {
        case .awaitingConfiguration: phase = 0
        case .capturing: phase = 1
        case .blocked: phase = 2
        case .closed: phase = 3
        }
        let snapshot = try? await queue.snapshot()
        let ledger = try? await queue.nativeReplaySessionState()
        let inventory = try? await queue.replayInventory()
        let delivered = await transport.count()
        let session = ledger?.session
        return [
            "runtimePhase=\(phase)",
            "sourceCurrent=\(h.base.gate.isCurrent(h.base.witness))",
            "queueReadable=\(snapshot != nil)",
            "hasAnalyticsSession=\(snapshot?.identity.session != nil)",
            "optedOut=\(snapshot?.identity.optedOut == true)",
            "nativeLedgerReadable=\(ledger != nil)",
            "hasNativeSession=\(session != nil)",
            "sampleSelected=\(session?.originalSelected == true)",
            "hasFirstStart=\(session?.firstStartAt != nil)",
            "hasActiveEpoch=\(session?.activeEpoch != nil)",
            "clockDenied=\(session?.clockDenied == true)",
            "interrupted=\(session?.interrupted == true)",
            "remainingSeconds=\(session?.remainingWholeSeconds ?? -1)",
            "nextReplayOrdinal=\(ledger?.nextReplayOrdinal ?? -1)",
            "inventoryReadable=\(inventory != nil)",
            "sealedCount=\(inventory?.replayCount ?? -1)",
            "recording=\(runtime.nativeReplayIsRecording())",
            "transportCount=\(delivered)",
            "lifecycleReadiness=\(lifecycle.observeRootReadiness())"
        ].joined(separator: ";")
    }

    /// `keepingStore` leaves the store on disk for a relaunch on the same root.
    func close(keepingStore: Bool = false) async -> EluNativeReplayComposition.CloseOutcome {
        let outcome = await composition.closeAndWait()
        await runtime.close(); lifecycle.close(); window.rootViewController = previous
        if outcome == .settled, !keepingStore { h.base.remove() }
        return outcome
    }
}
private final class CompositionOnce: @unchecked Sendable {
    private let lock = NSLock(); private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
    func wasTaken() -> Bool { lock.lock(); defer { lock.unlock() }; return used }
}
#endif
