import Foundation
import XCTest
@testable import EluAnalytics

final class EluV2ConfigSourceTests: XCTestCase {
    private let key = "elu_pk_live_" + String(repeating: "a", count: 22)

    func testRequestUsesOnlyCanonicalKeyAndExactApprovedHTTPSOrigin() throws {
        let request = try EluV2ConfigRequest(siteKey: key, configHost: URL(string: "https://ELU.dev:443/")!)
        XCTAssertEqual(request.url.absoluteString, "https://elu.dev/sdk/v2/\(key)/config")
        for invalid in ["", " \(key)", "\(key)\n", "\(key)/x", "elu_pk_live_short", "\(key)?site_key=x"] {
            XCTAssertThrowsError(try EluV2ConfigRequest(siteKey: invalid, configHost: URL(string: "https://elu.dev")!))
        }
        for host in ["http://elu.dev", "https://elu.dev.evil.test", "https://elu.dev/path", "https://elu.dev?q=1", "https://user@elu.dev", "https://elu.dev:444", "https://elu.dev/#x"] {
            XCTAssertThrowsError(try EluV2ConfigRequest(siteKey: key, configHost: URL(string: host)!))
        }
    }

    func testLoopbackRequestAndSourceFollowCompiledPublicPolicy() async throws {
        for origin in ["http://127.0.0.1:8765", "http://localhost:8765", "https://localhost"] {
            let url = URL(string: origin)!
            #if DEBUG
                XCTAssertTrue(EluConfigHostAllowlist.loopbackPermitted)
                let request = try EluV2ConfigRequest(siteKey: key, configHost: url)
                XCTAssertEqual(request.url.absoluteString, "\(origin)/sdk/v2/\(key)/config")
                let transport = EluV2ControlledTransport()
                let clock = EluV2TestClock()
                let source = try EluV2ConfigSource(siteKey: key, configHost: url,
                                                 transport: transport, clock: clock.clock)
                let document = try fixture()
                let result = await refresh(source, transport, data: document)
                XCTAssertEqual(result, .document(document))
                let dataPlaneLoopback = try fixture { object in
                    var endpoints = object["endpoints"] as! [String: Any]
                    endpoints["events"] = "http://127.0.0.1:8765/v1/events"
                    object["endpoints"] = endpoints
                }
                let rejected = await refresh(source, transport, data: dataPlaneLoopback)
                XCTAssertEqual(rejected, .unavailable)
                await source.close()
            #else
                XCTAssertFalse(EluConfigHostAllowlist.loopbackPermitted)
                XCTAssertThrowsError(try EluV2ConfigRequest(siteKey: key, configHost: url))
                XCTAssertThrowsError(try EluV2ConfigSource(siteKey: key, configHost: url))
            #endif
        }
        for invalid in ["http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://localhost/path", "http://localhost?q=x", "http://user@localhost"] {
            XCTAssertThrowsError(try EluV2ConfigRequest(siteKey: key, configHost: URL(string: invalid)!))
        }
    }

    func testFreshV2DocumentAndExactWallExpiry() async throws {
        let (source, transport, clock) = try makeSource()
        let data = try fixture()
        let result = await refresh(source, transport, data: data)
        XCTAssertEqual(result, .document(data))
        let active = await source.currentDocument()
        XCTAssertEqual(active, data)
        clock.set(wall: 1_785_888_300, continuous: 1)
        let expired = await source.currentDocument()
        XCTAssertNil(expired)
    }

    func testFailureWithdrawsButIdenticalDocumentCanRecoverWithinOriginalLease() async throws {
        let (source, transport, _) = try makeSource()
        let data = try fixture()
        _ = await refresh(source, transport, data: data)
        let failure = await refresh(source, transport, result: .failure(URLError(.notConnectedToInternet)))
        XCTAssertEqual(failure, .unavailable)
        let withdrawn = await source.currentDocument()
        XCTAssertNil(withdrawn)
        let restored = await refresh(source, transport, data: data)
        XCTAssertEqual(restored, .document(data))
    }

