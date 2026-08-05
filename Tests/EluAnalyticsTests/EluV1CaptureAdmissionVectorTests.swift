import Foundation
import XCTest
@testable import EluAnalytics

final class EluV1CaptureAdmissionVectorTests: XCTestCase {
    private enum Applicability {
        case native
        case nativeStructural
        case browserOnly(String)
    }

    func testSharedCaptureAdmissionActivityVector() async throws {
        let vector = try dictionary(try Data(contentsOf: vectorURL))
        XCTAssertEqual(vector["schemaVersion"] as? Int, 1)
        XCTAssertEqual(vector["vectorId"] as? String, "elu-capture-admission-activity-v1")
        XCTAssertEqual(
            vector["platformSpecificExclusions"] as? [String],
            ["recordId", "payloadBytes", "versions.platform"]
        )
        try executeCanonicalCases(try dictionary(vector["canonicalization"]))

        let scenarios = try dictionaries(vector["scenarios"])
        let applicability: [String: Applicability] = [
            "same-semantic-different-bytes": .native,
            "equal-issued-semantic-conflict": .native,
            "newer-revoke-older-cannot-revive": .native,
            "same-witness-restriction-dominates": .native,
            "higher-context-can-reauthorize": .native,
            "malformed-latches-terminal": .native,
            "site-pin": .native,
            "namespace-and-stream-binding": .nativeStructural,
            "super-properties-and-screen": .native,
            "first-capture-is-atomic": .native,
            "session-boundaries": .native,
            "opt-gap": .native,
            "expiry": .native,
            "browser-shared-barrier": .browserOnly(
                "IndexedDB/BroadcastChannel cross-realm barrier is browser-only"
            ),
            "native-background-order": .native,
            "generation-is-not-authority": .native,
            "ambiguous-storage": .native,
        ]
        let scenarioIds = Set(try scenarios.map { try string($0, "id") })
        XCTAssertEqual(scenarioIds, Set(applicability.keys))
        XCTAssertEqual(scenarioIds.count, scenarios.count)

        for scenario in scenarios {
            let identifier = try string(scenario, "id")
            guard let classification = applicability[identifier] else {
                return XCTFail("Unmapped vector scenario: \(identifier)")
            }
            switch classification {
            case .native:
                try await executeNativeScenario(scenario)
            case .nativeStructural:
                try await executeNativeStructuralScenario(scenario)
            case let .browserOnly(reason):
                XCTAssertFalse(reason.isEmpty)
                let realmScoped = try dictionaries(scenario["steps"]).contains {
                    $0["realm"] != nil
                }
                XCTAssertTrue(realmScoped)
            }
        }
    }

    private func executeCanonicalCases(_ canonicalization: [String: Any]) throws {
        XCTAssertEqual(canonicalization["algorithm"] as? String, "elu-canonical-json-v1")
        for testCase in try dictionaries(canonicalization["cases"]) {
            let identifier = try string(testCase, "id")
            let raw = try string(testCase, "raw")
            if testCase["expect"] as? String == "reject" {
                XCTAssertThrowsError(
                    try EluV1StrictCanonicalJSON.parse(Data(raw.utf8)),
                    identifier
                )
                continue
            }
            let parsed = try EluV1StrictCanonicalJSON.parse(Data(raw.utf8))
            let expectedBase64 = try string(testCase, "expectedCanonicalBase64")
            let expectedHash = try string(testCase, "expectedSha256")
            XCTAssertEqual(
                parsed.canonicalData.base64EncodedString(),
                expectedBase64,
                identifier
            )
            XCTAssertEqual(
                EluV1StrictCanonicalJSON.hash(parsed.canonicalData),
                expectedHash,
                identifier
            )
        }
    }

