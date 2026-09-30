#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit
import XCTest
@testable import EluAnalytics

@MainActor
final class EluNativeRasterDeliveryTests: XCTestCase {
    func testExplicitSelectionUsesOriginalStoredRequestAndExactEndpointWithoutCaptureRenewal() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        let request = try h.request(); _ = try await h.append(request); await h.stop()
        let original = try await h.queue.storedReplayRecords()
        let oldOnly = try await h.permission(.wireframeOnly)
        if let oldOnly {
            guard case .idle = try await h.queue.claimNextReplay(oldOnly) else { return XCTFail("default routed raster") }
        }
        let claim = try await h.claim()
        XCTAssertEqual(claim.format, .raster); XCTAssertEqual(claim.row, original[0])
        let value = try await h.queue.enrollReplayDispatch(claim, dispatchAllowed: { true })
        let dispatch = try XCTUnwrap(value), use = try XCTUnwrap(dispatch.takePhysicalUse())
        XCTAssertEqual(use.format, .raster)
        XCTAssertEqual(use.request.url.absoluteString, "https://ingest.elu.dev/v3/replay")
        XCTAssertEqual(use.request.body, request.body)
        XCTAssertEqual(use.request.headers["Authorization"], "Bearer elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")
        let current = await use.revalidate(); XCTAssertTrue(current); XCTAssertTrue(use.beginOnce())
        XCTAssertNil(dispatch.takePhysicalUse()); use.settle()
        guard case let .raster(row) = claim.row else { return XCTFail("original raster") }
        let response = try Self.ack(row.prepared)
        let outcome = EluNativeRasterResponse.classify(response, request: row.prepared, now: h.native.base.now)
        XCTAssertEqual(outcome, .accepted)
        _ = try await h.queue.finishReplayClaim(claim, completion: .rasterResponse(outcome))
        let remaining = try await h.queue.storedReplayRecords(); XCTAssertTrue(remaining.isEmpty)
        await h.close()
    }

    func testLostAckRenewalAndReopenRetryOriginalBytesBeforeSuffix() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        let first = try h.request(); _ = try await h.append(first)
        h.native.base.testClock.advance(1); let second = try h.request(); _ = try await h.append(second)
        await h.stop()
        let claim = try await h.claim(); XCTAssertEqual(claim.row.body, first.body)
        _ = try await h.queue.finishReplayClaim(claim, completion: .networkFailure)
        await h.close(); try await h.native.reopen(); try await h.publish(branch: true, advance: true)
        let value = try await h.permission(), current = try XCTUnwrap(value)
        guard case .deferred = try await h.queue.claimNextReplay(current) else { return XCTFail("restart shortened retry") }
        h.native.base.testClock.advance(1)
        let retry = try await h.claim(current); XCTAssertEqual(retry.row.body, first.body); XCTAssertEqual(retry.attemptCount, 2)
        _ = try await h.queue.finishReplayClaim(retry, completion: .rasterResponse(.accepted))
        let next = try await h.claim(current); XCTAssertEqual(next.row.body, second.body); XCTAssertEqual(next.row.sequence, 1)
        _ = try await h.queue.finishReplayClaim(next, completion: .released)
        await h.queue.close()
    }

    func testActualURLSessionUsesOnlyOriginalRasterEndpointAndClassifiesOriginalAck() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request()); await h.stop()
        let claim = try await h.claim()
        guard case let .raster(row) = claim.row else { return XCTFail("raster") }
        let response = try Self.ack(row.prepared)
        ReplayTransportURLProtocol.hooks.set { request, client, instance in
            XCTAssertEqual(request.url?.absoluteString, "https://ingest.elu.dev/v3/replay")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")
            XCTAssertFalse(request.httpShouldHandleCookies)
            client.urlProtocol(instance, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(instance, didLoad: response.body); client.urlProtocolDidFinishLoading(instance)
        }
        let value = try await h.queue.enrollReplayDispatch(claim, dispatchAllowed: { true }), dispatch = try XCTUnwrap(value)
        let transport = EluV2URLSessionReplayTransport(protocolClasses: [ReplayTransportURLProtocol.self])
        let actual = try await transport.send(dispatch)
        let outcome = EluNativeRasterResponse.classify(actual, request: row.prepared, now: h.native.base.now)
        XCTAssertEqual(outcome, .accepted)
        _ = try await h.queue.finishReplayClaim(claim, completion: .rasterResponse(outcome))
        let remaining = try await h.queue.storedReplayRecords(); XCTAssertTrue(remaining.isEmpty)
        await h.close()
    }

    func testMissingBranchAndChangedEffectivePolicyRetainButDoNotAuthorizeOldBytes() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request()); await h.stop()
        let rows = try await h.queue.storedReplayRecords()
        let originalConfig = h.native.base.config
        try await h.publish(branch: false, advance: true)
        if let permission = try await h.permission() {
            guard case .idle = try await h.queue.claimNextReplay(permission) else { return XCTFail("missing branch granted raster") }
        }
        var changed = try JSONSerialization.jsonObject(with: originalConfig) as! [String: Any]
        changed["replayAudience"] = "new-devices"
        h.native.base.config = try JSONSerialization.data(withJSONObject: changed)
        try await h.publish(branch: true, advance: true)
        let changedValue = try await h.permission(), changedPermission = try XCTUnwrap(changedValue)
        guard case .idle = try await h.queue.claimNextReplay(changedPermission) else { return XCTFail("changed policy rebound original bytes") }
        let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, rows)
        h.native.base.config = originalConfig; try await h.publish(branch: true, advance: true)
        let restored = try await h.claim(); XCTAssertEqual(restored.row, rows[0])
        _ = try await h.queue.finishReplayClaim(restored, completion: .released)
        await h.close()
    }

    func testExactConflictAndSizeRefusalPermanentlyBlockOriginalEpochIncludingAppendAndReopen() async throws {
        for reason in ["request", "chunk", "sequence", "too-large"] {
            let h = try await Rig.make(); defer { h.remove() }
            _ = try await h.append(h.request()); h.native.base.testClock.advance(1)
            _ = try await h.append(h.request()); h.native.base.testClock.advance(1)
            let notYetAppended = try h.request()
            let rows = try await h.queue.storedReplayRecords(), claim = try await h.claim()
            guard case let .raster(row) = claim.row else { return XCTFail("raster") }
            let response = try Self.refusal(row.prepared, reason: reason)
            let outcome = EluNativeRasterResponse.classify(response, request: row.prepared, now: h.native.base.now)
            _ = try await h.queue.finishReplayClaim(claim, completion: .rasterResponse(outcome))
            do { _ = try await h.append(notYetAppended); XCTFail("blocked epoch appended") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, .nativeRasterEpochBlocked(replayId: row.prepared.replayId, reason: reason)) }
            let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, rows)
            let metadata = try h.native.bytes("SELECT metadata FROM replay_delivery WHERE ordinal=0")
            XCTAssertEqual(try EluV2ReplayDeliveryState.decode(metadata).rasterBlock?.reason, reason)
            await h.close(); try await h.native.reopen(); try await h.publish(branch: true, advance: true)
            let value = try await h.permission(), authority = try XCTUnwrap(value)
            guard case .idle = try await h.queue.claimNextReplay(authority) else { return XCTFail("renewal revived permanent block") }
            XCTAssertEqual(try h.native.bytes("SELECT metadata FROM replay_delivery WHERE ordinal=0"), metadata)
            let reopened = try await h.queue.storedReplayRecords(); XCTAssertEqual(reopened, rows)
            await h.queue.close()
        }
    }

    func testCredentialRefusalRenewalUnlatchesOnlyNewLawfulEpoch() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request()); h.native.base.testClock.advance(1); _ = try await h.append(h.request())
        let rows = try await h.queue.storedReplayRecords()
        let transport = RasterDeliveryTransport { request, index in
            if index == 0 { return .init(status: 401, headers: [:], body: Data()) }
            return try Self.ack(EluNativeRasterStoredRequest(restoring: request.body))
        }
        let clock = h.native.base.testClock
        let coordinator = EluV2ReplayDeliveryCoordinator(queue: h.queue, transport: transport, wallNow: { clock.read() })
        let permissionValue = try await h.permission(), permission = try XCTUnwrap(permissionValue)
        let first = await coordinator.trigger(permission); XCTAssertEqual(first.blocked, 1)
        let latched = await coordinator.trigger(permission); XCTAssertEqual(latched.attempted, 0); XCTAssertEqual(latched.stopped, .withdrawn)
        h.native.base.testClock.advance(1); let rejected = try h.request()
        do { _ = try await h.append(rejected); XCTFail("refused prefix accepted suffix") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .nativeRasterEpochBlocked(replayId: rejected.replayId, reason: "credential-401")) }
        await h.stop(); try await h.publish(branch: true, advance: true); try await h.start()
        let fresh = try h.request(); XCTAssertNotEqual(fresh.replayId, rejected.replayId); _ = try await h.append(fresh)
        let renewedValue = try await h.permission(), renewed = try XCTUnwrap(renewedValue)
        let recovered = await coordinator.trigger(renewed); XCTAssertEqual(recovered.accepted, 1); XCTAssertEqual(recovered.attempted, 1)
        let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, rows)
        let sent = await transport.bodies; XCTAssertEqual(sent, [rows[0].body, fresh.body])
        _ = await coordinator.closeAndWait(); await h.close()
    }

    func testCoordinatorRetains413AndExact409ButNeverPromotesForgedConflictScope() async throws {
        for reason in ["too-large", "request", "forged"] {
            let h = try await Rig.make(); defer { h.remove() }
            let request = try h.request(); _ = try await h.append(request)
            h.native.base.testClock.advance(1); _ = try await h.append(h.request()); await h.stop()
            let original = try await h.queue.storedReplayRecords()
            let response: EluV1BatchHTTPResponse
            if reason == "forged" { response = .init(status: 409, headers: [:], body: Data("{}".utf8)) }
            else { response = try Self.refusal(EluNativeRasterStoredRequest(restoring: request.body), reason: reason) }
            let transport = RasterDeliveryTransport { _, _ in response }, clock = h.native.base.testClock
            let coordinator = EluV2ReplayDeliveryCoordinator(queue: h.queue, transport: transport, wallNow: { clock.read() })
            let value = try await h.permission(), authority = try XCTUnwrap(value)
            let summary = await coordinator.trigger(authority)
            XCTAssertEqual(summary.attempted, 1); XCTAssertEqual(summary.blocked, 1); XCTAssertEqual(summary.discardedTooLarge, 0)
            let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, original)
            let metadata = try EluV2ReplayDeliveryState.decode(h.native.bytes("SELECT metadata FROM replay_delivery WHERE ordinal=0"))
            if reason == "forged" { XCTAssertNil(metadata.rasterBlock); XCTAssertEqual(metadata.blocked?.reason, "protocol") }
            else { XCTAssertEqual(metadata.rasterBlock?.reason, reason); XCTAssertNil(metadata.blocked) }
            _ = await coordinator.closeAndWait(); await h.close()
        }
    }

    func testStaleSourceAckCannotDeleteButOriginalRefusalStillPersists() async throws {
        for refusal in [false, true] {
            let h = try await Rig.make(); defer { h.remove() }
            _ = try await h.append(h.request()); await h.stop()
            let rows = try await h.queue.storedReplayRecords(), claim = try await h.claim()
            try await h.publish(branch: true, advance: true)
            XCTAssertFalse(claim.isCurrent())
            let saved = try await h.queue.finishReplayClaim(claim,
                completion: .rasterResponse(refusal ? .identityConflict(scope: .request) : .accepted))
            XCTAssertEqual(saved, refusal)
            let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, rows)
            if refusal {
                let value = try await h.permission(), current = try XCTUnwrap(value)
                guard case .idle = try await h.queue.claimNextReplay(current) else { return XCTFail("late original conflict lost") }
            } else { let next = try await h.claim(); _ = try await h.queue.finishReplayClaim(next, completion: .released) }
            await h.close()
        }
    }

    func testRasterCooldownCannotBecomeWireframeCooldownAndPersistsAcrossRestart() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request()); await h.stop()
        let claim = try await h.claim()
        _ = try await h.queue.finishReplayClaim(claim, completion: .rasterResponse(.endpointCooldown(seconds: 10)))
        let bytes = try h.native.bytes("SELECT metadata FROM replay_delivery WHERE ordinal=-1")
        let metadata = try EluV2ReplayDeliveryState.decode(bytes)
        XCTAssertNil(metadata.endpointRetry(for: .wireframe)); XCTAssertEqual(metadata.endpointRetry(for: .raster)?.delayMillis, 10_000)
        // A change in only the other endpoint cannot erase raster's cooldown.
        var base = try JSONSerialization.jsonObject(with: h.native.base.config) as! [String: Any]
        var endpoints = base["endpoints"] as! [String: Any]
        endpoints["replay"] = "https://ingest.elu.dev/v2/replay?variant=2"; base["endpoints"] = endpoints
        h.native.base.config = try JSONSerialization.data(withJSONObject: base)
        try await h.publish(branch: true, advance: true)
        let renewedValue = try await h.permission(), renewed = try XCTUnwrap(renewedValue)
        guard case .deferred = try await h.queue.claimNextReplay(renewed) else { return XCTFail("other endpoint changed raster cooldown") }
        h.native.base.testClock.advance(9); await h.close(); try await h.native.reopen()
        let value = try await h.permission(), authority = try XCTUnwrap(value)
        guard case .deferred = try await h.queue.claimNextReplay(authority) else { return XCTFail("cooldown lost on restart") }
        h.native.base.testClock.advance(9)
        guard case .deferred = try await h.queue.claimNextReplay(authority) else { return XCTFail("cooldown shortened") }
        h.native.base.testClock.advance(1)
        let retry = try await h.claim(authority); XCTAssertEqual(retry.row, claim.row)
        _ = try await h.queue.finishReplayClaim(retry, completion: .released); await h.queue.close()
    }

    func testLegacyMetadataBytesAndBothClosedEndpointCooldownsRemainIndependent() throws {
        let pending = Data("{\"attemptCount\":0,\"schemaVersion\":1}".utf8)
        XCTAssertEqual(try EluV2ReplayDeliveryState.pending.encoded(), pending)
        let old = EluV2ReplayDeliveryState.Retry(recordedAt: "2026-08-05T00:01:00Z", delayMillis: 5_000,
            ownerEpoch: UUID().uuidString, authorizationWitness: "sha256:" + String(repeating: "a", count: 64))
        let raster = EluV2ReplayDeliveryState.Retry(recordedAt: old.recordedAt, delayMillis: 7_000,
            ownerEpoch: old.ownerEpoch, authorizationWitness: "sha256:" + String(repeating: "b", count: 64))
        var metadata = EluV2ReplayDeliveryState.pending
        metadata.setEndpointRetry(old, for: .wireframe)
        let legacy = try metadata.encoded(); XCTAssertEqual(metadata.schemaVersion, 1)
        XCTAssertEqual(try EluV2ReplayDeliveryState.decode(legacy).encoded(), legacy)
        metadata.setEndpointRetry(raster, for: .raster)
        let current = try EluV2ReplayDeliveryState.decode(metadata.encoded())
        XCTAssertEqual(current.endpointRetry(for: .wireframe), old); XCTAssertEqual(current.endpointRetry(for: .raster), raster)
        metadata.setEndpointRetry(raster, for: .wireframe)
        XCTAssertEqual(metadata.endpointRetry(for: .raster), raster)
        for bad in ["{\"schemaVersion\":1,\"attemptCount\":0,\"endpointRetries\":{}}",
                    "{\"schemaVersion\":2,\"attemptCount\":0,\"endpointRetries\":{\"unknown\":{}}}",
                    "{\"schemaVersion\":2,\"attemptCount\":0}"] {
            XCTAssertThrowsError(try EluV2ReplayDeliveryState.decode(Data(bad.utf8)))
        }
    }

    func testOriginalCoordinatorDispatchesOtherEndpointWhileFirstEndpointCoolsDown() async throws {
        let h = try await Rig.make(seedReplay: true); defer { h.remove() }
        _ = try await h.append(h.request()); await h.stop()
        let before = try await h.queue.storedReplayRecords(); XCTAssertEqual(before.count, 2)
        let transport = RasterDeliveryTransport { request, index in
            if index < 2 {
                return .init(status: 429, headers: ["Retry-After": request.url.path == "/v2/replay" ? "10" : "2"],
                    body: try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "status": 429,
                        "code": "rate-limited", "message": "fixture", "disposition": "retryable"]))
            }
            return try Self.ack(EluNativeRasterStoredRequest(restoring: request.body))
        }
        let clock = h.native.base.testClock
        let coordinator = EluV2ReplayDeliveryCoordinator(queue: h.queue, transport: transport, wallNow: { clock.read() },
            sleep: { _ in throw CancellationError() })
        let value = try await h.permission(), authority = try XCTUnwrap(value)
        let first = await coordinator.trigger(authority)
        XCTAssertEqual(first.attempted, 2); XCTAssertEqual(first.retried, 2); XCTAssertEqual(first.stopped, .deferred)
        let metadata = try EluV2ReplayDeliveryState.decode(h.native.bytes("SELECT metadata FROM replay_delivery WHERE ordinal=-1"))
        XCTAssertEqual(metadata.endpointRetry(for: .wireframe)?.delayMillis, 10_000)
        XCTAssertEqual(metadata.endpointRetry(for: .raster)?.delayMillis, 2_000)
        clock.advance(2)
        let second = await coordinator.trigger(authority); XCTAssertEqual(second.accepted, 1); XCTAssertEqual(second.stopped, .deferred)
        let remaining = try await h.queue.storedReplayRecords(); XCTAssertEqual(remaining, [before[0]])
        let sent = await transport.bodies; XCTAssertEqual(sent, [before[0].body, before[1].body, before[1].body])
        _ = await coordinator.closeAndWait(); await h.close()
    }

    func testFailedOriginalRasterReceiptKeepsQuarantineAfterPhysicalSettlement() async throws {
        for point in [EluRuntimeQueueFaultPoint.beforeCommit, .afterCommit] {
            let fault = DeliveryFault(), h = try await Rig.make(fault: fault); defer { h.remove() }
            _ = try await h.append(h.request()); await h.stop()
            let claim = try await h.claim(), value = try await h.queue.enrollReplayDispatch(claim, dispatchAllowed: { true })
            let dispatch = try XCTUnwrap(value), use = try XCTUnwrap(dispatch.takePhysicalUse())
            XCTAssertTrue(use.beginOnce())
            fault.action = { actual in if actual == point { throw EluRuntimeQueueError.faultInjected(actual) } }
            do { _ = try await h.queue.finishReplayClaim(claim, completion: .rasterResponse(.identityConflict(scope: .sequence))); XCTFail("failed receipt released") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, point == .beforeCommit ? .provenNotCommitted : .ambiguousCommit) }
            fault.action = nil; use.settle(); await h.queue.close()
            do { let next = try await h.native.base.reopen(); await next.close(); XCTFail("quarantined original lease replaced") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
        }
    }

    func testUnknownDeliveryMetadataRefusesBeforeChangingDatabaseOrSidecars() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request()); await h.close()
        let invalid = Data("{\"attemptCount\":0,\"schemaVersion\":3}".utf8)
        try h.native.base.sql("UPDATE replay_delivery SET metadata=X'\(invalid.map { String(format: "%02x", $0) }.joined())' WHERE ordinal=-1")
        let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")
        let database = h.native.base.root.appendingPathComponent(namespace).appendingPathComponent("runtime-state-v1.sqlite3")
        func files() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for suffix in ["", "-wal", "-shm"] {
                let path = database.path + suffix
                if FileManager.default.fileExists(atPath: path) { result[suffix] = try Data(contentsOf: URL(fileURLWithPath: path)) }
            }
            return result
        }
        let before = try files()
        do { try await h.native.reopen(); XCTFail("unknown metadata opened") } catch {}
        XCTAssertEqual(try files(), before)
        // Actual current-opener refusal. Old schema1-only decoder/preflight is
        // retained as separate source evidence, not an executed historical binary.
    }

    func testWholeEpochExpiryNeverDispatchesYoungerSuffixThroughEitherReconciler() async throws {
        for reconcile in [false, true] {
            let h = try await Rig.make(); defer { h.remove() }
            _ = try await h.append(h.request()); h.native.base.testClock.advance(1); _ = try await h.append(h.request()); await h.stop()
            h.native.base.testClock.advance(604_799)
            if reconcile { try await h.publish(branch: true, advance: true); _ = try await h.permission() }
            else {
                let count = try await h.queue.expireReplay(expectedConfigWitness: h.native.base.configWitness)
                XCTAssertEqual(count, 2)
            }
            let rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
            XCTAssertEqual(try h.native.integer("SELECT count(*) FROM replay_delivery WHERE ordinal>=0"), 0)
            await h.close()
        }
    }

    func testPendingIdentityIntentRevokesOriginalDispatchWithoutReplacingSealedIdentity() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request()); await h.stop()
        let original = try await h.queue.storedReplayRecords(), claim = try await h.claim()
        let enrolled = try await h.queue.enrollReplayDispatch(claim, dispatchAllowed: { true })
        let dispatch = try XCTUnwrap(enrolled), use = try XCTUnwrap(dispatch.takePhysicalUse())
        let intent = h.queue.beginFlagProjectionIntent()
        let valid = await use.revalidate(); XCTAssertFalse(valid); XCTAssertFalse(use.beginOnce())
        h.queue.finishFlagProjectionIntent(intent); use.settle()
        let accepted = try await h.queue.finishReplayClaim(claim, completion: .rasterResponse(.accepted)); XCTAssertFalse(accepted)
        let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, original)
        await h.close()
    }

    func testOriginalPhysicalAndReceiptBarriersRetainLeaseAfterLogicalClose() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request()); await h.stop()
        let claim = try await h.claim(), value = try await h.queue.enrollReplayDispatch(claim, dispatchAllowed: { true })
        let dispatch = try XCTUnwrap(value), use = try XCTUnwrap(dispatch.takePhysicalUse())
        let valid = await use.revalidate(); XCTAssertTrue(valid); XCTAssertTrue(use.beginOnce())
        await h.queue.close()
        do { let next = try await h.native.base.reopen(); await next.close(); XCTFail("physical lease released") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
        use.settle()
        do { let next = try await h.native.base.reopen(); await next.close(); XCTFail("receipt lease released") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
        _ = try await h.queue.finishReplayClaim(claim, completion: .rasterResponse(.identityConflict(scope: .chunk)))
        try await h.native.reopen()
        let value2 = try await h.permission(), permission = try XCTUnwrap(value2)
        guard case .idle = try await h.queue.claimNextReplay(permission) else { return XCTFail("closed refusal lost") }
        await h.queue.close()
    }

    private nonisolated static func ack(_ request: EluNativeRasterStoredRequest) throws -> EluV1BatchHTTPResponse {
        .init(status: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 3, "requestId": request.requestId, "replayId": request.replayId,
            "chunkId": request.chunkId, "sequence": request.sequence, "result": "accepted"]))
    }
    private static func refusal(_ request: EluNativeRasterStoredRequest, reason: String) throws -> EluV1BatchHTTPResponse {
        if reason == "too-large" {
            return .init(status: 413, headers: [:], body: try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "requestId": request.requestId, "status": 413,
                "code": "payload-too-large", "disposition": "retry-after-reduction", "message": "fixture"]))
        }
        return .init(status: 409, headers: [:], body: try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 3, "requestId": request.requestId, "status": 409,
            "code": "replay-identity-conflict", "disposition": "permanent", "conflictScope": reason]))
    }

    // Actual collector/sealer/admission and SQLite ownership, with controlled
    // drawing/clock only to isolate delivery. No rendering deadline qualification.
    @MainActor private final class Rig {
        let native: NativeSessionHarness
        let window: UIWindow, previous: UIViewController?, root: UIView
        let registry = EluSwiftUIReplayRegistry(requiredRegions: [])
        let marker: EluSwiftUIReplayMarkerView
        let lifecycle = EluNativeReplayLifecycle()
        let owner: EluNativeReplayAuthority
        var enrollment: EluNativeReplayCaptureEnrollment?
        var use: EluNativeReplayCapturePhysicalUse!
        var permit: EluNativeRasterPermit!
        var admission: EluNativeRasterCaptureAdmission!
        var sealerValue: EluNativeRasterSealer?
        var queue: EluSQLiteRuntimeQueue { native.queue }
        var timestamp: Int64 { get throws { try EluV1Timestamp.exactClock(native.base.now).floorUnixMilliseconds } }
        init(_ native: NativeSessionHarness) throws {
            self.native = native
            owner = EluNativeReplayAuthority(queue: native.queue, clock: { native.base.now })
            window = try EluUIKitTestHost.window(); previous = window.rootViewController
            let controller = UIViewController(); window.rootViewController = controller; controller.loadViewIfNeeded()
            root = controller.view; root.frame = window.bounds
            marker = EluSwiftUIReplayMarkerView(region: nil, registry: registry)
            marker.frame = CGRect(x: 0, y: 0, width: 32, height: 32); root.addSubview(marker)
            window.makeKeyAndVisible(); window.layoutIfNeeded(); CATransaction.flush()
            lifecycle.attached(UUID())
        }
        static func make(fault: DeliveryFault? = nil, start: Bool = true, seedReplay: Bool = false) async throws -> Rig {
            let native: NativeSessionHarness
            if seedReplay {
                let wireframe = try await SealedPolicyTestHarness.make(clearSession: false, fault: fault, tuple: .v2)
                native = NativeSessionHarness(wireframe.base)
                try await native.update(rate: 1, cap: 60)
                try await native.queue.ensureNativeReplayAuthoritySchema()
            } else { native = try await NativeSessionHarness.make(fault: fault) }
            let h = try Rig(native)
            try await h.publish(branch: true, advance: true)
            if start { try await h.start() }
            return h
        }
        func start() async throws {
            let selection = try XCTUnwrap(lifecycle.select(root: root, window: window))
            let prepared = try await owner.prepareRaster(source: XCTUnwrap(native.base.witness),
                sourceIdentity: registry.sourceIdentity(), timeZoneIdentifier: "America/Los_Angeles")
            enrollment = try await queue.enrollNativeReplayCapture()
            use = try XCTUnwrap(enrollment?.takePhysicalUse())
            let started = try await owner.startRaster(prepared, selection: selection, physicalUse: use)
            permit = try XCTUnwrap(started)
            admission = try await owner.captureAdmission(for: permit, physicalUse: use)
            sealerValue = try sealer()
        }
        func permission(_ support: EluReplayDeliverySupport = .includingRaster) async throws -> EluV2ReplayDeliveryAuthority? {
            try await queue.currentSealedReplayDelivery(source: XCTUnwrap(native.base.witness),
                capabilities: .init(readbackProvenTransports: Set(EluNativeReplayProtocol.allCases.map(\.transport)),
                    readbackProvenProtocolGenerations: Set(EluNativeReplayProtocol.allCases.map(\.generation))),
                timeZoneIdentifier: "America/Los_Angeles", support: support)
        }
        func claim(_ permission: EluV2ReplayDeliveryAuthority? = nil) async throws -> EluV2ReplayClaim {
            let authority: EluV2ReplayDeliveryAuthority
            if let permission { authority = permission } else { let value = try await self.permission(); authority = try XCTUnwrap(value) }
            guard case let .claimed(value) = try await queue.claimNextReplay(authority) else { throw EluRuntimeQueueError.invalidState }
            return value
        }
        func publish(branch: Bool, advance: Bool, installCapture: Bool = true) async throws {
            var base = try JSONSerialization.jsonObject(with: native.base.config) as! [String: Any]
            if advance { native.base.testClock.advance(0.001); base["issuedAt"] = EluRFC3339.string(from: native.base.now); base["expiresAt"] = EluRFC3339.string(from: native.base.now.addingTimeInterval(300)) }
            let bytes = try JSONSerialization.data(withJSONObject: base)
            let parsed = try EluNativeV3ConfigParser.parse(branch ? nativeV3SourceRasterFixture(base: bytes) : nativeV3SourceEnvelope(bytes))
            try publishReceipt(parsed)
            guard installCapture else { return }
            guard case .activated = try await applyCapture(parsed.configV2Data) else { throw EluRuntimeQueueError.invalidState }
        }
        func publishPlainV2(_ data: Data) async throws -> EluV1CaptureAuthorityUpdateResult {
            let document = try EluV1ConfigManager.prepareConfig(data, endpointPolicy: .cloud).document
            let token = EluV2ConfigLifecycleToken()
            native.base.gate.publish(token: token, lease: EluV2ConfigLease(data: data,
                expiresAt: document.expiresAt, continuousDeadline: native.base.testClock.ticks() + 600_000_000_000))
            native.base.witness = try XCTUnwrap(native.base.gate.witness(for: token)); native.base.config = data
            return try await applyCapture(data)
        }
        func applyCapture(_ data: Data) async throws -> EluV1CaptureAuthorityUpdateResult {
            let manager = EluV1ConfigManager(); _ = try manager.update(configData: data, now: native.base.now)
            let snapshot = try await queue.snapshot()
            let input = EluPrivacyProjectionInput(contextRevision: snapshot.identity.contextRevision, identityOptedOut: snapshot.identity.optedOut,
                timeZoneIdentifier: "America/Los_Angeles", evaluatedAt: native.base.now,
                appliedMasking: EluPrivacyMaskingCapability(text: .all, inputs: .all, images: .block),
                replaySampleDraw: 0, replaySessionEligible: false, replayBudgetRemainingSeconds: 0, localReplayTransports: [])
            let projection = try EluPrivacyStateProjector.project(context: manager.activePrivacyProjectionContext(now: native.base.now), input: input)
            return await queue.submitCaptureAuthority(configData: data,
                effectivePrivacyStateData: projection.stateData, sourceWitness: native.base.witness)
        }
        func publishReceipt(_ parsed: EluNativeV3ConfigParser.Parsed) throws {
            let token = EluV2ConfigLifecycleToken()
            native.base.gate.publish(token: token, lease: EluV2ConfigLease(data: parsed.configV2Data,
                expiresAt: parsed.base.expiresAt, continuousDeadline: native.base.testClock.ticks() + 600_000_000_000, nativeV3: parsed))
            native.base.witness = try XCTUnwrap(native.base.gate.witness(for: token)); native.base.config = parsed.configV2Data
        }
        func sealer(sourceIdentity: EluSwiftUIReplaySourceIdentity? = nil) throws -> EluNativeRasterSealer {
            let original = admission!
            return try EluNativeRasterSealer(replayId: permit.replayId, identity: permit.identity, policy: permit.sealingPolicy(),
                versions: .init(runtime: .init(name: "elu-ios", version: "1.0.0"), facade: .init(name: "EluAnalytics", version: "1.0.0")),
                sourceIdentity: sourceIdentity ?? registry.sourceIdentity(), sourceIsCurrent: { original.isCurrent() })
        }
        func request() throws -> EluNativeRasterPreparedRequest {
            var value = try XCTUnwrap(sealerValue)
            let request = try value.seal(registry.capture(deadline: 1, clock: { 0 }, draw: { _, _, context in
                context.setFillColor(UIColor.green.cgColor); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32)); return true
            }), timestamp: timestamp)
            sealerValue = value
            return request
        }
        func append(_ request: EluNativeRasterPreparedRequest) async throws -> EluNativeRasterCaptureAppendResult {
            try await queue.appendNativeRaster(request, admission: admission, physicalUse: use)
        }
        func stop() async {
            use?.settle(); try? await owner.stop()
            if let enrollment { _ = try? await queue.finishNativeReplayCapture(enrollment) }
            enrollment = nil
        }
        func close() async { await stop(); await owner.close(); await queue.close() }
        func remove() { window.rootViewController = previous; native.base.remove() }
    }
}

private actor RasterDeliveryTransport: EluV2ReplayHTTPTransport {
    private let response: @Sendable (EluV1BatchHTTPRequest, Int) throws -> EluV1BatchHTTPResponse
    private(set) var bodies: [Data] = []
    init(_ response: @escaping @Sendable (EluV1BatchHTTPRequest, Int) throws -> EluV1BatchHTTPResponse) { self.response = response }
    func send(_ dispatch: EluV2ReplayDispatch) async throws -> EluV1BatchHTTPResponse {
        guard let use = dispatch.takePhysicalUse() else { throw EluV1BoundTransportError.occupied }
        defer { use.settle() }
        guard await use.revalidate(), use.beginOnce() else { throw EluV1BoundTransportError.staleAuthority }
        let index = bodies.count; bodies.append(use.request.body)
        return try response(use.request, index)
    }
}
#endif