    func testIdenticalRefreshNeverExtendsContinuousLeaseEvenAfterWithdrawal() async throws {
        let (source, transport, clock) = try makeSource()
        let data = try fixture()
        _ = await refresh(source, transport, data: data)
        clock.set(wall: 1_785_888_090, continuous: 200_000_000_001)
        _ = await refresh(source, transport, data: data)
        _ = await refresh(source, transport, result: .failure(URLError(.timedOut)))
        clock.set(wall: 1_785_888_090, continuous: 210_000_000_001)
        let result = await refresh(source, transport, data: data)
        XCTAssertEqual(result, .unavailable)
        let expired = await source.currentDocument()
        XCTAssertNil(expired)
    }

    func testLiveLeaseRemainsDuringRenewalAndOlderResponseDoesNotRenewIt() async throws {
        let (source, transport, clock) = try makeSource()
        let data = try fixture { $0["issuedAt"] = "2026-08-05T00:01:00.000Z" }
        _ = await refresh(source, transport, data: data)
        let pending = Task { await source.refresh() }
        await transport.waitForRequests(2)
        let live = await source.currentDocument()
        XCTAssertEqual(live, data)
        await transport.resolve(1, with: .success(try fixture()))
        let result = await pending.value
        XCTAssertEqual(result, .document(data))
        clock.set(wall: 1_785_888_090, continuous: 210_000_000_001)
        let expired = await source.currentDocument()
        XCTAssertNil(expired)
    }

    func testRevokedAndDisabledRawDocumentsCannotBeReplacedByOlderEnabledData() async throws {
        for status in ["revoked", "disabled"] {
            let (source, transport, _) = try makeSource()
            let inactive = try inactiveFixture(status: status)
            let applied = await refresh(source, transport, data: inactive)
            XCTAssertEqual(applied, .document(inactive))
            _ = await refresh(source, transport, result: .failure(URLError(.timedOut)))
            let old = await refresh(source, transport, data: try fixture())
            XCTAssertEqual(old, .unavailable)
            let raw = await source.currentDocument()
            XCTAssertNil(raw)
        }
    }

    func testSameIssuedAtConflictStaysRestrictiveAfterOriginalReturns() async throws {
        let (source, transport, _) = try makeSource()
        let original = try fixture()
        _ = await refresh(source, transport, data: original)
        let conflict = try fixture { $0["revision"] = "conflicting" }
        let rejected = await refresh(source, transport, data: conflict)
        XCTAssertEqual(rejected, .unavailable)
        let stillRejected = await refresh(source, transport, data: original)
        XCTAssertEqual(stillRejected, .unavailable)
    }

    func testMalformedOversizedV1FutureAndOverlongDocumentsWithdraw() async throws {
        let invalid = [
            Data("{\"schemaVersion\":2,\"schemaVersion\":2}".utf8),
            Data(repeating: 32, count: 65_537),
            try fixture { $0["schemaVersion"] = 1 },
            try fixture { $0["issuedAt"] = "2026-08-05T00:01:30.0000000000000001Z" },
            try fixture { $0["expiresAt"] = "2026-08-05T00:10:00.0000000000000001Z" },
            try fixture { $0["expiresAt"] = "2026-08-05T00:00:00.000Z" },
            try fixture { object in
                var endpoints = object["endpoints"] as! [String: Any]
                endpoints["events"] = "https://evil.test/v1/events"
                object["endpoints"] = endpoints
            },
        ]
        for data in invalid {
            let (source, transport, _) = try makeSource()
            _ = await refresh(source, transport, data: try fixture())
            let result = await refresh(source, transport, data: data)
            XCTAssertEqual(result, .unavailable)
            let raw = await source.currentDocument()
            XCTAssertNil(raw)
        }
    }

    func testTimeSpentFetchingConsumesLeaseWhenWallClockStalls() async throws {
        let (source, transport, clock) = try makeSource()
        let pending = Task { await source.refresh() }
        await transport.waitForRequests(1)
        clock.set(wall: 1_785_888_090, continuous: 5_000_000_001)
        await transport.resolve(0, with: .success(try fixture()))
        let applied = await pending.value
        XCTAssertEqual(applied, .document(try fixture()))
        clock.set(wall: 1_785_888_090, continuous: 210_000_000_001)
        let expired = await source.currentDocument()
        XCTAssertNil(expired)
    }