    private func executeNativeScenario(_ scenario: [String: Any]) async throws {
        try await withTemporaryDirectory { root in
            let steps = try dictionaries(scenario["steps"])
            let first = try XCTUnwrap(steps.first)
            let clock = VectorClock(
                wall: try date(try string(first, "wallNow")),
                continuous: try uint64(first, "monotonicNanos")
            )
            let fault = VectorFaultInjector()
            let identifiers = VectorIdentifiers()
            if try string(scenario, "initialState") == "activeSession" {
                try seedActiveSession(root: root)
            }
            var queue = try await openQueue(
                root: root,
                clock: clock,
                fault: fault,
                identifiers: identifiers
            )
            var priorAuthority: EluV1CaptureAuthoritySnapshot?

            for step in steps {
                clock.set(
                    wall: try date(try string(step, "wallNow")),
                    continuous: try uint64(step, "monotonicNanos")
                )
                let expectation = try dictionary(step["expect"])
                let type = try string(step, "type")
                switch type {
                case "submitCandidate":
                    let configName = try string(step, "config")
                    let privacyName = step["privacy"] as? String
                    let privacyData = try privacyName.map { try privacy(named: $0) }
                    let result = await queue.submitCaptureAuthority(
                        configData: try config(named: configName),
                        effectivePrivacyStateData: privacyData
                    )
                    switch result {
                    case let .activated(authority):
                        XCTAssertEqual(expectation["authority"] as? String, "authorized")
                        priorAuthority = authority
                        if let expected = expectation["configSemanticHash"] as? String {
                            XCTAssertEqual(authority.configBoundary.semanticHash, expected)
                        }
                        if let expected = expectation["configSiteId"] as? String {
                            XCTAssertEqual(authority.configSiteId, expected)
                        }
                        if let expected = expectation["namespaceDigest"] as? String {
                            XCTAssertEqual(authority.ownerNamespaceHash, expected)
                        }
                        if let expected = expectation["streamId"] as? String {
                            XCTAssertEqual(authority.streamId, expected)
                        }
                        if let expected = expectation["contextRevision"] as? Int {
                            XCTAssertEqual(authority.contextRevision, Int64(expected))
                        }
                        if let maximum = expectation["monotonicBudgetNoGreaterThanNanos"] as? String {
                            let maximumBudget = try XCTUnwrap(UInt64(maximum))
                            XCTAssertLessThanOrEqual(authority.monotonicBudget, maximumBudget)
                        }
                    case let .terminated(terminal):
                        XCTAssertEqual(expectation["authority"] as? String, "terminal")
                        if let reason = expectation["reason"] as? String {
                            XCTAssertEqual(terminalReason(terminal.reason), reason)
                        }
                    }

                case "capture", "screen":
                    let before = try await queue.snapshot()
                    let attemptsBefore = fault.hitCount(for: .afterStateRead)
                    let result = await queue.capture(
                        try command(
                            kind: type == "screen" ? .screen : .capture,
                            name: try string(step, "name"),
                            occurredAt: clock.wall(),
                            properties: try jsonProperties(step["properties"])
                        )
                    )
                    let expectedAccepted = expectation["accepted"] as? Bool ?? false
                    switch result {
                    case let .accepted(record, snapshot):
                        XCTAssertTrue(expectedAccepted)
                        if let added = expectation["recordsAdded"] as? Int {
                            XCTAssertEqual(snapshot.queuedCount - before.queuedCount, Int64(added))
                        }
                        if expectation["sessionCreated"] as? Bool == true {
                            XCTAssertNil(before.identity.session)
                            XCTAssertNotNil(snapshot.identity.session)
                        }
                        if expectation["sessionRotated"] as? Bool == true {
                            XCTAssertNotEqual(
                                before.identity.session?.id,
                                snapshot.identity.session?.id
                            )
                        }
                        if let lifecycle = expectation["lifecycle"] as? String {
                            XCTAssertEqual(snapshot.identity.session?.lifecycle.rawValue, lifecycle)
                        }
                        if case let .event(event) = record {
                            if let kind = expectation["kind"] as? String {
                                XCTAssertEqual(event.kind.rawValue, kind)
                            }
                            for (key, value) in try jsonProperties(expectation["properties"]) {
                                XCTAssertEqual(event.properties[key], value)
                            }
                            if expectation["reservedVersionPropertiesAuthoritative"] as? Bool == true {
                                XCTAssertEqual(event.properties["$elu_contract_version"], .string("1.0.0"))
                                XCTAssertEqual(event.properties["$elu_sdk_version"], .string("0.1.0"))
                                XCTAssertEqual(event.properties["$elu_facade_version"], .string("0.1.0"))
                            }
                        }
                        if let generation = expectation["generation"] as? Int {
                            XCTAssertEqual(snapshot.generation, Int64(generation))
                        }
                    case let .rejected(reason, snapshot):
                        XCTAssertFalse(expectedAccepted)
                        if let expected = expectation["reason"] as? String {
                            XCTAssertEqual(captureReason(reason), expected)
                        }
                        if let added = expectation["recordsAdded"] as? Int {
                            XCTAssertEqual(snapshot.queuedCount - before.queuedCount, Int64(added))
                        }
                    }
                    if let attempts = expectation["attempts"] as? Int {
                        XCTAssertEqual(
                            fault.hitCount(for: .afterStateRead) - attemptsBefore,
                            attempts
                        )
                    }
                    if expectation["authorityUnchanged"] as? Bool == true,
                       let priorAuthority
                    {
                        let afterAuthority = await queue.captureAuthorityForTesting()
                        XCTAssertEqual(afterAuthority, .authorized(priorAuthority))
                    }

                case "registerSuperProperties":
                    let before = try await queue.snapshot()
                    let snapshot = try await queue.registerStandaloneSuperProperties(
                        try jsonProperties(step["properties"])
                    )
                    try assertMutation(expectation, before: before, after: snapshot)

                case "unregisterSuperProperty":
                    let before = try await queue.snapshot()
                    let snapshot = try await queue.unregisterStandaloneSuperProperty(
                        try string(step, "key")
                    )
                    try assertMutation(expectation, before: before, after: snapshot)

                case "setOptedOut":
                    let before = try await queue.snapshot()
                    let snapshot = try await queue.setOptedOut(
                        try bool(step, "value"),
                        expectedGeneration: before.generation
                    )
                    try assertMutation(expectation, before: before, after: snapshot)
                    if expectation.keys.contains("session") {
                        XCTAssertNil(snapshot.identity.session)
                    }

                case "background":
                    let before = try await queue.snapshot()
                    let result = try await queue.markStandaloneBackgrounded(at: clock.wall())
                    switch result {
                    case let .changed(snapshot):
                        XCTAssertEqual(snapshot.identity.session?.lifecycle.rawValue, "background")
                        XCTAssertEqual(snapshot.queuedCount, before.queuedCount)
                    case let .unchanged(snapshot):
                        XCTAssertTrue(expectation["idempotent"] as? Bool == true)
                        XCTAssertEqual(snapshot, before)
                    case .rejectedOptedOut:
                        XCTFail("Vector background step unexpectedly opted out")
                    }

                case "acknowledgePrefix":
                    let count = try integer(step, "count")
                    let prefix = try await queue.peek(maximumCount: count, maximumBytes: 1_000_000)
                    let references = prefix.map {
                        EluQueueAcknowledgementReference(
                            streamId: beforeStream($0),
                            sequence: $0.sequence,
                            kind: $0.kind,
                            recordId: $0.recordId
                        )
                    }
                    let snapshot = try await queue.acknowledge(references)
                    if let generation = expectation["generation"] as? Int {
                        XCTAssertEqual(snapshot.generation, Int64(generation))
                    }

                case "reopen":
                    await queue.close()
                    queue = try await openQueue(
                        root: root,
                        clock: clock,
                        fault: fault,
                        identifiers: identifiers
                    )
                    let namespaceDigest = try EluV1SiteNamespace.digest(
                        exactConstructorSiteKey: "elu_pk_test_capture"
                    )
                    XCTAssertEqual(
                        namespaceDigest,
                        expectation["namespaceDigest"] as? String
                    )
                    let reopenedAuthority = await queue.captureAuthorityForTesting()
                    XCTAssertEqual(reopenedAuthority, .absent)
                    priorAuthority = nil

                case "injectStorageOutcome":
                    switch try string(step, "outcome") {
                    case "proven-not-committed-once": fault.arm(.provenNotCommittedOnce)
                    case "unknown": fault.arm(.unknown)
                    default: XCTFail("Unknown storage outcome")
                    }

                default:
                    XCTFail("Unimplemented native vector step \(type)")
                }
            }
            await queue.close()
        }
    }

