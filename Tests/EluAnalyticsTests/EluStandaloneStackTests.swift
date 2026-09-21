import Foundation
import XCTest
@testable import EluAnalytics

final class EluStandaloneStackTests: XCTestCase {
    func testStartupRemainsClosedUntilObservedForegroundAndCoalescesActivation() async throws {
        try await withHarness { h in
            h.stack.start()
            await h.stack.settled()
            let count = await h.config.count
            XCTAssertEqual(count, 0)
            h.stack.setForeground(true)
            h.stack.setForeground(true)
            try await eventually { await h.config.count == 1 }
            await h.config.resolve(try fixture())
            try await eventually { await h.stack.runtime.currentPhase == .capturing }
            let result = await h.stack.runtime.capture("owned")
            guard case .accepted = result else { return XCTFail("Expected capture: \(result)") }
            _ = await h.stack.runtime.flush()
            let sent = await h.events.count
            XCTAssertEqual(sent, 1)
        }
    }

    func testBackgroundImmediatelyFencesOldSourceAndRetainsPhysicalConfigSlot() async throws {
        try await withHarness { h in
            h.stack.start()
            h.stack.setForeground(true)
            try await eventually { await h.config.count == 1 }
            h.stack.setForeground(false)
            h.stack.setForeground(true)
            await h.stack.settled()
            let held = await h.config.count
            XCTAssertEqual(held, 1)
            await h.config.resolve(try fixture())
            try await eventually { await h.config.count == 2 }
            let rejected = await h.stack.runtime.capture("old")
            guard case .rejected = rejected else { return XCTFail("Late old source granted capture") }
            await h.config.resolve(try fixture())
            try await eventually { await h.stack.runtime.currentPhase == .capturing }
            _ = await h.stack.runtime.capture("lawful")
            h.stack.setForeground(false)
            _ = await h.stack.runtime.flush()
            let sends = await h.events.count
            XCTAssertEqual(sends, 0)
            let snapshot = try await h.stack.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.queuedCount, 1)
        }
    }

    func testSameIssuanceAfterBackgroundDrainsQueuedEventWithoutAnotherCaptureOrFlush() async throws {
        try await withHarness { h in
            let document = try fixture()
            try await h.install(document)
            let captured = await h.stack.runtime.capture("queued-before-background")
            guard case .accepted = captured else { return XCTFail("Expected a lawful queued event") }
            h.stack.setForeground(false)
            await h.stack.settled()
            // Let the original capture's one-shot timer finish while source
            // authority is unavailable. Foreground must not depend on it.
            try await Task.sleep(nanoseconds: EluStandaloneRuntime.defaultFlushDelayNanoseconds + 200_000_000)
            let suspended = try await h.stack.runtime.queueSnapshot()
            let sentWhileSuspended = await h.events.count
            XCTAssertEqual(suspended.queuedCount, 1)
            XCTAssertEqual(sentWhileSuspended, 0)

            h.stack.setForeground(true)
            try await eventually { await h.config.count == 2 }
            await h.stack.runtime.markForegrounded()
            // Foreground's early pass has no configuration yet.
            let earlyPass = await h.stack.runtime.flush()
            guard case .unavailable = earlyPass else { return XCTFail("Held refresh granted delivery") }
            await h.config.resolve(document)
            try await eventually { await h.stack.runtime.currentPhase == .capturing }
            await h.stack.settled()
            // No capture, explicit flush or new timer after config installation.
            try await eventually { await h.events.names == ["queued-before-background"] }
            try await eventually { try await h.stack.runtime.queueSnapshot().queuedCount == 0 }
        }
    }

    func testCaptureOffAllowsLocalIdentityContextAndIndependentFlagsWithoutWireBackfill() async throws {
        try await withHarness { h in
            try await h.install(try fixture(capture: false))
            let identity = await h.stack.runtime.identify("local-person", properties: ["tier": .string("pro")])
            XCTAssertEqual(identity?.identity.userId, "local-person")
            _ = await h.stack.runtime.group(type: "company", key: "example")
            _ = await h.stack.runtime.setFlagPersonProperties(["beta": .bool(true)])
            let projection = await h.stack.flags.reloadProjection()
            XCTAssertNotNil(projection)
            XCTAssertEqual(projection?.lookup("variant"), .found(value: .string(Array("local-person".utf16)), payload: nil))
            let snapshot = try await h.stack.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.queuedCount, 0)
            XCTAssertEqual(snapshot.identity.groups["company"], "example")
            XCTAssertEqual(snapshot.flagContext.personProperties["beta"], .bool(true))
            let capture = await h.stack.runtime.capture("blocked")
            guard case .rejected = capture else { return XCTFail("Capture-off admitted an event") }
        }
    }

    func testOriginalCacheProjectionExpiresAndSourceWithdrawalIsNonterminal() async throws {
        try await withHarness { h in
            try await h.install(try fixture())
            let loaded = await h.stack.flags.reloadProjection()
            let projection = try XCTUnwrap(loaded)
            XCTAssertTrue(projection.authority.isCurrent())
            await h.stack.flags.withdrawConfiguration()
            XCTAssertFalse(projection.authority.isCurrent())
            let withdrawnRead = await h.stack.flags.readProjection()
            let withdrawnReload = await h.stack.flags.reloadProjection()
            XCTAssertNil(withdrawnRead)
            XCTAssertNil(withdrawnReload)
            // Source is still live; explicit same-document channel recovery uses
            // the original source witness, not a new cache/source deadline.
            // A real source withdrawal changes the lifecycle state. An ordinary
            // identical refresh intentionally emits no replacement notification.
            h.stack.setForeground(false)
            await h.stack.settled()
            h.stack.setForeground(true)
            try await eventually { await h.config.count == 2 }
            await h.config.resolve(try fixture())
            try await eventually { await h.stack.runtime.currentPhase == .capturing }
            await h.stack.settled()
            let recovered = await h.stack.flags.reloadProjection()
            XCTAssertNotNil(recovered)
            h.clock.advance(151)
            let expired = await h.stack.flags.readProjection()
            XCTAssertNil(expired)
            XCTAssertFalse(projection.authority.isCurrent())
        }
    }

    func testFacadePendingIdentityImmediatelyClosesOldGetterAndDelayedNotification() async throws {
        try await withHarness { h in
            let notifications = StackNotifications()
            let context = EluRuntimeBackendContext(siteKey: StackHarness.siteKey,
                config: try TestConfigFactory.make(), configDocument: nil, isNewUser: true, flagsDidLoad: {})
            let facade = EluStandaloneFacadeRuntime(context: context, openStack: { h.stack },
                guardedFlagsDidLoad: { notifications.append($0) })
            await facade.settled()
            facade.setForeground(true)
            try await eventually { await h.config.count == 1 }
            await h.config.resolve(try fixture())
            try await eventually { await h.stack.runtime.currentPhase == .capturing }
            await h.stack.settled()
            facade.activate()
            await facade.settled()
            XCTAssertEqual(facade.featureFlag("variant") as? String, "anonymous")
            XCTAssertTrue(notifications.latest?() ?? false)
            facade.execute(.identify(distinctId: "next", userProperties: nil))
            XCTAssertNil(facade.featureFlag("variant"))
            XCTAssertFalse(notifications.latest?() ?? true)
            facade.execute(.setPersonPropertiesForFlags(["plan": "new"]))
            XCTAssertNil(facade.featureFlag("variant"))
            await facade.settled()
            await facade.settled()
            XCTAssertEqual(facade.featureFlag("variant") as? String, "next")
            facade.shutDown()
            XCTAssertNil(facade.featureFlag("variant"))
            XCTAssertFalse(notifications.latest?() ?? true)
            await facade.settled()
        }
    }

    func testSameDocumentAtLaterClockKeepsCaptureAndLawfulQueuedIdentity() async throws {
        try await withHarness { h in
            let data = try fixture()
            try await h.install(data)
            _ = await h.stack.runtime.capture("before")
            _ = await h.stack.runtime.resetIdentity()
            h.clock.advance(1)
            await h.stack.lifecycle.refresh()
            try await eventually { await h.config.count == 2 }
            await h.config.resolve(data)
            try await eventually { await h.stack.runtime.currentPhase == .capturing }
            await h.stack.settled()
            let captured = await h.stack.runtime.capture("after")
            guard case .accepted = captured else { return XCTFail("Same document terminalized: \(captured)") }
            _ = await h.stack.runtime.flush()
            let names = await h.events.names
            XCTAssertEqual(names, ["before", "after"])
        }
    }

    func testIdentityChangeDuringHeldDeliveryPreservesSealedEvent() async throws {
        try await withHarness { h in
            try await h.install(try fixture())
            _ = await h.stack.runtime.capture("sealed")
            await h.events.holdNext()
            let sending = Task { await h.stack.runtime.flush() }
            try await eventually { await h.events.isHeld }
            _ = await h.stack.runtime.resetIdentity()
            await h.events.release()
            _ = await sending.value
            let names = await h.events.names
            XCTAssertEqual(names, ["sealed"])
        }
    }

    func testSourceWithdrawalBetweenAsyncValidationAndFinalSendLeavesBytesQueued() async throws {
        try await withHarness { h in
            try await h.install(try fixture())
            _ = await h.stack.runtime.capture("sealed")
            await h.events.holdNext()
            let sending = Task { await h.stack.runtime.flush() }
            try await eventually { await h.events.isHeld }
            h.stack.setForeground(false)
            await h.events.release()
            _ = await sending.value
            let count = await h.events.count
            XCTAssertEqual(count, 0)
            let snapshot = try await h.stack.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.queuedCount, 1)
        }
    }

    func testFacadeRetainsForegroundIntentWhileStackOpenIsSuspended() async throws {
        try await withHarness { h in
            let opening = StackOpenBarrier()
            let context = EluRuntimeBackendContext(siteKey: StackHarness.siteKey,
                isNewUser: true, flagsDidLoad: {})
            let facade = EluStandaloneFacadeRuntime(context: context,
                openStack: { await opening.wait(); return h.stack }, guardedFlagsDidLoad: { _ in })
            facade.setForeground(true)
            await opening.release()
            await facade.settled()
            try await eventually { await h.config.count == 1 }
            facade.shutDown()
            await h.config.failAll()
            await facade.settled()
        }
    }

    func testLatestBackgroundDuringOpenKeepsStackClosedUntilNewForeground() async throws {
        try await withHarness { h in
            let opening = StackOpenBarrier()
            let context = EluRuntimeBackendContext(siteKey: StackHarness.siteKey,
                isNewUser: true, flagsDidLoad: {})
            let facade = EluStandaloneFacadeRuntime(context: context,
                openStack: { await opening.wait(); return h.stack }, guardedFlagsDidLoad: { _ in })
            facade.setForeground(true)
            facade.setForeground(false)
            await opening.release()
            await facade.settled()
            await h.stack.settled()
            let count = await h.config.count
            XCTAssertEqual(count, 0)
            facade.setForeground(true)
            try await eventually { await h.config.count == 1 }
            facade.shutDown()
            await h.config.failAll()
            await facade.settled()
        }
    }

    func testPreSetupDenialIsDurableBeforeFactoryReturnsOrConfigurationCanGrantCapture() async throws {
        try await withHarness { h in
            let handoff = StackPausedFactory()
            defer { handoff.release.signal() }
            let core = EluCore(backendFactory: EluRuntimeBackendFactory { _, context in
                let facade = EluStandaloneFacadeRuntime(context: context, openStack: { h.stack },
                    guardedFlagsDidLoad: context.guardedFlagsDidLoad)
                handoff.publish(facade)
                facade.setForeground(true)
                // The constructor has started its asynchronous work, but core
                // cannot deliver a later execute(.consent) until this returns.
                _ = handoff.release.wait(timeout: .now() + 10)
                return facade
            })
            core.setConsent(optedOut: false)
            core.setConsent(optedOut: true)
            core.setup(siteKey: StackHarness.siteKey, options: EluSetupOptions())
            try await eventually { handoff.facade != nil }
            let facade = try XCTUnwrap(handoff.facade)
            await facade.settled()
            try await eventually { await h.config.count == 1 }
            let beforeConfiguration = try await h.stack.runtime.queueSnapshot()
            XCTAssertTrue(beforeConfiguration.identity.optedOut,
                "The denial must reach durable storage before configuration begins, not after the factory returns")
            await h.config.resolve(try fixture())
            await h.stack.settled()
            let result = await h.stack.runtime.capture("constructor-window")
            guard case .rejected = result else {
                handoff.release.signal()
                facade.shutDown(); await facade.settled()
                return XCTFail("Configuration granted capture before pending consent was handed over")
            }
            _ = await h.stack.runtime.flush()
            let sends = await h.events.count
            XCTAssertEqual(sends, 0)
            handoff.release.signal()
            _ = core.backendForTesting()
            await facade.settled()
            XCTAssertTrue(core.isOptedOut())
            facade.shutDown(); await facade.settled()
            await h.close()
            let reopened = try await StackHarness(root: h.root)
            let restored = try await reopened.stack.runtime.queueSnapshot()
            XCTAssertTrue(restored.identity.optedOut)
            await reopened.close()
        }
    }

    func testLatestConsentWhileOpenIsHeldPersistsBeforeStartupAndSurvivesReset() async throws {
        try await withHarness { h in
            let gate = StackOpenGate()
            let core = EluCore(backendFactory: EluRuntimeBackendFactory { _, context in
                EluStandaloneFacadeRuntime(context: context, openStack: {
                    await gate.wait()
                    return h.stack
                }, guardedFlagsDidLoad: context.guardedFlagsDidLoad)
            })
            core.setConsent(optedOut: false, event: "obsolete-opt-in")
            core.setup(siteKey: StackHarness.siteKey, options: EluSetupOptions())
            let facade = try XCTUnwrap(core.backendForTesting() as? EluStandaloneFacadeRuntime)
            try await eventually { await gate.isWaiting }
            core.setConsent(optedOut: true)
            _ = core.bufferDropCountForTesting()
            facade.setForeground(true)
            await gate.release()
            await facade.settled()
            let saved = try await h.stack.runtime.queueSnapshot()
            XCTAssertTrue(saved.identity.optedOut)
            XCTAssertEqual(saved.queuedCount, 0)
            try await eventually { await h.config.count == 1 }
            await h.config.resolve(try fixture())
            try await eventually { core.distinctId() != nil }
            core.reset()
            _ = core.bufferDropCountForTesting()
            await facade.settled()
            let reset = try await h.stack.runtime.queueSnapshot()
            XCTAssertTrue(reset.identity.optedOut)
            XCTAssertEqual(reset.queuedCount, 0)
            facade.shutDown(); await facade.settled()
            await h.close()
            let reopened = try await StackHarness(root: h.root)
            let restored = try await reopened.stack.runtime.queueSnapshot()
            XCTAssertTrue(restored.identity.optedOut)
            await reopened.close()
        }
    }

    func testLatestPreSetupGrantClearsSavedDenialBeforeStartupWithoutBackfilledOptIn() async throws {
        try await withHarness { h in
            let old = UUID()
            h.stack.runtime.acceptConsentIntent(old, optedOut: true)
            _ = await h.stack.runtime.setOptedOut(true, intent: old)
            let core = EluCore(backendFactory: EluRuntimeBackendFactory { _, context in
                EluStandaloneFacadeRuntime(context: context, openStack: { h.stack },
                    guardedFlagsDidLoad: context.guardedFlagsDidLoad)
            })
            core.setConsent(optedOut: true)
            core.setConsent(optedOut: false, event: "early-opt-in")
            core.setup(siteKey: StackHarness.siteKey, options: EluSetupOptions())
            let facade = try XCTUnwrap(core.backendForTesting() as? EluStandaloneFacadeRuntime)
            await facade.settled()
            let saved = try await h.stack.runtime.queueSnapshot()
            XCTAssertFalse(saved.identity.optedOut)
            XCTAssertEqual(saved.queuedCount, 0, "The opt-in event is a normal attempt, not a config-deferred event")
            facade.setForeground(true)
            try await eventually { await h.config.count == 1 }
            await h.config.resolve(try fixture())
            try await eventually { core.distinctId() != nil }
            core.dispatch(.capture(event: "allowed", properties: nil))
            _ = core.bufferDropCountForTesting()
            await facade.settled()
            _ = await h.stack.runtime.flush()
            let names = await h.events.names
            XCTAssertEqual(names, ["allowed"])
            facade.shutDown(); await facade.settled()
            await h.close()
            let reopened = try await StackHarness(root: h.root)
            let restored = try await reopened.stack.runtime.queueSnapshot()
            XCTAssertFalse(restored.identity.optedOut)
            await reopened.close()
        }
    }

    func testCoreOwnedBootstrapPropagatesHostAndPreservesInitialCallOrder() async throws {
        try await withHarness { h in
            let selectedHost = URL(string: "https://www.elu.dev")!
            let core = EluCore(backendFactory: EluRuntimeBackendFactory { selection, context in
                XCTAssertEqual(selection, .standalone)
                XCTAssertEqual(context.configHost, selectedHost)
                XCTAssertNil(context.config)
                XCTAssertNil(context.configDocument)
                return EluStandaloneFacadeRuntime(context: context, openStack: { h.stack },
                    guardedFlagsDidLoad: context.guardedFlagsDidLoad)
            })
            var options = EluSetupOptions(configHost: selectedHost)
            options.runtimeSelection = .standalone
            core.setup(siteKey: StackHarness.siteKey, options: options)
            core.dispatch(.capture(event: "first", properties: nil))
            core.dispatch(.identify(distinctId: "buffered", userProperties: nil))
            core.dispatch(.capture(event: "identified", properties: nil))
            core.reset()
            core.dispatch(.capture(event: "last", properties: nil))
            let facade = try XCTUnwrap(core.backendForTesting() as? EluStandaloneFacadeRuntime)
            XCTAssertNil(core.distinctId())
            facade.setForeground(true)
            try await eventually { await h.config.count == 1 }
            await h.config.resolve(try fixture())
            try await eventually { core.distinctId() != nil }
            await facade.settled()
            core.flush()
            _ = core.bufferDropCountForTesting()
            await facade.settled()
            let names = await h.events.names
            XCTAssertEqual(names, ["first", "identified", "last"])
            let snapshot = try await h.stack.runtime.queueSnapshot()
            XCTAssertNil(snapshot.identity.userId)
            facade.shutDown()
            await facade.settled()
        }
    }

    func testCoreCallbackMutationFencesFollowingCallbackBeforeCoreQueueHop() async throws {
        try await withHarness { h in
            let (core, facade) = try await runningCore(h)
            let first = expectation(description: "first callback")
            let second = expectation(description: "stale callback")
            second.isInverted = true
            // Late registrations retain their original projection, and execute
            // on main. The first callback accepts a mutation synchronously;
            // the second must reject that old projection before queued work.
            await MainActor.run {
                core.onFeatureFlagsLoaded {
                    core.dispatch(.register(["tier": "changed"]))
                    first.fulfill()
                }
                core.onFeatureFlagsLoaded { second.fulfill() }
                _ = core.bufferDropCountForTesting()
            }
            await fulfillment(of: [first, second], timeout: 0.1)
            facade.shutDown()
            await facade.settled()
        }
    }

    func testLateCallbackRetainsOriginalExpiryRatherThanRereadingNewClockLease() async throws {
        try await withHarness { h in
            let (core, facade) = try await runningCore(h)
            let callback = expectation(description: "expired late callback")
            callback.isInverted = true
            await MainActor.run {
                core.onFeatureFlagsLoaded { callback.fulfill() }
                _ = core.bufferDropCountForTesting()
                h.clock.advance(151)
            }
            await fulfillment(of: [callback], timeout: 0.1)
            facade.shutDown()
            await facade.settled()
        }
    }

    private func runningCore(_ h: StackHarness) async throws -> (EluCore, EluStandaloneFacadeRuntime) {
        let core = EluCore(backendFactory: EluRuntimeBackendFactory { _, context in
            EluStandaloneFacadeRuntime(context: context, openStack: { h.stack },
                guardedFlagsDidLoad: context.guardedFlagsDidLoad)
        })
        var options = EluSetupOptions()
        options.runtimeSelection = .standalone
        core.setup(siteKey: StackHarness.siteKey, options: options)
        let facade = try XCTUnwrap(core.backendForTesting() as? EluStandaloneFacadeRuntime)
        facade.setForeground(true)
        try await eventually { await h.config.count == 1 }
        await h.config.resolve(try fixture())
        try await eventually { core.distinctId() != nil }
        await facade.settled()
        XCTAssertEqual(core.getFeatureFlag("variant") as? String, "anonymous")
        return (core, facade)
    }

    private func withHarness(_ body: (StackHarness) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("elu-stack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await StackHarness(root: root)
        do { try await body(h) } catch { await h.close(); throw error }
        await h.close()
    }
}