    func testExactMaximumTTLIsAccepted() async throws {
        let (source, transport, _) = try makeSource()
        let data = try fixture { $0["expiresAt"] = "2026-08-05T00:10:00.000Z" }
        let result = await refresh(source, transport, data: data)
        XCTAssertEqual(result, .document(data))
    }

    func testExpiredNewerDocumentEstablishesBoundaryAgainstOlderLiveConfig() async throws {
        let (source, transport, _) = try makeSource()
        let expired = try fixture {
            $0["issuedAt"] = "2026-08-05T00:00:30.000Z"
            $0["expiresAt"] = "2026-08-05T00:01:00.000Z"
        }
        let result = await refresh(source, transport, data: expired)
        XCTAssertEqual(result, .unavailable)
        let older = await refresh(source, transport, data: try fixture())
        XCTAssertEqual(older, .unavailable)
    }

    func testClockRollbackAndInvalidClockFailClosedPermanently() async throws {
        for wall in [1_785_888_089.0, Double.nan, Double.infinity] {
            let (source, transport, clock) = try makeSource()
            _ = await refresh(source, transport, data: try fixture())
            clock.set(wall: wall, continuous: 2)
            let invalid = await source.currentDocument()
            XCTAssertNil(invalid)
            clock.set(wall: 1_785_888_090, continuous: 3)
            let blocked = await source.refresh()
            XCTAssertEqual(blocked, .unavailable)
        }
        let (source, transport, clock) = try makeSource()
        _ = await refresh(source, transport, data: try fixture())
        clock.set(wall: 1_785_888_090, continuous: 0)
        let backwards = await source.currentDocument()
        XCTAssertNil(backwards)
    }

    func testSupersededCompletionCannotWithdrawOrReplaceNewerDecision() async throws {
        let (source, transport, _) = try makeSource()
        let oldTask = Task { await source.refresh() }
        await transport.waitForRequests(1)
        let newTask = Task { await source.refresh() }
        await transport.waitForRequests(2)
        let revoked = try inactiveFixture(status: "revoked")
        await transport.resolve(1, with: .success(revoked))
        let newResult = await newTask.value
        XCTAssertEqual(newResult, .document(revoked))
        await transport.resolve(0, with: .success(try fixture()))
        let oldResult = await oldTask.value
        XCTAssertEqual(oldResult, .superseded)
        let raw = await source.currentDocument()
        XCTAssertEqual(raw, revoked)
    }

    func testCloseAndCallerCancellationFenceTransportIgnoringCancellation() async throws {
        for close in [false, true] {
            let (source, transport, _) = try makeSource()
            let pending = Task { await source.refresh() }
            await transport.waitForRequests(1)
            if close { await source.close() } else { pending.cancel() }
            await transport.resolve(0, with: .success(try fixture()))
            let result = await pending.value
            XCTAssertEqual(result, close ? .superseded : .unavailable)
            let raw = await source.currentDocument()
            XCTAssertNil(raw)
            if close {
                let terminal = await source.refresh()
                XCTAssertEqual(terminal, .unavailable)
            }
        }
    }

    func testLeaseSnapshotCarriesOriginalContinuousDeadlineAndWithdrawalPreservesIt() async throws {
        let (source, transport, clock) = try makeSource()
        let data = try fixture()
        _ = await refresh(source, transport, data: data)
        let original = await source.currentLease()
        XCTAssertEqual(original?.data, data)
        XCTAssertEqual(original?.expiresAt.source, "2026-08-05T00:05:00.000Z")
        XCTAssertEqual(original?.continuousDeadline, 210_000_000_001)
        await source.withdraw()
        let withdrawn = await source.currentLease()
        XCTAssertNil(withdrawn)
        clock.set(wall: 1_785_888_090, continuous: 100_000_000_001)
        _ = await refresh(source, transport, data: data)
        let recovered = await source.currentLease()
        XCTAssertEqual(recovered?.continuousDeadline, original?.continuousDeadline)
        clock.set(wall: 1_785_888_090, continuous: 210_000_000_001)
        await source.withdraw()
        let spent = await refresh(source, transport, data: data)
        XCTAssertEqual(spent, .unavailable)
    }