    private func executeNativeStructuralScenario(_ scenario: [String: Any]) async throws {
        let steps = try dictionaries(scenario["steps"])
        let identifier = try string(scenario, "id")
        XCTAssertEqual(identifier, "namespace-and-stream-binding")
        XCTAssertNotNil(steps.last?["authorityOverrideForTest"])
        try await withTemporaryDirectory { root in
            let first = try XCTUnwrap(steps.first)
            let clock = VectorClock(
                wall: try date(try string(first, "wallNow")),
                continuous: try uint64(first, "monotonicNanos")
            )
            let queue = try await openQueue(
                root: root,
                clock: clock,
                fault: VectorFaultInjector(),
                identifiers: VectorIdentifiers()
            )
            guard case let .activated(authority) = await queue.submitCaptureAuthority(
                configData: try config(named: try string(first, "config")),
                effectivePrivacyStateData: try privacy(named: try string(first, "privacy"))
            ) else {
                return XCTFail("Expected structurally bound native authority")
            }
            XCTAssertEqual(
                authority.ownerNamespaceHash,
                "0d28cb28b0d301938550ddaf297a1c9b59a78c1d02534cf2be40aef423d6b943"
            )
            XCTAssertEqual(authority.streamId, "stream_capture_vector")
            // Native exposes no token/override input; the vector's synthetic
            // wrong-authority step is therefore structurally inapplicable.
            XCTAssertEqual(steps.last?["type"] as? String, "capture")
            await queue.close()
        }
    }

