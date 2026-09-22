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

    private func makeSource() throws -> (EluV2ConfigSource, EluV2ControlledTransport, EluV2TestClock) {
        let clock = EluV2TestClock()
        let transport = EluV2ControlledTransport()
        let source = try EluV2ConfigSource(siteKey: key, transport: transport, clock: clock.clock)
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
    func fetch(_: EluV2ConfigRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
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