    func testWithdrawalFencesPendingCompletionWithoutClosingSource() async throws {
        let (source, transport, _) = try makeSource()
        let pending = Task { await source.refresh() }
        await transport.waitForRequests(1)
        await source.withdraw()
        await transport.resolve(0, with: .success(try fixture()))
        let old = await pending.value
        XCTAssertEqual(old, .superseded)
        let raw = await source.currentDocument()
        XCTAssertNil(raw)
        let restored = await refresh(source, transport, data: try fixture())
        XCTAssertEqual(restored, .document(try fixture()))
    }

    func testWithdrawalRetainsRevocationBoundary() async throws {
        let (source, transport, _) = try makeSource()
        _ = await refresh(source, transport, data: try inactiveFixture(status: "revoked"))
        await source.withdraw()
        let old = await refresh(source, transport, data: try fixture())
        XCTAssertEqual(old, .unavailable)
    }

    func testNativeV3UsesOneExplicitURLAndNeverFallsBackAfterFailureOrWrongSchema() async throws {
        let request = try EluV2ConfigRequest(siteKey: key, configHost: URL(string: "https://elu.dev")!, format: .nativeV3)
        XCTAssertEqual(request.url.absoluteString, "https://elu.dev/sdk/v3/\(key)/config")
        for format in [EluV2ConfigRequest.Format.v2, .nativeV3] {
            let (source, transport, _) = try makeSource(format: format)
            let base = try fixture(), wrapper = nativeV3SourceEnvelope(base)
            let wrong = format == .v2 ? wrapper : base
            let result = await refresh(source, transport, data: wrong)
            XCTAssertEqual(result, .unavailable)
            let count = await transport.count
            XCTAssertEqual(count, 1, "An incompatible response cannot start a second version fetch")
            let failure = await refresh(source, transport, result: .failure(URLError(.badServerResponse)))
            XCTAssertEqual(failure, .unavailable)
            let urls = await transport.urls
            XCTAssertEqual(urls.count, 2)
            XCTAssertTrue(urls.allSatisfy { $0.path.contains(format == .v2 ? "/sdk/v2/" : "/sdk/v3/") })
            await source.close()
        }
    }

    func testNativeV3RetainsOneReceiptAndExactEmbeddedBaseForOriginalChannelManager() async throws {
        let (source, transport, _) = try makeSource(format: .nativeV3)
        let bytes = try nativeV3SourceRasterFixture(base: fixture())
        let parsed = try EluNativeV3ConfigParser.parse(bytes)
        let result = await refresh(source, transport, data: bytes)
        XCTAssertEqual(result, .document(parsed.configV2Data))
        let retained = await source.currentLease()
        let lease = try XCTUnwrap(retained)
        XCTAssertEqual(lease.data, parsed.configV2Data)
        XCTAssertEqual(lease.receiptData, bytes)
        XCTAssertEqual(lease.nativeV3?.raster?.effectivePolicyHash, parsed.raster?.effectivePolicyHash)
        XCTAssertNotNil(lease.nativeV3?.raster)
        let original = try EluV1ConfigManager.prepareConfig(lease.data, endpointPolicy: .cloud)
        XCTAssertEqual(original.semanticHash, parsed.baseSemanticHash)
        XCTAssertEqual(original.policySourceHash, parsed.basePrivacyHash)
        XCTAssertThrowsError(try EluV1ConfigManager.prepareConfig(bytes, endpointPolicy: .cloud))
        await source.close()
    }

    func testNativeV3OuterSpellingChangesDoNotExtendOriginalLeaseAfterWithdrawal() async throws {
        let (source, transport, clock) = try makeSource(format: .nativeV3)
        let base = try fixture(), first = nativeV3SourceEnvelope(base)
        let second = Data(" \n".utf8) + first + Data("\t ".utf8)
        _ = await refresh(source, transport, data: first)
        let original = await source.currentLease()
        await source.withdraw()
        clock.set(wall: 1_785_888_090, continuous: 100_000_000_001)
        let refreshed = await refresh(source, transport, data: second)
        XCTAssertEqual(refreshed, .document(base))
        let current = await source.currentLease()
        XCTAssertEqual(current?.receiptData, second)
        XCTAssertEqual(current?.nativeV3?.data, second)
        XCTAssertEqual(current?.continuousDeadline, original?.continuousDeadline)
        clock.set(wall: 1_785_888_090, continuous: 210_000_000_001)
        let spent = await refresh(source, transport, data: first)
        XCTAssertEqual(spent, .unavailable)
        await source.close()
    }