    private func assertMutation(
        _ expectation: [String: Any],
        before: EluRuntimeQueueSnapshot,
        after: EluRuntimeQueueSnapshot
    ) throws {
        if let context = expectation["contextRevision"] as? Int {
            XCTAssertEqual(after.identity.contextRevision, Int64(context))
        }
        if let added = expectation["recordsAdded"] as? Int {
            XCTAssertEqual(after.queuedCount - before.queuedCount, Int64(added))
        }
    }

    private func openQueue(
        root: URL,
        clock: VectorClock,
        fault: VectorFaultInjector,
        identifiers: VectorIdentifiers
    ) async throws -> EluSQLiteRuntimeQueue {
        try await EluSQLiteRuntimeQueue.openCaptureRuntime(
            rootDirectoryURL: root,
            exactConstructorSiteKey: "elu_pk_test_capture",
            clock: { clock.wall() },
            continuousClock: { clock.continuous() },
            continuousBudgetConverter: { $0 },
            anonymousIdGenerator: { "anon_capture_vector" },
            streamIdGenerator: { "stream_capture_vector" },
            sessionIdGenerator: { identifiers.nextSessionId() },
            faultInjector: fault
        )
    }

    private func seedActiveSession(root: URL) throws {
        let directory = root.appendingPathComponent(
            try EluV1SiteNamespace.directoryComponent(
                exactConstructorSiteKey: "elu_pk_test_capture"
            ),
            isDirectory: true
        )
        let startedAt = try date("2026-08-04T00:01:00.000Z")
        let lastActivityAt = try date("2026-08-04T00:01:10.000Z")
        let session = try EluSessionState(
            id: "session_existing",
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            timeoutSeconds: 1_800
        )
        let identity = try EluIdentityState(
            revision: 0,
            contextRevision: 0,
            anonymousId: "anon_capture_vector",
            userId: nil,
            groups: [:],
            superProperties: [:],
            session: session,
            optedOut: false,
            updatedAt: lastActivityAt
        )
        let state = try EluPersistedState(
            identity: identity,
            streamMetadata: EluStreamMetadata(streamId: "stream_capture_vector"),
            flagContext: EluPersistedFlagContext()
        )
        try EluFileIdentityStateStore(directoryURL: directory).save(state, mode: .normal)
    }

