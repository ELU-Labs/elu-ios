import Foundation
import XCTest
@testable import EluAnalytics

final class EluV2ConfigManagerTests: XCTestCase {
    private let v1Now = Date(timeIntervalSince1970: 1_785_801_660) // 2026-08-04T00:01:00Z
    private let v2Now = Date(timeIntervalSince1970: 1_785_888_090) // 2026-08-05T00:01:30Z

    func testFrozenV2DocumentInstallsWithV2ReplayRoleExactPairsAndProtocolGeneration() throws {
        let manager = manager(readbackProven: [browserPair])
        XCTAssertEqual(
            try manager.update(configData: v2Fixture("config-enabled.json"), now: v2Now),
            .enabled(
                revision: "config-v2-2026-08-05-1",
                expiresAt: Date(timeIntervalSince1970: 1_785_888_300)
            )
        )

        let result = try manager.authorize(
            effectivePrivacyStateData: try v2AllowedPrivacy { _ in },
            identity: identity(contextRevision: 5),
            now: v2Now
        )

        XCTAssertEqual(result.configSchemaVersion, 2)
        XCTAssertEqual(result.configRevision, "config-v2-2026-08-05-1")
        XCTAssertEqual(result.siteId, "site_demo")
        XCTAssertEqual(result.exactExpiresAt.source, "2026-08-05T00:05:00.000Z")
        XCTAssertEqual(result.endpoints.roles, Set([.events, .replay, .flags]))
        XCTAssertEqual(result.endpoints[.events]?.absoluteString, "https://ingest.elu.dev/v1/events")
        XCTAssertEqual(result.endpoints[.replay]?.absoluteString, "https://ingest.elu.dev/v2/replay")
        XCTAssertEqual(result.endpoints[.flags]?.absoluteString, "https://ingest.elu.dev/v1/flags")
        XCTAssertNil(result.endpoints[.assets])
        XCTAssertEqual(result.replayProtocolGeneration, "replay-v2-generation-1")
        XCTAssertEqual(result.sessionIdleTimeoutSeconds, 1_800)
        XCTAssertEqual(result.sessionMaximumDurationSeconds, 86_400)
        XCTAssertEqual(result.limits.eventBatchCount, 100)
        XCTAssertEqual(result.limits.eventBatchBytes, 1_048_576)
        XCTAssertEqual(result.limits.replayChunkBytes, 5_242_880)
        XCTAssertEqual(result.limits.queueBytes, 16_777_216)
        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(result.replayAuthorization, .authorized(browserPair))
    }

    func testV2PairsAreExactSoTheCodecIsNotAdvertisedWithAnotherCompression() throws {
        let uncompressed = EluV1ReplayTransportSelection(codec: browserPair.codec, compression: .none)!
        let manager = manager(readbackProven: [uncompressed])
        _ = try manager.update(configData: v2Fixture("config-enabled.json"), now: v2Now)

        let privacy = try v2AllowedPrivacy { object in
            var transport = object["replayTransport"] as! [String: Any]
            transport["compression"] = "none"
            object["replayTransport"] = transport
        }
        let result = try manager.authorize(
            effectivePrivacyStateData: privacy,
            identity: identity(contextRevision: 5),
            now: v2Now
        )

        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(result.replayAuthorization, .invalid(.unadvertisedReplayTransport))
        XCTAssertEqual(result.endpoints.roles, Set([.events, .flags]))
        XCTAssertNil(result.endpoints[.replay])
    }

    func testV1DocumentsStayOnTheV1ReplayRoleWithoutAProtocolGeneration() throws {
        let manager = manager(readbackProven: [browserPair])
        _ = try manager.update(configData: v1Fixture("config-enabled.json"), now: v1Now)

        let result = try manager.authorize(
            effectivePrivacyStateData: try v2AllowedPrivacy { _ in },
            identity: identity(contextRevision: 5),
            now: v1Now
        )

        XCTAssertEqual(result.configSchemaVersion, 1)
        XCTAssertNil(result.replayProtocolGeneration)
        XCTAssertEqual(result.endpoints[.replay]?.absoluteString, "https://ingest.elu.dev/v1/replay")
        XCTAssertEqual(result.limits.queueBytes, 16_777_216)
        XCTAssertEqual(result.replayAuthorization, .authorized(browserPair))
    }