    func testNativeV3EmbeddedValueBytesSurviveUnicodeWhitespaceAndNumericSpelling() async throws {
        let (source, transport, _) = try makeSource(format: .nativeV3)
        let base = Data("""
        { "schemaVersion" : 2e0, "revision" : "r-λ",\
         "issuedAt" : "2026-08-05T00:00:00Z", "expiresAt" : "2026-08-05T00:05:00Z",\
         "status" : "disabled", "reason" : "合成" }
        """.utf8)
        let envelope = nativeV3SourceEnvelope(base)
        let result = await refresh(source, transport, data: envelope)
        XCTAssertEqual(result, .document(base))
        let lease = await source.currentLease()
        XCTAssertEqual(lease?.data, base)
        XCTAssertEqual(lease?.nativeV3?.configV2Data, base)
        XCTAssertEqual(lease?.receiptData, envelope)
        let canonicalBase = try EluV1StrictCanonicalJSON.parse(base).canonicalData
        XCTAssertNotEqual(base, canonicalBase)
        let semanticRefresh = await refresh(source, transport, data: nativeV3SourceEnvelope(canonicalBase))
        XCTAssertEqual(semanticRefresh, .document(canonicalBase))
        let refreshed = await source.currentLease()
        XCTAssertEqual(refreshed?.continuousDeadline, lease?.continuousDeadline)
        await source.close()
    }

    func testNativeV3SameIssuanceBranchConflictStaysPoisonedAndOnlyNewerBaseCanRecover() async throws {
        for positiveFirst in [true, false] {
            let (source, transport, _) = try makeSource(format: .nativeV3)
            let positive = try nativeV3SourceRasterFixture(base: fixture())
            let parsed = try EluNativeV3ConfigParser.parse(positive)
            let absent = nativeV3SourceEnvelope(parsed.configV2Data)
            let first = positiveFirst ? positive : absent, changed = positiveFirst ? absent : positive
            _ = await refresh(source, transport, data: first)
            let conflict = await refresh(source, transport, data: changed)
            XCTAssertEqual(conflict, .unavailable)
            await source.withdraw()
            let originalAgain = await refresh(source, transport, data: first)
            XCTAssertEqual(originalAgain, .unavailable)
            let lease = await source.currentLease(); XCTAssertNil(lease)
            let newer = try fixture { $0["issuedAt"] = "2026-08-05T00:01:00.000Z" }
            let recovered = await refresh(source, transport, data: nativeV3SourceEnvelope(newer))
            XCTAssertEqual(recovered, .document(newer))
            let next = await source.currentLease(); XCTAssertNil(next?.nativeV3?.raster)
            let old = await refresh(source, transport, data: positive)
            XCTAssertEqual(old, .document(newer), "Old raster cannot replace the newer branch removal")
            let retainedNewer = await source.currentLease()
            XCTAssertEqual(retainedNewer?.receiptData, nativeV3SourceEnvelope(newer))
            await source.close()
        }
    }

    func testActualConflictReceiptIsBoundedRetainedAndOnlyNewerConflictReplacesIt() async throws {
        let (source, transport, _) = try makeSource(format: .nativeV3)
        let positive = try nativeV3SourceRasterFixture(base: fixture())
        let parsed = try EluNativeV3ConfigParser.parse(positive)
        _ = await refresh(source, transport, data: positive)
        _ = await refresh(source, transport, data: Data(" \n".utf8) + positive)
        XCTAssertNil(source.denials.pending(), "Equivalent spelling is not a conflict")
        _ = await refresh(source, transport, data: nativeV3SourceEnvelope(parsed.configV2Data))
        let first = try XCTUnwrap(source.denials.pending())
        XCTAssertEqual(first.issuedAt, parsed.base.issuedAt)
        XCTAssertEqual(first.semanticHash, parsed.semanticHash)
        XCTAssertNotEqual(first.semanticHash, first.conflictingSemanticHash)
        XCTAssertEqual(first.semanticHash.utf8.count, 71)
        await source.withdraw()
        _ = await refresh(source, transport, data: positive)
        XCTAssertTrue(source.denials.pending() === first)
        let newer = try fixture { $0["issuedAt"] = "2026-08-05T00:01:00.000Z" }
        let nextPositive = try nativeV3SourceRasterFixture(base: newer)
        let nextParsed = try EluNativeV3ConfigParser.parse(nextPositive)
        _ = await refresh(source, transport, data: nextPositive)
        _ = await refresh(source, transport, data: nativeV3SourceEnvelope(nextParsed.configV2Data))
        let second = try XCTUnwrap(source.denials.pending())
        XCTAssertFalse(first === second); XCTAssertGreaterThan(second.issuedAt, first.issuedAt)
        source.denials.acknowledge(first)
        XCTAssertTrue(source.denials.pending() === second, "Old settlement cannot erase the replacement")
        await source.close(); XCTAssertTrue(source.denials.pending() === second)
    }