    private func config(named name: String) throws -> Data {
        switch name {
        case "configEnabledContext0":
            return fixture("config-enabled.json")
        case "configEnabledEquivalentBytes":
            let serialized = try JSONSerialization.data(
                withJSONObject: dictionary(fixture("config-enabled.json")),
                options: [.prettyPrinted, .sortedKeys]
            )
            var result = Data(" \n".utf8)
            result.append(serialized)
            result.append(Data("\n".utf8))
            return result
        case "configEqualIssuedConflict":
            return try mutateConfig("config-enabled.json") { object in
                var session = object["session"] as! [String: Any]
                session["idleTimeoutSeconds"] = 900
                object["session"] = session
            }
        case "configLongLived":
            return try mutateConfig("config-enabled.json") {
                $0["expiresAt"] = "2026-08-06T00:05:00.000Z"
            }
        case "configNewerRevoked":
            return try mutateConfig("config-disabled.json") {
                $0["issuedAt"] = "2026-08-04T00:01:30.000Z"
                $0["expiresAt"] = "2026-08-04T00:06:30.000Z"
                $0["revision"] = "config-revoked-2"
                $0["status"] = "revoked"
            }
        case "configChangedSite":
            return try mutateConfig("config-enabled.json") { object in
                object["issuedAt"] = "2026-08-04T00:01:30.000Z"
                object["expiresAt"] = "2026-08-04T00:06:30.000Z"
                object["revision"] = "config-changed-site"
                var site = object["site"] as! [String: Any]
                site["id"] = "site_other"
                object["site"] = site
            }
        default:
            throw VectorError.invalidVector
        }
    }

    private func privacy(named name: String) throws -> Data {
        let allowed: Bool
        let context: Int
        switch name {
        case "privacyAllowedContext0": (allowed, context) = (true, 0)
        case "privacyAllowedContext1": (allowed, context) = (true, 1)
        case "privacyAllowedContext2": (allowed, context) = (true, 2)
        case "privacyBlockedSameWitness": (allowed, context) = (false, 0)
        case "privacyMalformedDuplicate":
            let valid = try privacy(named: "privacyAllowedContext0")
            var raw = String(decoding: valid, as: UTF8.self)
            raw.removeLast()
            raw += ",\"\\u0063ontextRevision\":0}"
            return Data(raw.utf8)
        default:
            throw VectorError.invalidVector
        }
        let fixtureName = allowed ? "privacy-allowed.json" : "privacy-blocked.json"
        var object = try dictionary(fixture(fixtureName))
        object["policyRevision"] = "privacy-1"
        object["contextRevision"] = context
        object["effectivePolicyHash"] = "sha256:" + String(repeating: "0", count: 64)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        object["effectivePolicyHash"] = try EluV1ConfigManager.computedEffectivePolicyHash(for: data)
        data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data
    }