    func testV2DisabledFixtureStaysInactive() throws {
        let manager = manager()
        XCTAssertEqual(
            try manager.update(configData: v2Fixture("config-disabled.json"), now: v2Now),
            .disabled(revision: "config-v2-disabled-1")
        )
        XCTAssertThrowsError(
            try manager.authorize(
                effectivePrivacyStateData: try v2AllowedPrivacy { _ in },
                identity: identity(contextRevision: 5),
                now: v2Now
            )
        ) { error in
            XCTAssertEqual(error as? EluV1ConfigResolutionError, .missingActiveConfig)
        }
    }

    func testMajorsOrderByIssuedAtLikeAnyRevision() throws {
        let manager = manager(readbackProven: [browserPair])
        XCTAssertEqual(
            try manager.update(configData: v1Fixture("config-enabled.json"), now: v1Now),
            .enabled(
                revision: "config-2026-08-04-1",
                expiresAt: Date(timeIntervalSince1970: 1_785_801_900)
            )
        )
        XCTAssertEqual(
            try manager.update(configData: v2Fixture("config-enabled.json"), now: v2Now),
            .enabled(
                revision: "config-v2-2026-08-05-1",
                expiresAt: Date(timeIntervalSince1970: 1_785_888_300)
            )
        )
        XCTAssertEqual(
            try manager.update(configData: v1Fixture("config-enabled.json"), now: v2Now),
            .stale(revision: "config-2026-08-04-1")
        )

        let result = try manager.authorize(
            effectivePrivacyStateData: try v2AllowedPrivacy { _ in },
            identity: identity(contextRevision: 5),
            now: v2Now
        )
        XCTAssertEqual(result.configSchemaVersion, 2)
        XCTAssertEqual(result.endpoints[.replay]?.absoluteString, "https://ingest.elu.dev/v2/replay")
    }

    func testFlagProjectionAcceptsTheV2DocumentAndKeepsTheV1FlagsRole() throws {
        let manager = try EluV1ConfigManager(exactConstructorSiteKey: "site-key")
        let prepared = try manager.prepareFlagConfig(
            configData: v2Fixture("config-enabled.json"),
            now: v2Now
        )

        XCTAssertNil(prepared.restriction)
        XCTAssertEqual(prepared.siteId, "site_demo")
        XCTAssertEqual(prepared.endpoint?.absoluteString, "https://ingest.elu.dev/v1/flags")
        XCTAssertEqual(prepared.configRevision, "config-v2-2026-08-05-1")

        XCTAssertThrowsError(
            try manager.prepareFlagConfig(
                configData: try v2Config { $0["schemaVersion"] = 3 },
                now: v2Now
            )
        ) { error in
            XCTAssertEqual(
                error as? EluV1ConfigResolutionError,
                .unsupportedConfigSchemaVersion
            )
        }
    }

    func testReplayRolePathIsBoundToTheDocumentMajor() throws {
        let v2WithV1Replay = try v2Config { object in
            var endpoints = object["endpoints"] as! [String: Any]
            endpoints["replay"] = "https://ingest.elu.dev/v1/replay"
            object["endpoints"] = endpoints
        }
        assertUpdateError(.untrustedEndpoint(.replay), config: v2WithV1Replay, now: v2Now)

        let v1WithV2Replay = try v1Config { object in
            var endpoints = object["endpoints"] as! [String: Any]
            endpoints["replay"] = "https://ingest.elu.dev/v2/replay"
            object["endpoints"] = endpoints
        }
        assertUpdateError(.untrustedEndpoint(.replay), config: v1WithV2Replay, now: v1Now)
    }

    func testV2DocumentsRejectEveryRegressionOfTheFrozenCapabilityRules() throws {
        let malformed: [Data] = [
            try v2Capabilities { $0.removeValue(forKey: "events") },
            try v2Capabilities { capabilities in
                var events = capabilities["events"] as! [String: Any]
                events["contractVersion"] = "2.0.0"
                capabilities["events"] = events
            },
            try v2Capabilities { capabilities in
                var flags = capabilities["flags"] as! [String: Any]
                flags["schemaVersion"] = 2
                capabilities["flags"] = flags
            },
            try v2Replay { $0["replayContractVersion"] = "1.0.0" },
            try v2Replay { $0["replaySchemaVersion"] = 1 },
            try v2Replay { $0["replayProtocolGeneration"] = "" },
            try v2Replay { $0["replayProtocolGeneration"] = String(repeating: "g", count: 129) },
            try v2Replay { replay in
                let first = (replay["transports"] as! [[String: Any]])[0]
                replay["transports"] = [first, first]
            },
            try v2Replay { replay in
                replay.removeValue(forKey: "transports")
                replay["acceptedCodecs"] = ["elu-browser-dom-v1"]
                replay["acceptedCompressions"] = ["gzip"]
            },
            try v2Replay { $0["transports"] = [[String: Any]]() },
            try v2Replay { replay in
                var first = (replay["transports"] as! [[String: Any]])[0]
                first["compression"] = "br"
                replay["transports"] = [first]
            },
            try v2Replay { replay in
                replay["transports"] = (1 ... 33).map {
                    ["codec": "elu-browser-dom-v\($0)", "compression": "gzip"]
                }
            },
            try v2Replay { $0["futureField"] = true },
            try v1Config { $0["schemaVersion"] = 2 },
        ]
        for config in malformed {
            assertUpdateError(.malformedConfig, config: config, now: v2Now)
        }

        assertUpdateError(
            .unsupportedConfigSchemaVersion,
            config: try v2Config { $0["schemaVersion"] = 3 },
            now: v2Now
        )
    }