    func testNativeV3MalformedExtensionWithdrawsWithoutDroppingIntoBaseOnly() async throws {
        let (source, transport, _) = try makeSource(format: .nativeV3)
        let base = try fixture(), valid = nativeV3SourceEnvelope(base)
        _ = await refresh(source, transport, data: valid)
        let malformed = Data(("{\"schemaVersion\":3,\"configV2\":" + String(decoding: base, as: UTF8.self) + ",\"raster\":null}").utf8)
        for invalid in [malformed, Data(repeating: 32, count: 65_537)] {
            let result = await refresh(source, transport, data: invalid)
            XCTAssertEqual(result, .unavailable)
            let current = await source.currentLease(); XCTAssertNil(current)
        }
        let restored = await refresh(source, transport, data: valid)
        XCTAssertEqual(restored, .document(base))
        await source.close()
    }

    func testNativeV3ExpiredNewerAndLateSupersededResponsesCannotRestoreRaster() async throws {
        let (source, transport, _) = try makeSource(format: .nativeV3)
        let positive = try nativeV3SourceRasterFixture(base: fixture())
        _ = await refresh(source, transport, data: positive)
        let pending = Task { await source.refresh() }
        await transport.waitForRequests(2)
        let newer = try inactiveFixture(status: "revoked")
        let current = await refresh(source, transport, data: nativeV3SourceEnvelope(newer))
        XCTAssertEqual(current, .document(newer))
        await transport.resolve(1, with: .success(positive))
        let stale = await pending.value; XCTAssertEqual(stale, .superseded)
        let lease = await source.currentLease(); XCTAssertNil(lease?.nativeV3?.raster)
        let expired = try fixture {
            $0["issuedAt"] = "2026-08-05T00:01:10.000Z"
            $0["expiresAt"] = "2026-08-05T00:01:20.000Z"
        }
        let denied = await refresh(source, transport, data: nativeV3SourceEnvelope(expired))
        XCTAssertEqual(denied, .unavailable)
        let previous = await refresh(source, transport, data: positive)
        XCTAssertEqual(previous, .unavailable)
        await source.close()
    }

    private func makeSource(format: EluV2ConfigRequest.Format = .v2) throws -> (EluV2ConfigSource, EluV2ControlledTransport, EluV2TestClock) {
        let clock = EluV2TestClock()
        let transport = EluV2ControlledTransport()
        let source = try EluV2ConfigSource(siteKey: key, format: format, transport: transport, clock: clock.clock)
        return (source, transport, clock)
    }

    private func refresh(
        _ source: EluV2ConfigSource, _ transport: EluV2ControlledTransport, data: Data
    ) async -> EluV2ConfigRefreshResult {
        await refresh(source, transport, result: .success(data))
    }

    private func refresh(
        _ source: EluV2ConfigSource, _ transport: EluV2ControlledTransport, result: Result<Data, Error>
    ) async -> EluV2ConfigRefreshResult {
        let index = await transport.count
        let task = Task { await source.refresh() }
        await transport.waitForRequests(index + 1)
        await transport.resolve(index, with: result)
        return await task.value
    }

    private func fixture(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        // Use the closed contract's frozen fixture; no live config fetch.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Conformance/V2/fixtures/config-enabled.json"))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func inactiveFixture(status: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "revision": "inactive-1", "status": status,
            "issuedAt": "2026-08-05T00:01:00.000Z", "expiresAt": "2026-08-05T00:05:00.000Z",
            "reason": "owner_disabled",
        ], options: [.sortedKeys])
    }
}