private func fixture(capture: Bool = true) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Conformance/V2/fixtures/config-enabled.json"))) as! [String: Any]
    var features = value["features"] as! [String: Any]
    features["capture"] = capture
    value["features"] = features
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func eventually(file: StaticString = #filePath, line: UInt = #line, _ predicate: () async throws -> Bool) async throws {
    for _ in 0 ..< 500 {
        if try await predicate() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTFail("Timed out waiting for bounded mock operation", file: file, line: line)
}

private struct StackHarness: Sendable {
    static let siteKey = "elu_pk_test_" + String(repeating: "a", count: 22)
    let stack: EluStandaloneStack
    let root: URL
    let config = StackConfigTransport()
    let events = StackEventTransport()
    let clock = StackClock()
    init(root: URL) async throws {
        self.root = root
        stack = try await EluStandaloneStack.make(rootDirectoryURL: root, siteKey: Self.siteKey,
            configHost: URL(string: "https://elu.dev")!, configTransport: config,
            eventTransport: events, flagTransport: StackFlagTransport(), clock: clock.source,
            scheduler: StackScheduler(), timeZoneIdentifier: { "America/New_York" })
    }
    func install(_ data: Data) async throws {
        stack.start()
        stack.setForeground(true)
        try await eventually { await config.count == 1 }
        await config.resolve(data)
        try await eventually { await stack.flags.readAll().isAllowedForStackTest }
        await stack.settled()
    }
    func close() async {
        stack.close()
        await config.failAll()
        await stack.settled()
    }
}

private extension EluV1FlagCacheReadResult {
    var isAllowedForStackTest: Bool {
        switch self { case .miss, .hit: return true; default: return false }
    }
}

private actor StackConfigTransport: EluV2ConfigTransport {
    private(set) var count = 0
    private var pending: [CheckedContinuation<Data, Error>] = []
    func fetch(_ request: EluV2ConfigRequest) async throws -> Data {
        count += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resolve(_ data: Data) { if !pending.isEmpty { pending.removeFirst().resume(returning: data) } }
    func failAll() { let old = pending; pending = []; old.forEach { $0.resume(throwing: CancellationError()) } }
}

private actor StackEventTransport: EluV1AuthorizedBatchTransport {
    private(set) var count = 0
    private(set) var names: [String] = []
    private let delegate = FacadeBatchTransport()
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    var isHeld: Bool { held != nil }
    func holdNext() { shouldHold = true }
    func release() { held?.resume(); held = nil }
    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse {
        throw EluV1BoundTransportError.staleAuthority
    }
    func send(_ request: EluV1BatchHTTPRequest, authority: EluV1TransportAuthority) async throws -> EluV1BatchHTTPResponse {
        guard await authority.revalidate() else { throw EluV1BoundTransportError.staleAuthority }
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { held = $0 }
        }
        guard authority.isCurrent() else { throw EluV1BoundTransportError.staleAuthority }
        count += 1
        let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
        names += (body["records"] as! [[String: Any]]).compactMap { ($0["event"] as? [String: Any])?["name"] as? String }
        return try await delegate.send(request)
    }
}

private struct StackFlagTransport: EluV1AuthorizedFlagTransport {
    func send(endpoint: URL, requestBody: Data) async throws -> Data { throw EluV1BoundTransportError.staleAuthority }
    func send(endpoint: URL, requestBody: Data, authority: EluV1TransportAuthority) async throws -> Data {
        guard await authority.revalidate(), authority.isCurrent() else { throw EluV1BoundTransportError.staleAuthority }
        let request = try JSONSerialization.jsonObject(with: requestBody) as! [String: Any]
        let identity = request["identity"] as! [String: Any]
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "requestId": request["requestId"]!, "contextRevision": request["contextRevision"]!,
            "identityRevision": identity["revision"]!, "flagsRevision": "stack-1",
            "evaluatedAt": "2026-08-05T00:01:31.000Z", "expiresAt": "2026-08-05T00:04:00.000Z",
            "flags": ["variant": identity["userId"] as? String ?? "anonymous"], "payloads": [:]
        ], options: [.sortedKeys])
    }
}