    func testCodecBoundIsTheFrozenSchemaPattern() throws {
        let longestCodec = "elu-" + String(repeating: "a", count: 64)
        let longest = try v2Replay { replay in
            var first = (replay["transports"] as! [[String: Any]])[0]
            first["codec"] = longestCodec
            replay["transports"] = [first]
        }
        let manager = manager(
            readbackProven: [EluV1ReplayTransportSelection(codec: longestCodec, compression: .gzip)!]
        )
        XCTAssertNoThrow(try manager.update(configData: longest, now: v2Now))

        let tooLong = try v2Replay { replay in
            var first = (replay["transports"] as! [[String: Any]])[0]
            first["codec"] = longestCodec + "a"
            replay["transports"] = [first]
        }
        assertUpdateError(.malformedConfig, config: tooLong, now: v2Now)
    }

    private var browserPair: EluV1ReplayTransportSelection {
        EluV1ReplayTransportSelection(codec: "elu-browser-dom-v1", compression: .gzip)!
    }

    private func manager(
        readbackProven: Set<EluV1ReplayTransportSelection> = []
    ) -> EluV1ConfigManager {
        EluV1ConfigManager(readbackProvenReplayTransports: readbackProven)
    }

    private func assertUpdateError(
        _ expected: EluV1ConfigResolutionError,
        config: Data,
        now: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try manager().update(configData: config, now: now),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? EluV1ConfigResolutionError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func identity(contextRevision: Int64, optedOut: Bool = false) throws -> EluIdentitySnapshot {
        let state = try EluIdentityState(
            revision: 0,
            contextRevision: contextRevision,
            anonymousId: "anon-config-v2-test",
            userId: nil,
            groups: [:],
            superProperties: [:],
            session: nil,
            optedOut: optedOut,
            updatedAt: v2Now
        )
        return EluIdentitySnapshot(
            identity: state,
            streamId: "stream-config-v2-test",
            nextSequence: 0,
            flagContext: EluFlagContext()
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func v1Fixture(_ name: String) -> Data {
        try! Data(contentsOf: repositoryRoot
            .appendingPathComponent("Conformance/V1/Fixtures", isDirectory: true)
            .appendingPathComponent(name))
    }

    private func v2Fixture(_ name: String) -> Data {
        try! Data(contentsOf: repositoryRoot
            .appendingPathComponent("Conformance/V2/fixtures", isDirectory: true)
            .appendingPathComponent(name))
    }

    private func v1Config(_ mutation: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try jsonObject(v1Fixture("config-enabled.json"))
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func v2Config(_ mutation: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try jsonObject(v2Fixture("config-enabled.json"))
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func v2Capabilities(_ mutation: (inout [String: Any]) throws -> Void) throws -> Data {
        try v2Config { object in
            var capabilities = object["capabilities"] as! [String: Any]
            try mutation(&capabilities)
            object["capabilities"] = capabilities
        }
    }

    private func v2Replay(_ mutation: (inout [String: Any]) throws -> Void) throws -> Data {
        try v2Capabilities { capabilities in
            var replay = capabilities["replay"] as! [String: Any]
            try mutation(&replay)
            capabilities["replay"] = replay
        }
    }

    /// The frozen v1 privacy fixture already selects the v2 fixture's only
    /// advertised pair; native replay additionally requires recorded fallback.
    private func v2AllowedPrivacy(_ mutation: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try jsonObject(v1Fixture("privacy-allowed.json"))
        var masking = object["effectiveMasking"] as! [String: Any]
        masking["platformFallbackApplied"] = true
        object["effectiveMasking"] = masking
        try mutation(&object)
        object["effectivePolicyHash"] = "sha256:" + String(repeating: "0", count: 64)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        object["effectivePolicyHash"] = try EluV1ConfigManager.computedEffectivePolicyHash(for: data)
        data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
