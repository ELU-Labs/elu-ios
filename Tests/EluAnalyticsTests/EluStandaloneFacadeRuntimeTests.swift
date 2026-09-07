import Foundation
import XCTest
@testable import EluAnalytics

/// The facade projection onto the ELU-owned runtime: what each `Elu` method
/// records, in what order, what the flag getters report, and what a disabled
/// configuration leaves behind.
final class EluStandaloneFacadeRuntimeTests: XCTestCase {
    private static let siteKey = "elu_pk_test_facade"
    private let baseDate = Date(timeIntervalSince1970: 1_785_801_660) // 2026-08-04T00:01:00Z

    private struct CheckoutFailure: LocalizedError {
        var errorDescription: String? { "checkout failed" }
    }

    func testEveryFacadeMethodRecordsThroughTheOwnedRuntimeInCallOrder() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)

            harness.backend.execute(.capture(event: "checkout", properties: ["amount": 42]))
            harness.backend.execute(.screen(name: "Cart", properties: nil))
            harness.backend.execute(.captureException(CheckoutFailure(), properties: nil))
            harness.backend.execute(
                .identify(distinctId: "user-1", userProperties: ["plan": "pro"])
            )
            harness.backend.execute(.alias("alias-1"))
            harness.backend.execute(.register(["tier": "gold"]))
            harness.backend.execute(.unregister("tier"))
            harness.backend.execute(
                .group(type: "company", key: "acme", properties: ["seats": 12])
            )
            harness.backend.execute(.setPersonProperties(["plan": "enterprise"]))
            harness.backend.execute(.setPersonPropertiesForFlags(["beta": true]))
            harness.backend.execute(
                .setGroupPropertiesForFlags(type: "company", properties: ["tier": "design"])
            )
            harness.backend.execute(.capture(event: "after-identity", properties: nil))
            await harness.backend.settled()

            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.identity.userId, "user-1")
            XCTAssertEqual(snapshot.identity.groups["company"], "acme")
            XCTAssertNil(snapshot.identity.superProperties["tier"])
            XCTAssertEqual(snapshot.flagContext.personProperties["plan"], .string("enterprise"))
            XCTAssertEqual(snapshot.flagContext.personProperties["beta"], .bool(true))
            XCTAssertEqual(
                snapshot.flagContext.groupProperties["company"]?["tier"],
                .string("design")
            )

            _ = await harness.runtime.flush()
            let records = try await harness.transport.recordedRecords()
            XCTAssertEqual(
                records.compactMap { $0["event"] as? [String: Any] }
                    .compactMap { $0["name"] as? String },
                ["checkout", "Cart", "$exception", "after-identity"]
            )
            XCTAssertEqual(
                records.compactMap { $0["mutation"] as? [String: Any] }
                    .compactMap { ($0["change"] as? [String: Any])?["type"] as? String },
                [
                    "identify",
                    "linkAlias",
                    "associateGroup",
                    "setGroupProperties",
                    "setPersonProperties",
                    "setPersonProperties",
                    "setGroupProperties",
                ]
            )
            await harness.close()
        }
    }

    func testCapturedPropertiesAreProjectedAndReservedNamesAreStripped() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)

            harness.backend.execute(
                .capture(
                    event: "checkout",
                    properties: [
                        "amount": 42,
                        "ratio": 1.5,
                        "flagged": true,
                        "label": "cart",
                        "missing": NSNull(),
                        "items": ["a", 2],
                        "nested": ["deep": true],
                        "$elu_sdk_version": "9.9.9",
                        "unsupported": Data(),
                    ]
                )
            )
            await harness.backend.settled()
            _ = await harness.runtime.flush()

            let events = try await harness.transport.recordedEvents()
            let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
            XCTAssertEqual(properties["amount"] as? Int, 42)
            XCTAssertEqual(properties["ratio"] as? Double, 1.5)
            XCTAssertEqual(properties["flagged"] as? Bool, true)
            XCTAssertEqual(properties["label"] as? String, "cart")
            XCTAssertTrue(properties["missing"] is NSNull)
            XCTAssertEqual((properties["items"] as? [Any])?.count, 2)
            XCTAssertEqual((properties["nested"] as? [String: Any])?["deep"] as? Bool, true)
            XCTAssertNil(properties["unsupported"])
            // The runtime stamps its own version properties; a customer value
            // never shadows them.
            XCTAssertEqual(properties["$elu_sdk_version"] as? String, EluCore.sdkVersion)
            XCTAssertEqual(harness.backend.dropCounts[.reservedProperty], 1)
            XCTAssertEqual(harness.backend.dropCounts[.invalidInput], 1)
            await harness.close()
        }
    }

    func testFlagGettersReportDefaultsUntilFlagsLoadThenReportTheSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root, flagTransport: FacadeFlagTransport())

            XCTAssertFalse(harness.backend.flagsAreLoaded)
            XCTAssertNil(harness.backend.featureFlag("variant"))
            XCTAssertNil(harness.backend.featureFlagPayload("variant"))
            XCTAssertFalse(harness.backend.isFeatureEnabled("variant"))

            harness.backend.activate()
            await harness.backend.settled()

            XCTAssertTrue(harness.backend.flagsAreLoaded)
            XCTAssertEqual(harness.loadAnnouncements(), 1)
            XCTAssertEqual(harness.backend.featureFlag("variant") as? String, "variant-a")
            XCTAssertTrue(harness.backend.isFeatureEnabled("variant"))
            // A boolean-false flag is present but disabled; an absent key has
            // no value at all.
            XCTAssertEqual(harness.backend.featureFlag("enabled") as? Bool, false)
            XCTAssertFalse(harness.backend.isFeatureEnabled("enabled"))
            XCTAssertNil(harness.backend.featureFlag("absent"))
            XCTAssertFalse(harness.backend.isFeatureEnabled("absent"))
            // A numeric flag reports its enabled state, like the browser.
            XCTAssertEqual(harness.backend.featureFlag("zero") as? Bool, false)

            let payload = harness.backend.featureFlagPayload("variant") as? [String: Any]
            XCTAssertEqual(payload?["color"] as? String, "violet")
            XCTAssertNil(harness.backend.featureFlagPayload("enabled"))
            await harness.close()
        }
    }

    func testExposureIsReportedOncePerKeyAndValueForEachIdentityRevision() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root, flagTransport: FacadeFlagTransport())
            harness.backend.activate()
            await harness.backend.settled()

            _ = harness.backend.featureFlag("variant")
            _ = harness.backend.featureFlag("variant")
            _ = harness.backend.isFeatureEnabled("variant")
            // A payload read never reports an exposure.
            _ = harness.backend.featureFlagPayload("variant")
            // A key with no value reports its own missing-flag exposure, once.
            _ = harness.backend.featureFlag("absent")
            _ = harness.backend.featureFlag("absent")
            await harness.backend.settled()
            _ = await harness.runtime.flush()

            var exposures = try await harness.transport.recordedEvents()
                .filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(exposures.count, 2)
            let reported = try XCTUnwrap(exposures.first?["properties"] as? [String: Any])
            XCTAssertEqual(reported["$feature_flag"] as? String, "variant")
            XCTAssertEqual(reported["$feature_flag_response"] as? String, "variant-a")
            XCTAssertEqual(
                (reported["$feature_flag_payload"] as? [String: Any])?["color"] as? String,
                "violet"
            )
            let missing = try XCTUnwrap(exposures.last?["properties"] as? [String: Any])
            XCTAssertEqual(missing["$feature_flag"] as? String, "absent")
            XCTAssertEqual(missing["$feature_flag_error"] as? String, "flag_missing")
            XCTAssertNil(missing["$feature_flag_response"])

            // A new identity is a new ledger: the same value is reported again.
            harness.backend.execute(.identify(distinctId: "user-1", userProperties: nil))
            await harness.backend.settled()
            _ = harness.backend.featureFlag("variant")
            await harness.backend.settled()
            _ = await harness.runtime.flush()

            exposures = try await harness.transport.recordedEvents()
                .filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(exposures.count, 3)
            await harness.close()
        }
    }

    func testResetEndsTheIdentityAndClearsLoadedFlagsImmediately() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root, flagTransport: FacadeFlagTransport())
            harness.backend.activate()
            harness.backend.execute(.identify(distinctId: "user-1", userProperties: nil))
            harness.backend.execute(.register(["tier": "gold"]))
            await harness.backend.settled()
            XCTAssertEqual(harness.backend.distinctId(), "user-1")
            XCTAssertTrue(harness.backend.flagsAreLoaded)

            harness.backend.execute(.reset)
            // The flags belonged to the identity that is ending, so a read
            // before the queued reset runs must not report them.
            XCTAssertFalse(harness.backend.flagsAreLoaded)
            XCTAssertNil(harness.backend.featureFlag("variant"))

            await harness.backend.settled()
            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertNil(snapshot.identity.userId)
            XCTAssertTrue(snapshot.identity.groups.isEmpty)
            XCTAssertTrue(snapshot.identity.superProperties.isEmpty)
            XCTAssertEqual(harness.backend.distinctId(), snapshot.identity.anonymousId)
            await harness.close()
        }
    }

    func testIdentifyIsVisibleToTheSynchronousGetterBeforeItSettles() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            let before = harness.backend.distinctId()

            harness.backend.execute(.identify(distinctId: "user-1", userProperties: nil))
            XCTAssertEqual(harness.backend.distinctId(), "user-1")
            XCTAssertNotEqual(before, "user-1")

            await harness.backend.settled()
            XCTAssertEqual(harness.backend.distinctId(), "user-1")
            await harness.close()
        }
    }

    func testDisabledConfigurationRecordsNothingAndSendsNothing() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(
                root: root,
                document: fixture("config-disabled.json")
            )

            harness.backend.execute(.capture(event: "checkout", properties: nil))
            harness.backend.execute(.identify(distinctId: "user-1", userProperties: nil))
            harness.backend.execute(.register(["tier": "gold"]))
            harness.backend.activate()
            await harness.backend.settled()

            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.queuedCount, 0)
            XCTAssertNil(snapshot.identity.userId)
            let flushed = await harness.runtime.flush()
            XCTAssertEqual(flushed, .unavailable)
            let records = try await harness.transport.recordedRecords()
            XCTAssertTrue(records.isEmpty)
            XCTAssertNil(harness.backend.featureFlag("variant"))
            XCTAssertFalse(harness.backend.isFeatureEnabled("variant"))
            await harness.close()
        }
    }

    func testShutDownStopsEveryLaterCallAndStillDeliversAReloadCompletion() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            harness.backend.activate()
            await harness.backend.settled()

            harness.backend.shutDown()
            harness.backend.execute(.capture(event: "after-shutdown", properties: nil))

            let completed = expectation(description: "reload completion")
            harness.backend.reloadFeatureFlags {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            }
            await harness.backend.settled()
            await fulfillment(of: [completed], timeout: 5)

            XCTAssertNil(harness.backend.featureFlag("variant"))
            let records = try await harness.transport.recordedRecords()
            XCTAssertFalse(
                records.compactMap { ($0["event"] as? [String: Any])?["name"] as? String }
                    .contains("after-shutdown")
            )
        }
    }

    /// The configuration route still serves the document the provider-backed
    /// path decodes, which this runtime does not accept. Until the route
    /// serves a document it validates, the runtime holds no capture authority
    /// and records nothing, which is the fail-closed end of the selection.
    func testTheCurrentlyServedConfigurationDocumentGrantsNoAuthority() async throws {
        try await withTemporaryDirectory { root in
            let served = Data(
                """
                {"v":1,"enabled":true,"publicToken":"t","host":"https://ingest.example.test"}
                """.utf8
            )
            let harness = try await makeHarness(root: root, document: served)

            let phase = await harness.runtime.currentPhase
            XCTAssertEqual(phase, .blocked(.malformed))

            harness.backend.execute(.capture(event: "checkout", properties: nil))
            harness.backend.execute(.identify(distinctId: "user-1", userProperties: nil))
            await harness.backend.settled()

            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.queuedCount, 0)
            XCTAssertNil(snapshot.identity.userId)
            let records = try await harness.transport.recordedRecords()
            XCTAssertTrue(records.isEmpty)
            await harness.close()
        }
    }

    func testReloadCompletionStillRunsWhenTheStoreCannotBeOpened() async throws {
        let context = EluRuntimeBackendContext(
            siteKey: Self.siteKey,
            config: try TestConfigFactory.make(),
            configDocument: fixture("config-enabled.json"),
            isNewUser: true,
            flagsDidLoad: {}
        )
        let backend = EluStandaloneFacadeRuntime(
            context: context,
            open: { throw FacadeTransportError.malformedRequest }
        )

        let completed = expectation(description: "reload completion")
        backend.reloadFeatureFlags {
            XCTAssertTrue(Thread.isMainThread)
            completed.fulfill()
        }
        await backend.settled()
        await fulfillment(of: [completed], timeout: 5)

        // Nothing else the facade can be asked for reports a value it does
        // not have.
        XCTAssertNil(backend.distinctId())
        XCTAssertNil(backend.featureFlag("variant"))
        XCTAssertFalse(backend.isFeatureEnabled("variant"))
    }

    func testAliasWithoutAnIdentityIsDiscardedRatherThanRecorded() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)

            harness.backend.execute(.alias("alias-1"))
            await harness.backend.settled()

            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.queuedCount, 0)
            XCTAssertEqual(harness.backend.dropCounts[.unauthorized], 1)
            await harness.close()
        }
    }

    // MARK: - Harness

    private struct Harness {
        let runtime: EluStandaloneRuntime
        let backend: EluStandaloneFacadeRuntime
        let transport: FacadeBatchTransport
        let announcements: FacadeCounter

        func loadAnnouncements() -> Int { announcements.value() }

        func close() async {
            backend.shutDown()
            await backend.settled()
            await runtime.close()
        }
    }

    private func makeHarness(
        root: URL,
        document: Data? = nil,
        flagTransport: (any EluV1FlagTransport)? = nil
    ) async throws -> Harness {
        let transport = FacadeBatchTransport()
        let clock = FacadeClock(wall: baseDate)
        let identifiers = FacadeCounter()
        let runtime = try await EluStandaloneRuntime.make(
            rootDirectoryURL: root,
            siteKey: Self.siteKey,
            transport: transport,
            backgroundHandoff: EluStandaloneBackgroundHandoff(
                start: { operation in
                    await operation()
                    return true
                },
                cancel: {}
            ),
            clock: { clock.wall() },
            continuousClock: { clock.continuous() },
            continuousBudgetConverter: { $0 },
            time: clock.source,
            randomUnit: { 0 },
            timeZoneIdentifier: { "America/New_York" },
            replaySampleDraw: { 0.1 },
            anonymousIdGenerator: { "anon_facade_\(identifiers.next())" },
            streamIdGenerator: { "stream_facade" },
            sessionIdGenerator: { "session_facade_\(identifiers.next())" }
        )
        let announcements = FacadeCounter()
        let context = EluRuntimeBackendContext(
            siteKey: Self.siteKey,
            config: try TestConfigFactory.make(),
            configDocument: document ?? fixture("config-enabled.json"),
            isNewUser: true,
            flagsDidLoad: { _ = announcements.next() }
        )
        let backend = EluStandaloneFacadeRuntime(
            context: context,
            open: { runtime },
            flagTransport: flagTransport
        )
        // The runtime opens on the same ordered chain every call joins, so a
        // settled chain means the configuration decision has been applied.
        await backend.settled()
        return Harness(
            runtime: runtime,
            backend: backend,
            transport: transport,
            announcements: announcements
        )
    }

    private func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance/V1/Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        return try! Data(contentsOf: url)
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "elu-standalone-facade-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