    private func mutateConfig(
        _ fixtureName: String,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var object = try dictionary(fixture(fixtureName))
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func command(
        kind: EluEventKind,
        name: String,
        occurredAt: Date,
        properties: [String: EluJSONValue]
    ) throws -> EluV1CaptureCommand {
        EluV1CaptureCommand(
            kind: kind,
            name: name,
            occurredAt: occurredAt,
            properties: properties,
            versions: try EluVersionContext(
                runtime: EluVersionComponent(name: "elu-ios", version: "0.1.0"),
                facade: EluVersionComponent(name: "EluAnalytics", version: "0.1.0")
            )
        )
    }

    private func jsonProperties(_ value: Any?) throws -> [String: EluJSONValue] {
        guard let value else { return [:] }
        let object = try dictionary(value)
        return try object.mapValues { raw in
            switch raw {
            case let value as String: return .string(value)
            case let value as Bool: return .bool(value)
            case let value as Int: return .integer(Int64(value))
            default: throw VectorError.invalidVector
            }
        }
    }

    private func captureReason(_ reason: EluV1CaptureRejection) -> String {
        switch reason {
        case .authorityAbsent: "authority-absent"
        case .authorityTerminal: "authority-terminal"
        case .authorityExpired: "authority-expired"
        case .authorityWitnessChanged: "authority-witness-changed"
        case .optedOut: "opted-out"
        case .invalidEvent: "invalid-event"
        case .queueLimit: "queue-limit"
        case .storageProvenNotCommitted: "storage-proven-not-committed"
        case .storageOutcomeUnknown: "storage-outcome-unknown"
        }
    }

    private func terminalReason(_ reason: EluV1CaptureAuthorityTerminalReason) -> String {
        switch reason {
        case .disabled: "disabled"
        case .revoked: "revoked"
        case .privacyBlocked: "privacy-blocked"
        case .malformed: "malformed"
        case .conflict: "conflict"
        case .expired: "expired"
        case .siteChanged: "site-changed"
        case .stale: "stale"
        }
    }

    private func beforeStream(_ record: EluQueuedRecord) -> String {
        if case let .event(event) = record { return event.streamId }
        return "stream_capture_vector"
    }

    private var vectorURL: URL {
        repositoryRoot.appendingPathComponent(
            "Conformance/V1/TestVectors/capture-admission-activity.json"
        )
    }

    private func fixture(_ name: String) -> Data {
        try! Data(
            contentsOf: repositoryRoot
                .appendingPathComponent("Conformance/V1/Fixtures", isDirectory: true)
                .appendingPathComponent(name)
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(EluRFC3339.date(from: value))
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        try dictionary(JSONSerialization.jsonObject(with: data))
    }

    private func dictionaries(_ value: Any?) throws -> [[String: Any]] {
        try XCTUnwrap(value as? [[String: Any]])
    }

    private func string(_ object: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(object[key] as? String)
    }

    private func integer(_ object: [String: Any], _ key: String) throws -> Int {
        try XCTUnwrap(object[key] as? Int)
    }

    private func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        try XCTUnwrap(object[key] as? Bool)
    }

    private func uint64(_ object: [String: Any], _ key: String) throws -> UInt64 {
        try XCTUnwrap(UInt64(try string(object, key)))
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "elu-capture-vector-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private enum VectorError: Error {
    case invalidVector
}

private final class VectorClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wallValue: Date
    private var continuousValue: UInt64

    init(wall: Date, continuous: UInt64) {
        wallValue = wall
        continuousValue = continuous
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

    func set(wall: Date, continuous: UInt64) {
        lock.lock()
        wallValue = wall
        continuousValue = continuous
        lock.unlock()
    }
}

private final class VectorIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue = 0

    func nextSessionId() -> String {
        lock.lock()
        nextValue += 1
        let value = nextValue
        lock.unlock()
        return "session_vector_\(value)"
    }
}

private final class VectorFaultInjector: EluRuntimeQueueFaultInjecting, @unchecked Sendable {
    enum Mode {
        case none
        case provenNotCommittedOnce
        case unknown
    }

    private let lock = NSLock()
    private var mode: Mode = .none
    private var counts: [String: Int] = [:]

    func arm(_ mode: Mode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    func hit(_ point: EluRuntimeQueueFaultPoint) throws {
        lock.lock()
        counts[String(describing: point), default: 0] += 1
        let shouldThrow: Bool
        switch (mode, point) {
        case (.provenNotCommittedOnce, .afterStateRead), (.unknown, .afterCommit):
            shouldThrow = true
            mode = .none
        default:
            shouldThrow = false
        }
        lock.unlock()
        if shouldThrow {
            throw EluRuntimeQueueError.faultInjected(point)
        }
    }

    func hitCount(for point: EluRuntimeQueueFaultPoint) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[String(describing: point), default: 0]
    }
}