private struct StackScheduler: EluV2ConfigLifecycleScheduler {
    func schedule(afterNanoseconds: UInt64, action: @escaping @Sendable () async -> Void) -> any EluV2ConfigScheduledTask { StackTimer() }
}
private struct StackTimer: EluV2ConfigScheduledTask { func cancel() {} }

private final class StackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: UInt64 = 0
    private let start = Date(timeIntervalSince1970: 1_785_888_090)
    var source: EluV2ConfigClock {
        EluV2ConfigClock(wallNow: { [self] in lock.lock(); defer { lock.unlock() }; return start.addingTimeInterval(Double(elapsed) / 1_000_000_000) },
            continuousNow: { [self] in lock.lock(); defer { lock.unlock() }; return 1_000_000_000 + elapsed },
            floorTicks: { $0 }, floorNanoseconds: { $0 })
    }
    func advance(_ seconds: UInt64) { lock.lock(); elapsed += seconds * 1_000_000_000; lock.unlock() }
}

private final class StackNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [@Sendable () -> Bool] = []
    func append(_ value: @escaping @Sendable () -> Bool) { lock.lock(); values.append(value); lock.unlock() }
    var latest: (@Sendable () -> Bool)? { lock.lock(); defer { lock.unlock() }; return values.last }
}

private actor StackOpenBarrier {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private final class StackPausedFactory: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: EluStandaloneFacadeRuntime?
    func publish(_ facade: EluStandaloneFacadeRuntime) {
        lock.lock(); defer { lock.unlock() }; value = facade
    }
    var facade: EluStandaloneFacadeRuntime? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

private actor StackOpenGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