/// Accepts every batch and keeps the records it was handed.
actor FacadeBatchTransport: EluV1BatchHTTPTransport {
    private var requests: [EluV1BatchHTTPRequest] = []

    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse {
        requests.append(request)
        guard let root = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let requestId = root["requestId"] as? String,
              let streamId = root["streamId"] as? String,
              let records = root["records"] as? [[String: Any]]
        else {
            throw FacadeTransportError.malformedRequest
        }
        var outcomes: [[String: Any]] = []
        var last: Int64?
        for record in records {
            guard let kind = record["kind"] as? String,
                  let payload = record[kind] as? [String: Any],
                  let sequence = (payload["sequence"] as? NSNumber)?.int64Value,
                  let recordId = payload[kind == "event" ? "eventId" : "mutationId"] as? String
            else {
                throw FacadeTransportError.malformedRequest
            }
            last = sequence
            outcomes.append([
                "sequence": sequence,
                "recordId": recordId,
                "kind": kind,
                "result": "accepted",
            ])
        }
        guard let resolved = last else { throw FacadeTransportError.malformedRequest }
        let acknowledgement: [String: Any] = [
            "schemaVersion": 1,
            "requestId": requestId,
            "streamId": streamId,
            "resolvedThroughSequence": resolved,
            "retryFromSequence": NSNull(),
            "outcomes": outcomes,
        ]
        return EluV1BatchHTTPResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: acknowledgement, options: [.sortedKeys])
        )
    }

    func recordedRecords() throws -> [[String: Any]] {
        try requests.flatMap { request -> [[String: Any]] in
            let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            return (body?["records"] as? [[String: Any]]) ?? []
        }
    }

    func recordedEvents() throws -> [[String: Any]] {
        try recordedRecords().compactMap { $0["event"] as? [String: Any] }
    }
}