// Shared only by these source/lifecycle/gate tests. The parser's independent
// issuer goldens qualify policy hashing; these fixtures exercise original ownership.
func nativeV3SourceEnvelope(_ base: Data) -> Data {
    Data("{\"schemaVersion\":3,\"configV2\":".utf8) + base + Data("}".utf8)
}

func nativeV3SourceRasterFixture(base original: Data) throws -> Data {
    var base = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    var privacy = base["privacy"] as! [String: Any]
    var masking = privacy["masking"] as! [String: Any]; masking["images"] = "allow"
    privacy["masking"] = masking; base["privacy"] = privacy
    var capabilities = base["capabilities"] as! [String: Any]
    var replay = capabilities["replay"] as! [String: Any]
    replay["replayProtocolGeneration"] = "protocol-generation-v2"
    replay["transports"] = [["codec": "elu-native-wireframe-v2", "compression": "gzip"]]
    capabilities["replay"] = replay; base["capabilities"] = capabilities
    let limits: [String: Any] = ["requestBytes": 5_242_880, "decodedPayloadBytes": 2_800_000,
        "pngBytes": 2_097_152, "imageEdgePixels": 2_048, "imagePixels": 1_048_576,
        "viewportEdge": 16_384, "minimumFrameIntervalSeconds": 1, "framesPerChunk": 1]
    let revision = privacy["revision"] as! String
    let profile = EluNativeV3ConfigParser.profileHash
    var declared: [String: Any] = ["schemaVersion": 1, "maskingProfileHash": profile,
        "declaredRegionsAllowed": true, "inputCoverage": "declared-regions",
        "automaticInputDiscovery": false, "unknownContentClassification": false,
        "redactionBoundary": "before-encoding", "requiredBindingBehavior": "deny-incomplete-or-stale"]
    var material = declared
    material["policyRevision"] = revision; material["basePolicyRevision"] = revision
    material["basePrivacy"] = privacy; material["replayAudience"] = base["replayAudience"] ?? "all-devices"
    material["limits"] = limits
    let canonical = try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: material)).canonicalData
    declared["revision"] = revision
    declared["effectivePolicyHash"] = EluV1StrictCanonicalJSON.hash(Data("elu-native-raster-effective-policy-v1\0".utf8) + canonical)
    let raster: [String: Any] = ["schemaVersion": 1, "endpoint": "https://ingest.elu.dev/v3/replay",
        "replayContractVersion": "3.0.0", "replaySchemaVersion": 3, "ackSchemaVersion": 3,
        "replayProtocolGeneration": "native-raster-generation-v1", "codec": "elu-native-raster-v1",
        "compression": "gzip", "platforms": ["android", "ios"], "privacy": declared, "limits": limits]
    return try JSONSerialization.data(withJSONObject: ["schemaVersion": 3, "configV2": base, "raster": raster], options: [.sortedKeys])
}

private final class EluV2TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wall = Date(timeIntervalSince1970: 1_785_888_090)
    private var continuous: UInt64 = 1
    var clock: EluV2ConfigClock {
        EluV2ConfigClock(wallNow: { self.readWall() }, continuousNow: { self.readContinuous() }, floorTicks: { $0 })
    }
    func set(wall: TimeInterval, continuous: UInt64) {
        lock.lock()
        self.wall = Date(timeIntervalSince1970: wall)
        self.continuous = continuous
        lock.unlock()
    }
    private func readWall() -> Date { lock.lock(); defer { lock.unlock() }; return wall }
    private func readContinuous() -> UInt64 { lock.lock(); defer { lock.unlock() }; return continuous }
}

private actor EluV2ControlledTransport: EluV2ConfigTransport {
    private var requests: [CheckedContinuation<Data, Error>?] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int { requests.count }
    private(set) var urls: [URL] = []
    func fetch(_ request: EluV2ConfigRequest) async throws -> Data {
        urls.append(request.url)
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            let ready = observers.filter { $0.0 <= requests.count }
            observers.removeAll { $0.0 <= requests.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func resolve(_ index: Int, with result: Result<Data, Error>) {
        let continuation = requests[index]
        requests[index] = nil
        continuation?.resume(with: result)
    }
}