/// Answers every flag request from the identity witness it was sent.
actor FacadeFlagTransport: EluV1FlagTransport {
    private var calls = 0

    func send(endpoint: URL, requestBody: Data) async throws -> Data {
        calls += 1
        guard let request = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              let identity = request["identity"] as? [String: Any]
        else {
            throw FacadeFlagTransportError.malformedRequest
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "requestId": request["requestId"] ?? "",
                "contextRevision": request["contextRevision"] ?? 0,
                "identityRevision": identity["revision"] ?? 0,
                "flagsRevision": "flags-facade-1",
                "evaluatedAt": "2026-08-04T00:01:01.000Z",
                "expiresAt": "2026-08-04T00:04:00.000Z",
                "flags": [
                    "variant": "variant-a",
                    "enabled": false,
                    "zero": 0,
                ],
                "payloads": ["variant": ["color": "violet"]],
            ],
            options: [.sortedKeys]
        )
    }

    func callCount() -> Int { calls }
}

enum FacadeFlagTransportError: Error {
    case malformedRequest
}

enum FacadeTransportError: Error {
    case malformedRequest
}

/// A wall and continuous clock a test advances explicitly.
final class FacadeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wallValue: Date
    private var continuousValue: UInt64 = 1_000_000_000

    init(wall: Date) {
        wallValue = wall
    }

    func wall() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return wallValue
    }

    func continuous() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return continuousValue
    }

    var source: EluV1BatchTimeSource {
        EluV1BatchTimeSource(
            wallNow: { [self] in self.wall() },
            monotonicNow: { [self] in self.continuous() },
            sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }
        )
    }
}

/// A monotonic counter for unique test identifiers.
final class FacadeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
