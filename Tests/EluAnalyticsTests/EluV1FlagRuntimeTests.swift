import Foundation
import SQLite3
import XCTest
@testable import EluAnalytics

final class EluV1FlagRuntimeTests: XCTestCase {
    private let siteKey = "elu_pk_test_flags"
    private let initialWall = Date(timeIntervalSince1970: 1_785_801_660) // 00:01:00Z

    private struct ProductionActivityState {
        let root: URL
        let database: URL
        let clock: FlagTestClock
        let runtime: EluSQLiteRuntimeQueue
        let client: EluV1FlagClient
        let versions: EluVersionContext
        var tokens: [String: EluV1FlagBegunRequest] = [:]
    }

    func testFrozenActivityVectorDrivesCanonicalizationOracle() throws {
        let vectorData = try Data(contentsOf: vectorURL())
        XCTAssertEqual(vectorData.count, 22_684)
        XCTAssertEqual(
            EluV1FlagJSON.hash(vectorData),
            "sha256:dbceaa7bee48caf8bf54b73e494fb3f28460eeaf366bbe26f606b659c62a47c4"
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: vectorData) as? [String: Any]
        )
        let canonicalization = try XCTUnwrap(root["canonicalization"] as? [String: Any])
        let cases = try XCTUnwrap(canonicalization["cases"] as? [[String: Any]])
        for item in cases {
            let raw = try XCTUnwrap(item["raw"] as? String)
            if item["expect"] as? String == "reject" {
                XCTAssertThrowsError(try EluV1FlagJSON.parse(Data(raw.utf8)), item["id"] as? String ?? "")
            } else {
                let expected = try XCTUnwrap(item["expectedCanonicalBase64"] as? String)
                let value = try EluV1FlagJSON.parse(Data(raw.utf8))
                XCTAssertEqual(
                    try EluV1FlagJSON.canonicalData(for: value),
                    Data(base64Encoded: expected),
                    item["id"] as? String ?? ""
                )
            }
        }
        let requestOracle = try XCTUnwrap(root["requestOracle"] as? [String: Any])
        let requestBytes = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(requestOracle["canonicalBase64"] as? String))
        )
        XCTAssertEqual(
            EluV1FlagJSON.hash(requestBytes),
            requestOracle["canonicalSha256"] as? String
        )
        let oracleValue = try EluV1FlagJSON.parse(requestBytes)
        let nativeRequest = try EluV1FlagCodec.makeRequest(
            requestId: "flags_request_1",
            witness: try makeWitness()
        )
        let nativeValue = try EluV1FlagJSON.parse(nativeRequest.canonicalData)
        let versionsKey = Array("versions".utf16)
        guard case let .object(oracleMembers) = oracleValue,
              case let .object(nativeMembers) = nativeValue
        else {
            return XCTFail("request oracle must be an object")
        }
        XCTAssertEqual(
            try EluV1FlagJSON.canonicalData(
                for: .object(oracleMembers.filter { $0.name != versionsKey })
            ),
            try EluV1FlagJSON.canonicalData(
                for: .object(nativeMembers.filter { $0.name != versionsKey })
            )
        )

        let invalidUTF8Cases = try XCTUnwrap(root["invalidUtf8Cases"] as? [[String: Any]])
        XCTAssertEqual(
            Set(invalidUTF8Cases.compactMap { $0["id"] as? String }),
            Set(["invalid-continuation-byte", "leading-utf8-bom"])
        )
        for item in invalidUTF8Cases {
            let identifier = try XCTUnwrap(item["id"] as? String)
            let bytes = try XCTUnwrap(
                Data(base64Encoded: try XCTUnwrap(item["rawBase64"] as? String))
            )
            XCTAssertThrowsError(try EluV1FlagJSON.parse(bytes), identifier)
        }
    }

    func testFrozenActivityScenariosExecuteEveryStepAndExpectation() async throws {
        let data = try Data(contentsOf: vectorURL())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let vector = try FlagActivityVectorInterpreter(
            root: root,
            fixturesURL: fixturesURL()
        )
        XCTAssertEqual(
            try await runProductionActivityVector(vector),
            Set([
                "install-and-read-complete-snapshot",
                "empty-snapshot-replaces",
                "context-change-drops-response",
                "older-completion-cannot-overwrite-newer-begin",
                "cache-expiry-retains-config-barrier",
                "config-expiry-is-durable-restriction",
                "newer-revoke-rejects-old-completion",
                "cache-corruption-rotates-only-request-epoch",
                "authority-corruption-is-terminal",
                "future-schema-is-preserved",
            ])
        )
    }

    func testFrozenActivityScenarioExpectationMutationIsDetected() async throws {
        let original = try Data(contentsOf: vectorURL())
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original) as? [String: Any]
        )
        let mutatedData = try JSONSerialization.data(withJSONObject: root)
        var mutated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mutatedData) as? [String: Any]
        )
        var scenarios = try XCTUnwrap(mutated["scenarios"] as? [[String: Any]])
        var first = try XCTUnwrap(scenarios.first)
        var steps = try XCTUnwrap(first["steps"] as? [[String: Any]])
        var apply = try XCTUnwrap(steps.first)
        var expectation = try XCTUnwrap(apply["expect"] as? [String: Any])
        expectation["authorization"] = "restricted"
        apply["expect"] = expectation
        steps[0] = apply
        first["steps"] = steps
        scenarios[0] = first
        mutated["scenarios"] = scenarios

        let vector = try FlagActivityVectorInterpreter(
            root: mutated,
            fixturesURL: fixturesURL()
        )
        do {
            _ = try await runProductionActivityVector(vector)
            XCTFail("mutated production expectation must fail")
        } catch is FlagActivityVectorError {
            // The production-backed comparison consumed the mutated leaf.
        }
    }

    private func runProductionActivityVector(
        _ vector: FlagActivityVectorInterpreter
    ) async throws -> Set<String> {
        var executed: Set<String> = []
        for scenario in vector.productionScenarios {
            guard let identifier = scenario["id"] as? String else {
                throw FlagActivityVectorError.invalid("scenario without id")
            }
            try await withTemporaryDirectory { root in
                var state = try await self.makeProductionActivityState(
                    root: root,
                    vector: vector
                )
                try await self.executeProductionScenario(
                    identifier,
                    vector: vector,
                    state: &state,
                    stack: []
                )
                await state.runtime.close()
            }
            executed.insert(identifier)
        }
        return executed
    }

    private func makeProductionActivityState(
        root: URL,
        vector: FlagActivityVectorInterpreter
    ) async throws -> ProductionActivityState {
        let clock = FlagTestClock(initialWall)
        let versions = try self.versions()
        try await seedProductionActivityIdentity(
            root: root,
            clock: clock,
            versions: versions
        )
        let epochs = FlagTestStoreEpochs()
        let runtime = try await makeRuntime(
            root: root,
            clock: clock,
            flagStoreEpochGenerator: { epochs.next() }
        )
        let client = try await EluV1FlagClient.make(
            runtime: runtime,
            transport: ImmediateFlagTransport(),
            versions: versions
        )
        let database = try databaseURL(root: root)
        let state = ProductionActivityState(
            root: root,
            database: database,
            clock: clock,
            runtime: runtime,
            client: client,
            versions: versions
        )
        try await verifyProductionInitialState(state, vector: vector)
        return state
    }

    private func seedProductionActivityIdentity(
        root: URL,
        clock: FlagTestClock,
        versions: EluVersionContext
    ) async throws {
        let directory = try siteDirectoryURL(root: root)
        let runtime = try await EluSQLiteRuntimeQueue.open(
            directoryURL: directory,
            clock: { clock.now() },
            anonymousIdGenerator: { "anon_flags_1" },
            streamIdGenerator: { "stream_flags_1" },
            sessionIdGenerator: { "session_flags_1" }
        )
        var snapshot = try await runtime.snapshot()
        _ = try await runtime.applyMutation(
            .identify(
                userId: "user_123",
                set: [
                    "plan": .string("growth"),
                    "role": .string("owner"),
                ],
                setOnce: [:]
            ),
            versions: versions,
            expectedGeneration: snapshot.generation
        )
        snapshot = try await runtime.snapshot()
        _ = try await runtime.applyMutation(
            .group(
                groupType: "organization",
                groupKey: "org_456",
                set: ["tier": .string("design-partner")],
                setOnce: [:],
                unset: []
            ),
            versions: versions,
            expectedGeneration: snapshot.generation
        )
        for index in 1 ... 4 {
            snapshot = try await runtime.snapshot()
            _ = try await runtime.applyMutation(
                .linkAlias(aliasId: "vector_alias_\(index)"),
                versions: versions,
                expectedGeneration: snapshot.generation
            )
        }
        await runtime.close()
    }

    private func verifyProductionInitialState(
        _ state: ProductionActivityState,
        vector: FlagActivityVectorInterpreter
    ) async throws {
        let snapshot = try await state.runtime.snapshot()
        let authority = try EluV1FlagStorageCodec.decodeAuthority(
            flagAuthorityBody(state.database)
        )
        let actual: [String: Any] = [
            "identity": [
                "anonymousId": snapshot.identity.anonymousId,
                "userId": snapshot.identity.userId as Any? ?? NSNull(),
                "revision": snapshot.identity.revision,
            ],
            "contextRevision": snapshot.identity.contextRevision,
            "optedOut": snapshot.identity.optedOut,
            "personProperties": foundationJSON(snapshot.flagContext.personProperties),
            "groups": snapshot.identity.groups,
            "groupProperties": foundationJSON(snapshot.flagContext.groupProperties),
            "authority": [
                "initialized": authority.initialized,
                "barrierGeneration": authority.barrierGeneration,
                "lastObservedWall": authority.lastObservedWall as Any? ?? NSNull(),
            ],
            "cache": NSNull(),
        ]
        try vector.compareProductionValue(
            vector.productionInitialState,
            actual: actual,
            context: "initialState"
        )
    }

    private func executeProductionScenario(
        _ identifier: String,
        vector: FlagActivityVectorInterpreter,
        state: inout ProductionActivityState,
        stack: [String]
    ) async throws {
        guard !stack.contains(identifier),
              let scenario = vector.productionScenario(named: identifier),
              let steps = scenario["steps"] as? [[String: Any]]
        else {
            throw FlagActivityVectorError.invalid("unknown or recursive scenario \(identifier)")
        }
        let nextStack = stack + [identifier]
        for (index, step) in steps.enumerated() {
            try await executeProductionStep(
                step,
                vector: vector,
                state: &state,
                scenario: identifier,
                index: index,
                stack: nextStack
            )
        }
    }

    private func executeProductionStep(
        _ step: [String: Any],
        vector: FlagActivityVectorInterpreter,
        state: inout ProductionActivityState,
        scenario: String,
        index: Int,
        stack: [String]
    ) async throws {
        guard let type = step["type"] as? String else {
            throw FlagActivityVectorError.invalid("\(scenario)[\(index)] has no type")
        }
        let context = "\(scenario)[\(index)] \(type)"
        switch type {
        case "seedScenario":
            try requireActivityKeys(step, exactly: ["scenario", "type"], context: context)
            guard let seed = step["scenario"] as? String else {
                throw FlagActivityVectorError.invalid("\(context) has no seed")
            }
            try await executeProductionScenario(
                seed,
                vector: vector,
                state: &state,
                stack: stack
            )

        case "applyConfig":
            try requireActivityKeys(
                step,
                exactly: ["config", "expect", "type", "wallNow"],
                context: context
            )
            guard let name = step["config"] as? String,
                  let wall = step["wallNow"] as? String
            else {
                throw FlagActivityVectorError.invalid("\(context) has invalid inputs")
            }
            state.clock.set(try EluV1Timestamp(wall).date)
            let data = try vector.productionDocumentData(named: name, kind: "config")
            let authorization = await state.client.applyConfig(data)
            let authority = try EluV1FlagStorageCodec.decodeAuthority(
                flagAuthorityBody(state.database)
            )
            var actual: [String: Any] = [
                "barrierGeneration": authority.barrierGeneration,
            ]
            switch authorization {
            case .allowed:
                actual["authorization"] = "allowed"
            case let .restricted(restriction):
                actual["authorization"] = "restricted"
                actual["reason"] = activityRestriction(restriction)
            }
            if let observed = authority.lastObservedWall {
                actual["lastObservedWall"] = activityTimestamp(try observed.validated())
            }
            try vector.compareProductionExpectation(step, actual: actual, context: context)

        case "beginReload":
            try requireActivityKeys(
                step,
                required: ["expect", "requestId", "type", "wallNow"],
                optional: ["realm", "storeEpoch"],
                context: context
            )
            guard let requestId = step["requestId"] as? String,
                  let wall = step["wallNow"] as? String
            else {
                throw FlagActivityVectorError.invalid("\(context) has invalid inputs")
            }
            state.clock.set(try EluV1Timestamp(wall).date)
            let beforeRows = try completeFlagRows(state.database)
            let beforeAuthority = try? EluV1FlagStorageCodec.decodeAuthority(
                flagAuthorityBody(state.database)
            )
            let result = await state.runtime.beginFlagReload(
                requestId: requestId,
                versions: state.versions
            )
            let afterRows = try completeFlagRows(state.database)
            var actual: [String: Any]
            switch result {
            case let .begun(request):
                let realm = step["realm"] as? String ?? requestId
                state.tokens[realm] = request
                actual = [
                    "result": "begun",
                    "requestGeneration": request.token.requestGeneration,
                    "barrierGeneration": request.token.barrierGeneration,
                    "storeEpoch": request.token.storeEpoch,
                ]
                if let expected = step["expect"] as? [String: Any],
                   expected["requestCanonicalSha256"] != nil
                {
                    actual["requestCanonicalSha256"] = try activityRequestOracleHash(
                        request.request.canonicalData,
                        oracle: vector.productionRequestOracle
                    )
                }
                if let beforeAuthority,
                   let afterAuthority = try? EluV1FlagStorageCodec.decodeAuthority(
                       flagAuthorityBody(state.database)
                   )
                {
                    actual["authorityPreserved"] = activityAuthorityProjection(beforeAuthority)
                        == activityAuthorityProjection(afterAuthority)
                }

            case let .restricted(restriction):
                actual = [
                    "result": "restricted",
                    "restriction": activityRestriction(restriction),
                ]
                if let authority = try? EluV1FlagStorageCodec.decodeAuthority(
                    flagAuthorityBody(state.database)
                ) {
                    actual["barrierGeneration"] = authority.barrierGeneration
                }

            case .terminal:
                actual = [
                    "result": "terminal",
                    "storageMutation": beforeRows != afterRows,
                    "futureRecordPreservedByteForByte": beforeRows == afterRows
                        && beforeRows.contains(where: { $0.contains("request|0|2|") }),
                    "bodyMaterialized": false,
                ]
            }
            try vector.compareProductionExpectation(step, actual: actual, context: context)

        default:
            try await executeProductionNonBeginStep(
                step,
                type: type,
                vector: vector,
                state: &state,
                context: context
            )
        }
    }

    private func executeProductionNonBeginStep(
        _ step: [String: Any],
        type: String,
        vector: FlagActivityVectorInterpreter,
        state: inout ProductionActivityState,
        context: String
    ) async throws {
        switch type {
        case "completeReload":
            try requireActivityKeys(
                step,
                required: ["expect", "requestId", "response", "type", "wallNow"],
                optional: ["realm"],
                context: context
            )
            guard let requestId = step["requestId"] as? String,
                  let responseName = step["response"] as? String,
                  let wall = step["wallNow"] as? String
            else {
                throw FlagActivityVectorError.invalid("\(context) has invalid inputs")
            }
            let realm = step["realm"] as? String ?? requestId
            guard let begun = state.tokens[realm], begun.token.requestId == requestId else {
                throw FlagActivityVectorError.invalid("\(context) has no matching token")
            }
            state.clock.set(try EluV1Timestamp(wall).date)
            let responseData = try vector.productionDocumentData(
                named: responseName,
                kind: "flagsResponse"
            )
            let responseObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            )
            let responseRequestId = try XCTUnwrap(responseObject["requestId"] as? String)
            let decodingRequest = try EluV1FlagCodec.makeRequest(
                requestId: responseRequestId,
                witness: begun.token.witness
            )
            let response = try EluV1FlagCodec.decodeResponse(
                responseData,
                for: decodingRequest
            )
            let result = await state.runtime.commitFlagReload(
                token: begun.token,
                response: response
            )
            let requestState = try? EluV1FlagStorageCodec.decodeRequestState(
                flagRequestMetadataBody(state.database)
            )
            var actual: [String: Any]
            switch result {
            case .updated:
                actual = [
                    "result": "updated",
                    "flagsRevision": response.flagsRevision,
                    "flagCount": response.flags.count,
                    "payloadCount": response.payloads.count,
                ]
            case .stale:
                actual = [
                    "result": "stale",
                    "cache": requestState?.cacheRecordId as Any? ?? NSNull(),
                ]
            case let .restricted(restriction):
                actual = [
                    "result": "restricted",
                    "restriction": activityRestriction(restriction),
                ]
            case .terminal:
                actual = ["result": "terminal"]
            }
            if let requestState {
                actual["requestGeneration"] = requestState.requestGeneration
            }
            try vector.compareProductionExpectation(step, actual: actual, context: context)

        case "readAll":
            try requireActivityKeys(
                step,
                exactly: ["expect", "type", "wallNow"],
                context: context
            )
            guard let wall = step["wallNow"] as? String,
                  let expectation = step["expect"] as? [String: Any]
            else {
                throw FlagActivityVectorError.invalid("\(context) has invalid inputs")
            }
            state.clock.set(try EluV1Timestamp(wall).date)
            let result = await state.client.readAll()
            let authority = try EluV1FlagStorageCodec.decodeAuthority(
                flagAuthorityBody(state.database)
            )
            let requestState = try? EluV1FlagStorageCodec.decodeRequestState(
                flagRequestMetadataBody(state.database)
            )
            var actual: [String: Any] = [
                "barrierGeneration": authority.barrierGeneration,
                "requestGeneration": requestState?.requestGeneration as Any? ?? NSNull(),
                "activeRequestId": requestState?.activeRequestId as Any? ?? NSNull(),
            ]
            switch result {
            case let .hit(snapshot):
                actual["status"] = "hit"
                for key in expectation.keys where ![
                    "activeRequestId", "barrierGeneration", "requestGeneration", "status",
                ].contains(key) {
                    if key == "orphanPayloadExposed" {
                        actual[key] = snapshot.lookup("orphan") != .missing
                    } else {
                        actual[key] = foundationJSON(snapshot.lookup(key))
                    }
                }
            case .miss:
                actual["status"] = "miss"
            case let .restricted(restriction):
                actual["status"] = "restricted"
                actual["restriction"] = activityRestriction(restriction)
            case .terminal:
                actual["status"] = "terminal"
            }
            try vector.compareProductionExpectation(step, actual: actual, context: context)

        case "setPersonProperties":
            try requireActivityKeys(
                step,
                exactly: ["expect", "set", "type", "wallNow"],
                context: context
            )
            guard let wall = step["wallNow"] as? String,
                  let rawProperties = step["set"] as? [String: Any]
            else {
                throw FlagActivityVectorError.invalid("\(context) has invalid inputs")
            }
            let properties = try rawProperties.mapValues { value -> EluJSONValue in
                guard let string = value as? String else {
                    throw FlagActivityVectorError.invalid("\(context) property is not a string")
                }
                return .string(string)
            }
            state.clock.set(try EluV1Timestamp(wall).date)
            let before = try await state.runtime.snapshot()
            let after = try await state.runtime.setFlagPersonProperties(
                properties,
                versions: state.versions,
                expectedGeneration: before.generation
            )
            try vector.compareProductionExpectation(
                step,
                actual: ["contextRevision": after.identity.contextRevision],
                context: context
            )

        case "injectCacheCorruption":
            try requireActivityKeys(step, exactly: ["kind", "type"], context: context)
            guard step["kind"] as? String == "digest-mismatch" else {
                throw FlagActivityVectorError.invalid("\(context) invalid cache corruption")
            }
            try executeSQL(
                state.database,
                "UPDATE flag_cache_records SET body_sha256 = 'sha256:"
                    + String(repeating: "0", count: 64)
                    + "' WHERE record_type = 'request' AND record_index = 0"
            )

        case "injectAuthorityCorruption":
            try requireActivityKeys(step, exactly: ["kind", "type"], context: context)
            guard step["kind"] as? String == "missing-after-initialized" else {
                throw FlagActivityVectorError.invalid("\(context) invalid authority corruption")
            }
            try executeSQL(
                state.database,
                "DELETE FROM flag_cache_records "
                    + "WHERE record_type = 'authority' AND record_index = 0"
            )

        case "injectFutureCacheRecord":
            try requireActivityKeys(
                step,
                exactly: ["declaredBodyBytes", "storageSchemaVersion", "type"],
                context: context
            )
            guard let declared = activityInteger(step["declaredBodyBytes"]),
                  let schema = activityInteger(step["storageSchemaVersion"]),
                  declared > Int64(EluV1FlagJSON.maximumCacheBytes),
                  schema > Int64(EluV1FlagRequestCacheState.storageSchema)
            else {
                throw FlagActivityVectorError.invalid("\(context) invalid future record")
            }
            try executeSQL(
                state.database,
                "INSERT INTO flag_cache_records (record_type, record_index, storage_schema, "
                    + "initialized, declared_body_bytes, body_sha256, chunk_count, body) "
                    + "VALUES ('request', 0, \(schema), 1, \(declared), "
                    + "'future-schema-opaque', 1, X'7B7D')"
            )

        default:
            throw FlagActivityVectorError.invalid("\(context) unknown operation")
        }
    }

    private func siteDirectoryURL(root: URL) throws -> URL {
        let digest = try EluV1SiteNamespace.digest(exactConstructorSiteKey: siteKey)
        return root.appendingPathComponent("site-\(digest)", isDirectory: true)
    }

    private func activityRestriction(_ restriction: EluV1FlagRestriction) -> String {
        switch restriction {
        case .featureDisabled: "feature-disabled"
        case .wallRollback: "wall-rollback"
        case .storageUnavailable: "storage-unavailable"
        case .expired: "config-expired"
        default: restriction.rawValue
        }
    }

    private func activityTimestamp(_ timestamp: EluV1Timestamp) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: timestamp.date)
    }

    private func activityAuthorityProjection(
        _ authority: EluV1FlagDurableAuthority
    ) -> [String] {
        [
            authority.ordering?.source ?? "<nil>",
            authority.semanticHash ?? "<nil>",
            authority.siteId ?? "<nil>",
            authority.configRevision ?? "<nil>",
            authority.endpoint ?? "<nil>",
            authority.configExpiresAt?.source ?? "<nil>",
        ]
    }

    private func activityRequestOracleHash(
        _ productionRequest: Data,
        oracle: [String: Any]
    ) throws -> String {
        guard let encoded = oracle["canonicalBase64"] as? String,
              let oracleData = Data(base64Encoded: encoded),
              let expectedHash = oracle["canonicalSha256"] as? String,
              EluV1FlagJSON.hash(oracleData) == expectedHash
        else {
            throw FlagActivityVectorError.invalid("invalid request oracle")
        }
        let production = try EluV1FlagJSON.parse(productionRequest)
        let expected = try EluV1FlagJSON.parse(oracleData)
        let versions = Array("versions".utf16)
        guard case let .object(productionMembers) = production,
              case let .object(expectedMembers) = expected
        else {
            throw FlagActivityVectorError.invalid("request oracle is not an object")
        }
        let productionComparable = try EluV1FlagJSON.canonicalData(
            for: .object(productionMembers.filter { $0.name != versions })
        )
        let expectedComparable = try EluV1FlagJSON.canonicalData(
            for: .object(expectedMembers.filter { $0.name != versions })
        )
        return productionComparable == expectedComparable
            ? expectedHash
            : EluV1FlagJSON.hash(productionRequest)
    }

    private func foundationJSON(_ values: [String: EluJSONValue]) -> [String: Any] {
        values.mapValues(foundationJSON)
    }

    private func foundationJSON(
        _ values: [String: [String: EluJSONValue]]
    ) -> [String: Any] {
        values.mapValues { foundationJSON($0) }
    }

    private func foundationJSON(_ value: EluJSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case let .bool(value): value
        case let .integer(value): value
        case let .number(value): value
        case let .string(value): value
        case let .array(values): values.map(foundationJSON)
        case let .object(values): values.mapValues(foundationJSON)
        }
    }

    private func foundationJSON(_ value: EluV1FlagJSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case let .bool(value): value
        case let .number(value): value
        case let .string(value): String(decoding: value, as: UTF16.self)
        case let .array(values): values.map(foundationJSON)
        case let .object(members): Dictionary(
            uniqueKeysWithValues: members.map {
                (String(decoding: $0.name, as: UTF16.self), foundationJSON($0.value))
            }
        )
        }
    }

    private func foundationJSON(_ lookup: EluV1FlagLookup) -> [String: Any] {
        switch lookup {
        case .missing:
            return ["status": "missing"]
        case let .found(value, payload):
            var result: [String: Any] = [
                "status": "found",
                "value": foundationJSON(value.jsonValue),
            ]
            if let payload { result["payload"] = foundationJSON(payload) }
            return result
        }
    }

    private func activityInteger(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private func requireActivityKeys(
        _ value: [String: Any],
        exactly keys: Set<String>,
        context: String
    ) throws {
        guard Set(value.keys) == keys else {
            throw FlagActivityVectorError.invalid("\(context) has unconsumed fields")
        }
    }

    private func requireActivityKeys(
        _ value: [String: Any],
        required: Set<String>,
        optional: Set<String>,
        context: String
    ) throws {
        let actual = Set(value.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
            throw FlagActivityVectorError.invalid("\(context) has missing/unconsumed fields")
        }
    }

    func testStrictASTPreservesRawUTF16KeysAndDistinctNullishValues() throws {
        let value = try EluV1FlagJSON.parse(
            Data(#"{"é":false,"é":null,"zero":-0,"empty":"","__proto__":1}"#.utf8)
        )
        let members = try XCTUnwrap(value.objectMembers)
        XCTAssertEqual(members.count, 5)
        XCTAssertNotEqual(Array("é".utf16), Array("é".utf16))
        XCTAssertEqual(value.property(units: Array("é".utf16)), .bool(false))
        XCTAssertEqual(value.property(units: Array("é".utf16)), .null)
        guard case let .number(zero)? = value.property("zero") else {
            return XCTFail("expected numeric zero")
        }
        XCTAssertEqual(zero, 0)
        XCTAssertEqual(zero.sign, .plus)
        XCTAssertEqual(value.property("empty"), .string([]))
        XCTAssertEqual(value.property("__proto__"), .number(1))
        XCTAssertThrowsError(
            try EluV1FlagJSON.parse(Data(#"{"a":1,"\u0061":2}"#.utf8))
        )
    }

    func testStrictASTRejectsBOMInvalidUTF8UnsafeIntegersAndBudgetOverflow() throws {
        var bomPrefixed = Data([0xEF, 0xBB, 0xBF])
        bomPrefixed.append(contentsOf: Data("{}".utf8))
        XCTAssertThrowsError(
            try EluV1FlagJSON.parse(bomPrefixed)
        )
        XCTAssertThrowsError(
            try EluV1FlagJSON.parse(Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xC3, 0x28, 0x22, 0x7D]))
        )
        XCTAssertThrowsError(
            try EluV1FlagJSON.parse(Data(#"{"value":9007199254740992}"#.utf8))
        )
        for unsafeBinary64 in [
            #"{"value":9.007199254740992e15}"#,
            #"{"value":9007199254740992.0}"#,
            #"{"value":9007199254740991.5}"#,
        ] {
            XCTAssertThrowsError(
                try EluV1FlagJSON.parse(Data(unsafeBinary64.utf8)),
                unsafeBinary64
            )
        }
        XCTAssertNoThrow(
            try EluV1FlagJSON.parse(
                Data(#"{"value":1.7976931348623157e308}"#.utf8)
            )
        )
        let tooDeep = String(repeating: "[", count: 17) + "0"
            + String(repeating: "]", count: 17)
        XCTAssertThrowsError(try EluV1FlagJSON.parse(Data(tooDeep.utf8)))
        let exactDepth = String(repeating: "[", count: 16) + "0"
            + String(repeating: "]", count: 16)
        XCTAssertNoThrow(try EluV1FlagJSON.parse(Data(exactDepth.utf8)))

        let tooManyEntries = "[" + Array(repeating: "0", count: 1_025).joined(separator: ",") + "]"
        XCTAssertThrowsError(try EluV1FlagJSON.parse(Data(tooManyEntries.utf8)))
        let tooLongKey = "{\"" + String(repeating: "k", count: 257) + "\":true}"
        XCTAssertThrowsError(try EluV1FlagJSON.parse(Data(tooLongKey.utf8)))
        let tooLongString = "\"" + String(repeating: "v", count: 65_537) + "\""
        XCTAssertThrowsError(try EluV1FlagJSON.parse(Data(tooLongString.utf8)))

        let fullInner = "[" + Array(repeating: "0", count: 1_024).joined(separator: ",") + "]"
        let exactTail = "[" + Array(repeating: "0", count: 1_019).joined(separator: ",") + "]"
        let overTail = "[" + Array(repeating: "0", count: 1_020).joined(separator: ",") + "]"
        let exactNodes = "[\(fullInner),\(fullInner),\(fullInner),\(exactTail)]"
        let tooManyNodes = "[\(fullInner),\(fullInner),\(fullInner),\(overTail)]"
        XCTAssertNoThrow(try EluV1FlagJSON.parse(Data(exactNodes.utf8)))
        XCTAssertThrowsError(try EluV1FlagJSON.parse(Data(tooManyNodes.utf8)))

        let base = Data("{}".utf8)
        var exact = base
        exact.append(Data(repeating: 0x20, count: EluV1FlagJSON.maximumWireBytes - base.count))
        XCTAssertNoThrow(try EluV1FlagJSON.parse(exact))
        exact.append(0x20)
        XCTAssertThrowsError(try EluV1FlagJSON.parse(exact))
    }

    func testResponseRequiresClosedEchoedExactContract() throws {
        let witness = try makeWitness()
        let request = try EluV1FlagCodec.makeRequest(requestId: "flags_request", witness: witness)
        let valid = try response(for: request.canonicalData)
        let decoded = try EluV1FlagCodec.decodeResponse(valid, for: request)
        XCTAssertEqual(decoded.flag(units: Array("enabled".utf16)), .bool(false))
        XCTAssertEqual(decoded.flag(units: Array("zero".utf16)), .number(0))
        XCTAssertEqual(decoded.flag(units: Array("nothing".utf16)), .null)
        XCTAssertNil(decoded.flag(units: Array("missing".utf16)))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["unknown"] = true
        XCTAssertThrowsError(
            try EluV1FlagCodec.decodeResponse(
                JSONSerialization.data(withJSONObject: object),
                for: request
            )
        )
        object.removeValue(forKey: "unknown")
        object["requestId"] = "wrong"
        XCTAssertThrowsError(
            try EluV1FlagCodec.decodeResponse(
                JSONSerialization.data(withJSONObject: object),
                for: request
            )
        )
    }

    func testFutureCacheSchemaIsDetectedBeforeCurrentClosedShapeValidation() {
        XCTAssertThrowsError(
            try EluV1FlagCodec.decodeCache(
                Data(#"{"schemaVersion":2,"futureField":{"opaque":true}}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? EluV1FlagContractError,
                .unsupportedSchemaVersion
            )
        }
        let normalizationDistinct = Data(
            #"{"schemaVersion":2,"é":1,"é":2}"#.utf8
        )
        XCTAssertTrue(
            EluV1FlagJSON.declaresFutureTopLevelSchema(normalizationDistinct)
        )
        XCTAssertThrowsError(try EluV1FlagCodec.decodeCache(normalizationDistinct)) { error in
            XCTAssertEqual(error as? EluV1FlagContractError, .unsupportedSchemaVersion)
        }
    }

    func testCacheEnvelopeByteCeilingAcceptsExactMaximumAndRejectsOneMore() throws {
        let full = EluV1FlagJSONValue.string(
            Array(repeating: UInt16(0x61), count: 65_536)
        )
        let exactTail = EluV1FlagJSONValue.string(
            Array(repeating: UInt16(0x62), count: 65_343)
        )
        let overTail = EluV1FlagJSONValue.string(
            Array(repeating: UInt16(0x62), count: 65_344)
        )
        let exactValue = EluV1FlagJSONValue.array(
            Array(repeating: full, count: 63) + [exactTail]
        )
        let exact = try EluV1FlagJSON.canonicalData(
            for: exactValue,
            maximumBytes: EluV1FlagJSON.maximumCacheBytes
        )
        XCTAssertEqual(exact.count, EluV1FlagJSON.maximumCacheBytes)
        let overValue = EluV1FlagJSONValue.array(
            Array(repeating: full, count: 63) + [overTail]
        )
        XCTAssertThrowsError(
            try EluV1FlagJSON.canonicalData(
                for: overValue,
                maximumBytes: EluV1FlagJSON.maximumCacheBytes
            )
        )
    }

    func testFlagSchemaMigrationIsExplicitLazyAndAdditive() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            let initial = try await runtime.snapshot()
            await runtime.close()
            let database = try self.databaseURL(root: root)
            XCTAssertEqual(try self.userVersion(database), 1)
            XCTAssertEqual(try self.tableNames(database), ["queue_records", "runtime_state"])

            runtime = try await self.makeRuntime(root: root, clock: clock)
            await runtime.close()
            XCTAssertEqual(try self.userVersion(database), 1)
            XCTAssertEqual(try self.tableNames(database), ["queue_records", "runtime_state"])

            runtime = try await self.makeRuntime(root: root, clock: clock)
            _ = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            let migratedSnapshot = try await runtime.snapshot()
            XCTAssertEqual(migratedSnapshot, initial)
            await runtime.close()
            XCTAssertEqual(try self.userVersion(database), 2)
            XCTAssertEqual(
                try self.tableNames(database),
                ["flag_cache_records", "queue_records", "runtime_state"]
            )
            XCTAssertEqual(try self.runtimeRecordSchema(database), 1)
            let before = try self.flagRows(database)

            runtime = try await self.makeRuntime(root: root, clock: clock)
            let reopenedSnapshot = try await runtime.snapshot()
            XCTAssertEqual(reopenedSnapshot, initial)
            await runtime.close()
            XCTAssertEqual(try self.flagRows(database), before)
        }
    }

    func testLazyUninitializedAuthorityBindsExactSiteAndRejectsNamespaceCollision() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            _ = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            await runtime.close()

            let database = try self.databaseURL(root: root)
            var authority = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertFalse(authority.initialized)
            XCTAssertEqual(authority.exactConstructorSiteKey, self.siteKey)
            XCTAssertEqual(
                authority.siteNamespaceDigest,
                try EluV1SiteNamespace.digest(exactConstructorSiteKey: self.siteKey)
            )

            // Model a digest collision by changing only the exact constructor
            // key in the row while retaining the namespace directory/digest.
            authority.exactConstructorSiteKey = "elu_pk_synthetic_collision"
            let collisionBody = try EluV1FlagStorageCodec.encodeAuthority(authority)
            try self.updateFlagAuthorityBody(database, collisionBody)

            runtime = try await self.makeRuntime(root: root, clock: clock)
            var collisionError: Error?
            do {
                _ = try await EluV1FlagClient.make(
                    runtime: runtime,
                    transport: ImmediateFlagTransport(),
                    versions: try self.versions()
                )
            } catch {
                collisionError = error
            }
            XCTAssertEqual(collisionError as? EluRuntimeQueueError, .corruptStorage)
            await runtime.close()
            XCTAssertEqual(try self.flagAuthorityBody(database), collisionBody)
        }
    }

    func testFlagProjectionValidatesOnlyTheFlagsEndpointRole() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )

            let minimalProjection = try JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 1,
                    "revision": "config-flags-minimal",
                    "issuedAt": "2026-08-04T00:00:00.000Z",
                    "expiresAt": "2026-08-04T00:05:00.000Z",
                    "status": "enabled",
                    "site": ["id": "site_demo"],
                    "endpoints": [
                        "flags": "https://ingest.elu.dev/v1/flags",
                    ],
                    "features": ["flags": true],
                ],
                options: [.sortedKeys]
            )
            guard case .allowed = await client.applyConfig(minimalProjection) else {
                return XCTFail("unrelated config channels must be optional for flags")
            }

            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: self.fixture("config-enabled.json")
                ) as? [String: Any]
            )
            object["revision"] = "config-flags-unrelated-junk"
            object["issuedAt"] = "2026-08-04T00:00:30.000Z"
            object["expiresAt"] = "2026-08-04T00:05:30.000Z"
            object["privacy"] = "not-a-flags-policy"
            object["capabilities"] = NSNull()
            object["session"] = false
            object["limits"] = []
            var endpoints = try XCTUnwrap(object["endpoints"] as? [String: Any])
            endpoints["events"] = "http://untrusted.example/events"
            endpoints["replay"] = 17
            endpoints["assets"] = NSNull()
            object["endpoints"] = endpoints
            var features = try XCTUnwrap(object["features"] as? [String: Any])
            features["capture"] = "ignored"
            features["replay"] = NSNull()
            features["assets"] = 17
            object["features"] = features
            let otherRolesUntrusted = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            guard case .allowed = await client.applyConfig(otherRolesUntrusted) else {
                return XCTFail("non-flag endpoint roles cannot deny flag authority")
            }

            endpoints["flags"] = "https://other.example/flags"
            object["endpoints"] = endpoints
            let flagsRoleUntrusted = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            let rejected = await client.applyConfig(flagsRoleUntrusted)
            XCTAssertEqual(rejected, .restricted(.malformed))

            let authority = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(try self.databaseURL(root: root))
            )
            XCTAssertEqual(authority.siteId, "site_demo")
            XCTAssertEqual(authority.restriction, .malformed)
            await runtime.close()
        }
    }

    func testMalformedInactiveFlagConfigsCannotAdvanceOrderedAuthority() async throws {
        var missingReason = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: fixture("config-disabled.json")
            ) as? [String: Any]
        )
        missingReason.removeValue(forKey: "reason")

        var invalidReason = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: fixture("config-disabled.json")
            ) as? [String: Any]
        )
        invalidReason["reason"] = String(repeating: "x", count: 257)

        var nonStringReason = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: fixture("config-disabled.json")
            ) as? [String: Any]
        )
        nonStringReason["reason"] = 17

        var forbiddenSite = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: fixture("config-disabled.json")
            ) as? [String: Any]
        )
        forbiddenSite["site"] = ["id": "site_other"]

        var forbiddenEndpoints = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: fixture("config-disabled.json")
            ) as? [String: Any]
        )
        forbiddenEndpoints["status"] = "revoked"
        forbiddenEndpoints["endpoints"] = [
            "flags": "https://ingest.elu.dev/v1/flags",
        ]

        let malformedCases: [(String, [String: Any])] = [
            ("missing reason", missingReason),
            ("invalid reason", invalidReason),
            ("non-string reason", nonStringReason),
            ("forbidden site", forbiddenSite),
            ("forbidden endpoints", forbiddenEndpoints),
        ]
        for (name, input) in malformedCases {
            try await withTemporaryDirectory { root in
                let clock = FlagTestClock(self.initialWall)
                let runtime = try await self.makeRuntime(root: root, clock: clock)
                let client = try await EluV1FlagClient.make(
                    runtime: runtime,
                    transport: ImmediateFlagTransport(),
                    versions: try self.versions()
                )
                guard case .allowed = await client.applyConfig(
                    self.fixture("config-enabled.json")
                ) else {
                    return XCTFail("baseline config must be allowed")
                }
                let database = try self.databaseURL(root: root)
                let baseline = try EluV1FlagStorageCodec.decodeAuthority(
                    self.flagAuthorityBody(database)
                )

                var newer = input
                newer["revision"] = "config-invalid-inactive"
                newer["issuedAt"] = "2026-08-04T00:02:00.000Z"
                newer["expiresAt"] = "2026-08-04T00:07:00.000Z"
                let malformed = try JSONSerialization.data(
                    withJSONObject: newer,
                    options: [.sortedKeys]
                )
                let result = await client.applyConfig(malformed)
                XCTAssertEqual(
                    result,
                    .restricted(.malformed),
                    name
                )

                let restricted = try EluV1FlagStorageCodec.decodeAuthority(
                    self.flagAuthorityBody(database)
                )
                XCTAssertEqual(restricted.restriction, .malformed, name)
                XCTAssertEqual(restricted.barrierGeneration, baseline.barrierGeneration + 1, name)
                XCTAssertEqual(restricted.ordering, baseline.ordering, name)
                XCTAssertEqual(restricted.semanticHash, baseline.semanticHash, name)
                XCTAssertEqual(restricted.siteId, baseline.siteId, name)
                XCTAssertEqual(restricted.configRevision, baseline.configRevision, name)
                XCTAssertEqual(restricted.endpoint, baseline.endpoint, name)
                XCTAssertEqual(restricted.configExpiresAt, baseline.configExpiresAt, name)
                await runtime.close()
            }
        }
    }

    func testOwnerLocalActivationGenerationExhaustionNeverReusesSaturatedAuthority() throws {
        let manager = try EluV1ConfigManager(
            exactConstructorSiteKey: siteKey,
            flagActivationCounter: EluV1FlagActivationCounter(
                value: EluV1FlagActivationCounter.maximum - 1
            )
        )
        let saturated = try manager.prepareFlagConfig(
            configData: fixture("config-enabled.json"),
            now: initialWall
        )
        XCTAssertEqual(saturated.activationGeneration, EluV1FlagActivationCounter.maximum)
        guard case .allowed = manager.commitFlagConfig(saturated, barrierGeneration: 1) else {
            return XCTFail("the final unique generation should be usable exactly once")
        }

        XCTAssertThrowsError(
            try manager.prepareFlagConfig(
                configData: fixture("config-enabled.json"),
                now: initialWall
            )
        ) { error in
            XCTAssertEqual(
                error as? EluV1ConfigResolutionError,
                .flagActivationGenerationExhausted
            )
        }
        XCTAssertEqual(
            manager.currentFlagAuthorization(now: initialWall),
            .restricted(.missing)
        )
        XCTAssertEqual(
            manager.commitFlagConfig(saturated, barrierGeneration: 1),
            .restricted(.storageUnavailable)
        )
        XCTAssertThrowsError(
            try manager.prepareFlagConfig(
                configData: fixture("config-enabled.json"),
                now: initialWall
            )
        )
    }

    func testInjectedClientReloadsPersistsAndReadsAfterOwnerReplacement() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            var transport = ImmediateFlagTransport()
            var client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: transport,
                versions: try self.versions(),
                requestIdGenerator: { "flags_request_1" }
            )
            guard case .allowed = await client.applyConfig(self.fixture("config-enabled.json")) else {
                return XCTFail("flags-only config should authorize")
            }
            guard case let .updated(snapshot) = await client.reload() else {
                return XCTFail("expected updated snapshot")
            }
            XCTAssertEqual(snapshot.lookup("enabled"), .found(value: .bool(false), payload: nil))
            XCTAssertEqual(snapshot.lookup("nothing"), .found(value: .null, payload: nil))
            XCTAssertEqual(snapshot.lookup("missing"), .missing)
            let firstCallCount = await transport.callCount()
            XCTAssertEqual(firstCallCount, 1)
            await runtime.close()

            runtime = try await self.makeRuntime(root: root, clock: clock)
            transport = ImmediateFlagTransport()
            client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: transport,
                versions: try self.versions()
            )
            guard case .allowed = await client.applyConfig(self.fixture("config-enabled.json")) else {
                return XCTFail("replacement owner should revalidate exact config")
            }
            let expectedPayload = try EluV1FlagJSON.parse(Data(#"{"color":"violet"}"#.utf8))
            let restartedLookup = await client.read("variant")
            XCTAssertEqual(
                restartedLookup,
                .found(
                    value: .string(Array("variant-a".utf16)),
                    payload: expectedPayload
                )
            )
            let replacementCallCount = await transport.callCount()
            XCTAssertEqual(replacementCallCount, 0)
            await runtime.close()
        }
    }

    func testContextAndRealOptTransitionsInvalidateInFlightAndSameValueIsNoOp() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let transport = GatedFlagTransport()
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: transport,
                versions: try self.versions(),
                requestIdGenerator: { "flags_request_old" }
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            let reload = Task { await client.reload() }
            while await transport.callCount() == 0 { await Task.yield() }
            let coalescedReload = Task { await client.reload() }
            await Task.yield()
            let coalescedCallCount = await transport.callCount()
            XCTAssertEqual(coalescedCallCount, 1)

            let before = try await runtime.snapshot()
            let same = try await runtime.setOptedOut(
                false,
                expectedGeneration: before.generation
            )
            XCTAssertEqual(same, before)
            let optedOut = try await runtime.setOptedOut(
                true,
                expectedGeneration: same.generation
            )
            XCTAssertEqual(optedOut.identity.contextRevision, before.identity.contextRevision + 1)
            await transport.completeCurrent()
            let staleResult = await reload.value
            let coalescedStaleResult = await coalescedReload.value
            let invalidatedLookup = await client.read("enabled")
            XCTAssertEqual(staleResult, .stale)
            XCTAssertEqual(coalescedStaleResult, .stale)
            XCTAssertEqual(invalidatedLookup, .missing)
            await runtime.close()
        }
    }

    func testConfigExpiryIsDurableAndCacheExpiryRetainsAuthorization() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let database = try self.databaseURL(root: root)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions(),
                requestIdGenerator: { "flags_request_1" }
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected cache install")
            }

            clock.set(Date(timeIntervalSince1970: 1_785_801_840)) // 00:04:00Z
            let cacheExpiryRead = await client.readAll()
            XCTAssertEqual(cacheExpiryRead, .miss)
            guard case let .begun(next) = await runtime.beginFlagReload(
                requestId: "flags_after_cache_expiry",
                versions: try self.versions()
            ) else {
                return XCTFail("cache expiry must retain config authorization")
            }
            XCTAssertEqual(next.token.barrierGeneration, 1)

            clock.set(Date(timeIntervalSince1970: 1_785_801_900)) // 00:05:00Z
            let configExpiryRead = await client.readAll()
            XCTAssertEqual(configExpiryRead, .restricted(.expired))
            clock.set(Date(timeIntervalSince1970: 1_785_801_899.5))
            let rollbackApply = await client.applyConfig(self.fixture("config-enabled.json"))
            XCTAssertEqual(
                rollbackApply,
                .restricted(.wallRollback)
            )
            await runtime.close()
            let durableExpiry = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(durableExpiry.restriction, .expired)
            XCTAssertEqual(durableExpiry.barrierGeneration, 2)
            let durableWall = try XCTUnwrap(durableExpiry.lastObservedWall).validated()
            XCTAssertEqual(
                durableWall,
                try EluV1Timestamp("2026-08-04T00:05:00Z")
            )
        }
    }

    func testPreSendExpiryEqualityPersistsBarrierBeforeTransportAuthorization() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let transport = ImmediateFlagTransport()
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: transport,
                versions: try self.versions()
            )
            guard case .allowed = await client.applyConfig(
                self.fixture("config-enabled.json")
            ) else {
                return XCTFail("expected initial flag authorization")
            }
            // Reload reads the wall for its fingerprint, durable begin, then
            // the separate pre-send transaction. Advance only on that third
            // read so expiry lands exactly after begin and before transport.
            clock.set(
                Date(timeIntervalSince1970: 1_785_801_900), // 00:05:00Z
                onNthRead: 3
            )
            let result = await client.reload()
            XCTAssertEqual(result, .restricted(.expired))
            let transportCalls = await transport.callCount()
            XCTAssertEqual(transportCalls, 0)

            let database = try self.databaseURL(root: root)
            await runtime.close()
            let authority = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(authority.restriction, .expired)
            XCTAssertEqual(authority.barrierGeneration, 2)
            XCTAssertEqual(
                try XCTUnwrap(authority.lastObservedWall).validated(),
                try EluV1Timestamp("2026-08-04T00:05:00Z")
            )
            let requestState = try EluV1FlagStorageCodec.decodeRequestState(
                self.flagRequestMetadataBody(database)
            )
            XCTAssertNil(requestState.activeRequestId)
            XCTAssertNil(requestState.activeWitnessHash)
            XCTAssertNil(requestState.cacheRecordId)
            XCTAssertEqual(requestState.barrierGeneration, 2)
        }
    }

    func testFutureRequestAndReferencedChunkSchemasAreTerminalAndBytePreserved() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions(),
                requestIdGenerator: { "flags_future_request" }
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .begun = await runtime.beginFlagReload(
                requestId: "flags_future_request",
                versions: try self.versions()
            ) else {
                return XCTFail("expected request metadata")
            }
            await runtime.close()

            let database = try self.databaseURL(root: root)
            try self.executeSQL(
                database,
                "UPDATE flag_cache_records SET storage_schema = 2 "
                    + "WHERE record_type = 'request' AND record_index = 0"
            )
            let futureRows = try self.flagRows(database)
            runtime = try await self.makeRuntime(root: root, clock: clock)
            let replacement = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            let futureMetadataApply = await replacement.applyConfig(
                self.fixture("config-enabled.json")
            )
            let futureMetadataRead = await replacement.readAll()
            let futureMetadataReload = await replacement.reload()
            XCTAssertEqual(futureMetadataApply, .restricted(.terminal))
            XCTAssertEqual(futureMetadataRead, .terminal)
            XCTAssertEqual(futureMetadataReload, .terminal)
            await runtime.close()
            XCTAssertEqual(try self.flagRows(database), futureRows)
        }

        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions(),
                requestIdGenerator: { "flags_future_chunk" }
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected cache body")
            }
            await runtime.close()

            let database = try self.databaseURL(root: root)
            try self.executeSQL(
                database,
                "UPDATE flag_cache_records SET storage_schema = 2 "
                    + "WHERE record_type = 'chunk' AND record_index = 0"
            )
            let futureRows = try self.flagRows(database)
            runtime = try await self.makeRuntime(root: root, clock: clock)
            let replacement = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            let futureChunkApply = await replacement.applyConfig(
                self.fixture("config-enabled.json")
            )
            let futureChunkRead = await replacement.readAll()
            let futureChunkReload = await replacement.reload()
            XCTAssertEqual(futureChunkApply, .restricted(.terminal))
            XCTAssertEqual(futureChunkRead, .terminal)
            XCTAssertEqual(futureChunkReload, .terminal)
            await runtime.close()
            XCTAssertEqual(try self.flagRows(database), futureRows)
        }
    }

    func testUnreferencedFutureChunkOwnsStorageAndIsNeverRotated() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected baseline cache")
            }

            let database = try self.databaseURL(root: root)
            let extraIndex = try self.withDatabase(database) { database in
                try self.scalarInteger(
                    database,
                    sql: "SELECT chunk_count FROM flag_cache_records "
                        + "WHERE record_type = 'request' AND record_index = 0"
                )
            }
            try self.executeSQL(
                database,
                "INSERT INTO flag_cache_records (record_type, record_index, storage_schema, "
                    + "initialized, declared_body_bytes, body_sha256, chunk_count, body) "
                    + "VALUES ('chunk', \(extraIndex), 2, 1, NULL, NULL, NULL, X'7B7D')"
            )
            let before = try self.completeFlagRows(database)

            let apply = await client.applyConfig(try self.newerRevokedConfig())
            let read = await client.readAll()
            let reload = await client.reload()
            XCTAssertEqual(apply, .restricted(.terminal))
            XCTAssertEqual(read, .terminal)
            XCTAssertEqual(reload, .terminal)
            XCTAssertEqual(try self.completeFlagRows(database), before)
            await runtime.close()
        }
    }

    func testUnreferencedCurrentChunkRemainsRotatableCurrentCorruption() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let epochs = FlagTestStoreEpochs()
            let runtime = try await self.makeRuntime(
                root: root,
                clock: clock,
                flagStoreEpochGenerator: { epochs.next() }
            )
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected baseline cache")
            }

            let database = try self.databaseURL(root: root)
            let originalRequest = try EluV1FlagStorageCodec.decodeRequestState(
                self.flagRequestMetadataBody(database)
            )
            let authorityBefore = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            let extraIndex = try self.withDatabase(database) { database in
                try self.scalarInteger(
                    database,
                    sql: "SELECT chunk_count FROM flag_cache_records "
                        + "WHERE record_type = 'request' AND record_index = 0"
                )
            }
            try self.executeSQL(
                database,
                "INSERT INTO flag_cache_records (record_type, record_index, storage_schema, "
                    + "initialized, declared_body_bytes, body_sha256, chunk_count, body) "
                    + "VALUES ('chunk', \(extraIndex), 1, 1, NULL, NULL, NULL, X'7B7D')"
            )

            guard case .begun = await runtime.beginFlagReload(
                requestId: "flags_rotate_extra_current_chunk",
                versions: try self.versions()
            ) else {
                return XCTFail("all-current extra chunk must rotate as current corruption")
            }
            let freshRequest = try EluV1FlagStorageCodec.decodeRequestState(
                self.flagRequestMetadataBody(database)
            )
            XCTAssertNotEqual(freshRequest.storeEpoch, originalRequest.storeEpoch)
            let rowsAfterRotation = try self.completeFlagRows(database)
            XCTAssertFalse(
                rowsAfterRotation.contains(where: {
                    $0.hasPrefix("chunk|\(extraIndex)|")
                })
            )
            let authorityAfter = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(
                self.activityAuthorityProjection(authorityAfter),
                self.activityAuthorityProjection(authorityBefore)
            )
            await runtime.close()
        }
    }

    func testApplyMapsMissingAndFutureAuthorityToTerminalBeforeLocalMutation() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            let database = try self.databaseURL(root: root)
            try self.executeSQL(
                database,
                "DELETE FROM flag_cache_records "
                    + "WHERE record_type = 'authority' AND record_index = 0"
            )
            let before = try self.completeFlagRows(database)
            let apply = await client.applyConfig(try self.newerRevokedConfig())
            XCTAssertEqual(apply, .restricted(.terminal))
            XCTAssertEqual(try self.completeFlagRows(database), before)
            await runtime.close()
        }

        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            let database = try self.databaseURL(root: root)
            try self.executeSQL(
                database,
                "UPDATE flag_cache_records SET storage_schema = 2 "
                    + "WHERE record_type = 'authority' AND record_index = 0"
            )
            let before = try self.completeFlagRows(database)
            let apply = await client.applyConfig(try self.newerRevokedConfig())
            XCTAssertEqual(apply, .restricted(.terminal))
            XCTAssertEqual(try self.completeFlagRows(database), before)

            try self.executeSQL(
                database,
                "UPDATE flag_cache_records SET storage_schema = 1 "
                    + "WHERE record_type = 'authority' AND record_index = 0"
            )
            guard case .begun = await runtime.beginFlagReload(
                requestId: "flags_after_future_authority_restore",
                versions: try self.versions()
            ) else {
                return XCTFail("terminal preflight must preserve the active local authorization")
            }
            await runtime.close()
        }
    }

    func testDurableTerminalAuthorityPrecedesClockAndPreservesLocalActivation() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected baseline cache")
            }

            let database = try self.databaseURL(root: root)
            let currentAuthorityBody = try self.flagAuthorityBody(database)
            var terminalAuthority = try EluV1FlagStorageCodec.decodeAuthority(
                currentAuthorityBody
            )
            terminalAuthority.restriction = .terminal
            let terminalAuthorityBody = try EluV1FlagStorageCodec.encodeAuthority(
                terminalAuthority
            )

            try self.updateFlagAuthorityBody(database, terminalAuthorityBody)
            let terminalRows = try self.completeFlagRows(database)
            let normalApply = await client.applyConfig(try self.newerRevokedConfig())
            XCTAssertEqual(normalApply, .restricted(.terminal))
            XCTAssertEqual(try self.completeFlagRows(database), terminalRows)

            try self.updateFlagAuthorityBody(database, currentAuthorityBody)
            guard case .hit = await client.readAll() else {
                return XCTFail("terminal authority preflight must preserve local activation")
            }

            try self.updateFlagAuthorityBody(database, terminalAuthorityBody)
            clock.set(Date(timeIntervalSince1970: 1_785_801_659))
            let rollbackApply = await client.applyConfig(try self.newerRevokedConfig())
            XCTAssertEqual(rollbackApply, .restricted(.terminal))
            XCTAssertEqual(try self.completeFlagRows(database), terminalRows)

            try self.updateFlagAuthorityBody(database, currentAuthorityBody)
            clock.set(self.initialWall)
            guard case .hit = await client.readAll() else {
                return XCTFail("terminal authority preflight must not poison the rollback clock")
            }
            await runtime.close()
        }
    }

    func testFlagSubmissionRollbackFailurePoisonsAndReleasesOwner() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let fault = FlagTestArmedFaultInjector(point: .beforeRollback)
            let runtime = try await self.makeRuntime(
                root: root,
                clock: clock,
                faultInjector: fault
            )
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            guard case .allowed = await client.applyConfig(
                self.fixture("config-enabled.json")
            ) else {
                return XCTFail("expected baseline authorization")
            }
            let database = try self.databaseURL(root: root)
            let before = try self.completeFlagRows(database)

            fault.arm()
            let failed = await client.applyConfig(self.fixture("config-enabled.json"))
            XCTAssertEqual(failed, .restricted(.storageUnavailable))
            XCTAssertEqual(fault.hitCount, 1)
            XCTAssertEqual(try self.completeFlagRows(database), before)
            do {
                _ = try await runtime.snapshot()
                XCTFail("failed rollback must poison the old owner")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .poisoned)
            }

            let replacementRuntime = try await self.makeRuntime(root: root, clock: clock)
            let replacementClient = try await EluV1FlagClient.make(
                runtime: replacementRuntime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            guard case .allowed = await replacementClient.applyConfig(
                self.fixture("config-enabled.json")
            ) else {
                return XCTFail("rollback poison must release ownership for a new owner")
            }
            await replacementRuntime.close()
            await runtime.close()
        }
    }

    func testBarrierExhaustionLatchesTerminalWithoutReplacingAuthority() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            var client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            await runtime.close()

            let database = try self.databaseURL(root: root)
            var authority = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            let originalOrdering = authority.ordering
            let originalHash = authority.semanticHash
            authority.barrierGeneration = 9_007_199_254_740_991
            try self.updateFlagAuthorityBody(
                database,
                try EluV1FlagStorageCodec.encodeAuthority(authority)
            )

            runtime = try await self.makeRuntime(root: root, clock: clock)
            client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            let exhaustedApply = await client.applyConfig(Data("{".utf8))
            XCTAssertEqual(exhaustedApply, .restricted(.terminal))
            clock.set(Date(timeIntervalSince1970: 1_785_801_900))
            let terminalRead = await client.readAll()
            XCTAssertEqual(terminalRead, .terminal)
            await runtime.close()

            let terminal = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(terminal.barrierGeneration, 9_007_199_254_740_991)
            XCTAssertEqual(terminal.restriction, .terminal)
            XCTAssertEqual(terminal.ordering, originalOrdering)
            XCTAssertEqual(terminal.semanticHash, originalHash)
        }
    }

    func testBarrierOrderingPreservesStaleHighWaterAndEqualConflictRestriction() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            guard case .allowed = await client.applyConfig(
                self.fixture("config-enabled.json")
            ) else {
                return XCTFail("expected initial allow")
            }
            let database = try self.databaseURL(root: root)
            let initial = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )

            let conflictResult = await client.applyConfig(
                self.fixture("config-disabled.json")
            )
            XCTAssertEqual(conflictResult, .restricted(.conflict))
            let conflicted = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(conflicted.barrierGeneration, initial.barrierGeneration + 1)
            XCTAssertEqual(conflicted.ordering, initial.ordering)
            XCTAssertEqual(conflicted.semanticHash, initial.semanticHash)
            XCTAssertEqual(conflicted.restriction, .conflict)

            let equalOriginal = await client.applyConfig(
                self.fixture("config-enabled.json")
            )
            XCTAssertEqual(equalOriginal, .restricted(.conflict))
            let preservedConflict = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(preservedConflict.barrierGeneration, conflicted.barrierGeneration)
            XCTAssertEqual(preservedConflict.restriction, .conflict)
            await runtime.close()
        }

        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            let database = try self.databaseURL(root: root)
            let highWater = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            var staleObject = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: self.fixture("config-enabled.json")
                ) as? [String: Any]
            )
            staleObject["issuedAt"] = "2026-08-03T23:59:59.000Z"
            staleObject["revision"] = "config-stale"
            let staleResult = await client.applyConfig(
                try JSONSerialization.data(withJSONObject: staleObject, options: [.sortedKeys])
            )
            XCTAssertEqual(staleResult, .restricted(.missing))
            let afterStale = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(afterStale.barrierGeneration, highWater.barrierGeneration)
            XCTAssertEqual(afterStale.ordering, highWater.ordering)
            XCTAssertEqual(afterStale.semanticHash, highWater.semanticHash)
            let ownerLocalResult = await client.readAll()
            XCTAssertEqual(ownerLocalResult, .restricted(.missing))
            await runtime.close()
        }
    }

    func testPostCommitFinalCASCannotDeleteANewerBegin() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case let .begun(first) = await runtime.beginFlagReload(
                requestId: "flags_first",
                versions: try self.versions()
            ) else {
                return XCTFail("expected first begin")
            }
            let firstResponse = try EluV1FlagCodec.decodeResponse(
                flagResponse(for: first.request.canonicalData),
                for: first.request
            )
            let firstCommit = await runtime.commitFlagReload(
                token: first.token,
                response: firstResponse
            )
            XCTAssertEqual(firstCommit, .updated)
            guard case let .begun(second) = await runtime.beginFlagReload(
                requestId: "flags_second",
                versions: try self.versions()
            ) else {
                return XCTFail("expected newer begin")
            }
            let staleFinal = await runtime.finalizeFlagReload(
                token: first.token,
                versions: try self.versions()
            )
            XCTAssertEqual(staleFinal, .miss)
            guard case .hit = await runtime.readFlagCache(versions: try self.versions()) else {
                return XCTFail("token-scoped cleanup must preserve the newer request cache")
            }
            let secondResponse = try EluV1FlagCodec.decodeResponse(
                flagResponse(for: second.request.canonicalData),
                for: second.request
            )
            let secondCommit = await runtime.commitFlagReload(
                token: second.token,
                response: secondResponse
            )
            XCTAssertEqual(secondCommit, .updated)
            guard case .hit = await runtime.finalizeFlagReload(
                token: second.token,
                versions: try self.versions()
            ) else {
                return XCTFail("newest token should finalize")
            }
            await runtime.close()
        }
    }

    func testEmptySnapshotReplacesPriorValues() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case let .begun(first) = await runtime.beginFlagReload(
                requestId: "flags_snapshot_full",
                versions: try self.versions()
            ) else {
                return XCTFail("expected initial begin")
            }
            let firstResponse = try EluV1FlagCodec.decodeResponse(
                flagResponse(for: first.request.canonicalData),
                for: first.request
            )
            let firstCommit = await runtime.commitFlagReload(
                token: first.token,
                response: firstResponse
            )
            XCTAssertEqual(
                firstCommit,
                .updated
            )

            guard case let .begun(empty) = await runtime.beginFlagReload(
                requestId: "flags_snapshot_empty",
                versions: try self.versions()
            ) else {
                return XCTFail("expected replacement begin")
            }
            let emptyResponse = try EluV1FlagCodec.decodeResponse(
                emptyFlagResponse(for: empty.request.canonicalData),
                for: empty.request
            )
            let emptyCommit = await runtime.commitFlagReload(
                token: empty.token,
                response: emptyResponse
            )
            XCTAssertEqual(
                emptyCommit,
                .updated
            )
            guard case let .hit(snapshot) = await runtime.finalizeFlagReload(
                token: empty.token,
                versions: try self.versions()
            ) else {
                return XCTFail("expected empty authoritative snapshot")
            }
            XCTAssertTrue(snapshot.response.flags.isEmpty)
            XCTAssertTrue(snapshot.response.payloads.isEmpty)
            XCTAssertEqual(snapshot.lookup("enabled"), .missing)
            await runtime.close()
        }
    }

    func testNewerRevokeRejectsOldCompletion() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case let .begun(old) = await runtime.beginFlagReload(
                requestId: "flags_before_revoke",
                versions: try self.versions()
            ) else {
                return XCTFail("expected in-flight request")
            }
            let revoked = await client.applyConfig(try self.newerRevokedConfig())
            XCTAssertEqual(revoked, .restricted(.revoked))
            let response = try EluV1FlagCodec.decodeResponse(
                flagResponse(for: old.request.canonicalData),
                for: old.request
            )
            let completion = await runtime.commitFlagReload(
                token: old.token,
                response: response
            )
            XCTAssertEqual(completion, .stale)
            let read = await client.readAll()
            XCTAssertEqual(read, .restricted(.revoked))

            let database = try self.databaseURL(root: root)
            let revokedAuthority = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(revokedAuthority.siteId, "site_demo")
            XCTAssertNil(revokedAuthority.endpoint)

            let collision = await client.applyConfig(
                try self.newerEnabledConfig(siteId: "site_other")
            )
            XCTAssertEqual(collision, .restricted(.conflict))
            let collisionAuthority = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(collisionAuthority.siteId, "site_demo")
            XCTAssertEqual(collisionAuthority.restriction, .conflict)
            await runtime.close()
        }
    }

    func testFixedMonotonicDeadlinesExpireAtEqualityAndClockRegressionPoisonsOwner() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let continuous = FlagTestContinuousClock()
            let runtime = try await self.makeRuntime(
                root: root,
                clock: clock,
                continuousClock: continuous
            )
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            guard case .allowed = await client.applyConfig(self.fixture("config-enabled.json")),
                  case .updated = await client.reload()
            else {
                return XCTFail("expected installed config and cache")
            }

            // The cache's declared evaluatedAt→effective-expiry lifetime is
            // 179 seconds. Frozen wall time cannot extend that fixed lease.
            continuous.set(179_000_000_000)
            let cacheExpiry = await client.readAll()
            XCTAssertEqual(cacheExpiry, .miss)
            guard case .begun = await runtime.beginFlagReload(
                requestId: "flags_after_monotonic_cache_expiry",
                versions: try self.versions()
            ) else {
                return XCTFail("cache-only expiry must preserve config authority")
            }

            // The config's fixed wall/install lease is 240 seconds. Equality
            // durably restricts it even while wall time remains frozen.
            continuous.set(240_000_000_000)
            let configExpiry = await runtime.beginFlagReload(
                requestId: "flags_after_monotonic_config_expiry",
                versions: try self.versions()
            )
            XCTAssertEqual(
                configExpiry,
                .restricted(.expired)
            )
            await runtime.close()
            let authority = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(try self.databaseURL(root: root))
            )
            XCTAssertEqual(authority.restriction, .expired)
            XCTAssertEqual(authority.barrierGeneration, 2)
        }

        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let continuous = FlagTestContinuousClock(1_000)
            let runtime = try await self.makeRuntime(
                root: root,
                clock: clock,
                continuousClock: continuous
            )
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            continuous.set(999)
            let regressedRead = await client.readAll()
            XCTAssertEqual(regressedRead, .restricted(.wallRollback))
            continuous.set(2_000)
            let poisonedApply = await client.applyConfig(self.fixture("config-enabled.json"))
            XCTAssertEqual(
                poisonedApply,
                .restricted(.wallRollback)
            )
            await runtime.close()
        }
    }

    func testSyntheticDeadlineDigestCollisionCannotReuseDifferentExactExpiry() throws {
        let issued = EluV1StoredTimestamp(
            try EluV1Timestamp("2026-08-04T00:00:00.000Z")
        )
        let later = EluV1StoredTimestamp(
            try EluV1Timestamp("2026-08-04T00:05:00.000Z")
        )
        let earlier = EluV1StoredTimestamp(
            try EluV1Timestamp("2026-08-04T00:02:00.000Z")
        )
        let syntheticIndexCollision = "sha256:" + String(repeating: "f", count: 64)
        let laterConfig = EluV1FlagConfigDeadlineIdentity(
            exactConstructorSiteKey: siteKey,
            siteNamespaceDigest: try EluV1SiteNamespace.digest(
                exactConstructorSiteKey: siteKey
            ),
            siteId: "site_demo",
            configRevision: "config-1",
            ordering: issued,
            semanticHash: syntheticIndexCollision,
            endpoint: "https://ingest.elu.dev/v1/flags",
            configExpiresAt: later,
            barrierGeneration: 1,
            indexHash: syntheticIndexCollision
        )
        let earlierConfig = EluV1FlagConfigDeadlineIdentity(
            exactConstructorSiteKey: laterConfig.exactConstructorSiteKey,
            siteNamespaceDigest: laterConfig.siteNamespaceDigest,
            siteId: laterConfig.siteId,
            configRevision: laterConfig.configRevision,
            ordering: laterConfig.ordering,
            semanticHash: laterConfig.semanticHash,
            endpoint: laterConfig.endpoint,
            configExpiresAt: earlier,
            barrierGeneration: laterConfig.barrierGeneration,
            indexHash: syntheticIndexCollision
        )
        XCTAssertEqual(laterConfig.indexHash, earlierConfig.indexHash)
        XCTAssertNotEqual(laterConfig, earlierConfig)
        XCTAssertEqual(
            laterConfig,
            EluV1FlagConfigDeadlineIdentity(
                exactConstructorSiteKey: laterConfig.exactConstructorSiteKey,
                siteNamespaceDigest: laterConfig.siteNamespaceDigest,
                siteId: laterConfig.siteId,
                configRevision: laterConfig.configRevision,
                ordering: laterConfig.ordering,
                semanticHash: laterConfig.semanticHash,
                endpoint: laterConfig.endpoint,
                configExpiresAt: laterConfig.configExpiresAt,
                barrierGeneration: laterConfig.barrierGeneration,
                indexHash: nil
            )
        )

        let laterCache = EluV1FlagCacheDeadlineIdentity(
            storeEpoch: "store_epoch_1",
            cacheRecordId: "flag_cache_same",
            cachedWitnessHash: syntheticIndexCollision,
            flagsRevision: "flags-1",
            evaluatedAt: issued,
            responseExpiresAt: later,
            effectiveExpiresAt: later,
            barrierGeneration: 1,
            declaredBodyBytes: 512,
            bodySha256: syntheticIndexCollision,
            indexHash: syntheticIndexCollision
        )
        let earlierCache = EluV1FlagCacheDeadlineIdentity(
            storeEpoch: laterCache.storeEpoch,
            cacheRecordId: laterCache.cacheRecordId,
            cachedWitnessHash: laterCache.cachedWitnessHash,
            flagsRevision: laterCache.flagsRevision,
            evaluatedAt: laterCache.evaluatedAt,
            responseExpiresAt: earlier,
            effectiveExpiresAt: earlier,
            barrierGeneration: laterCache.barrierGeneration,
            declaredBodyBytes: laterCache.declaredBodyBytes,
            bodySha256: laterCache.bodySha256,
            indexHash: syntheticIndexCollision
        )
        XCTAssertEqual(laterCache.indexHash, earlierCache.indexHash)
        XCTAssertNotEqual(laterCache, earlierCache)
        XCTAssertEqual(
            laterCache,
            EluV1FlagCacheDeadlineIdentity(
                storeEpoch: laterCache.storeEpoch,
                cacheRecordId: laterCache.cacheRecordId,
                cachedWitnessHash: laterCache.cachedWitnessHash,
                flagsRevision: laterCache.flagsRevision,
                evaluatedAt: laterCache.evaluatedAt,
                responseExpiresAt: laterCache.responseExpiresAt,
                effectiveExpiresAt: laterCache.effectiveExpiresAt,
                barrierGeneration: laterCache.barrierGeneration,
                declaredBodyBytes: laterCache.declaredBodyBytes,
                bodySha256: laterCache.bodySha256,
                indexHash: nil
            )
        )
    }

    func testNonCooperativeTransportKeepsOneActiveAndOneReplaceablePendingReload() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let transport = GatedFlagTransport()
            let requestIds = FlagTestRequestIds()
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: transport,
                versions: try self.versions(),
                requestIdGenerator: { requestIds.next() }
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))

            let first = Task { await client.reload() }
            while await transport.callCount() != 1 { await Task.yield() }
            let initial = try await runtime.snapshot()
            let optedOut = try await runtime.setOptedOut(
                true,
                expectedGeneration: initial.generation
            )
            let replacedPending = Task { await client.reload() }
            await Task.yield()
            _ = try await runtime.setOptedOut(
                false,
                expectedGeneration: optedOut.generation
            )
            let newestPending = Task { await client.reload() }

            let replacedResult = await replacedPending.value
            let firstResult = await first.value
            let beforeReleaseCalls = await transport.callCount()
            let beforeReleaseMax = await transport.maxConcurrentCalls()
            XCTAssertEqual(replacedResult, .stale)
            XCTAssertEqual(firstResult, .stale)
            XCTAssertEqual(beforeReleaseCalls, 1)
            XCTAssertEqual(beforeReleaseMax, 1)

            await transport.completeCurrent()
            while await transport.callCount() != 2 { await Task.yield() }
            let promotedMax = await transport.maxConcurrentCalls()
            XCTAssertEqual(promotedMax, 1)
            await transport.completeCurrent()
            guard case .updated = await newestPending.value else {
                return XCTFail("only the newest pending witness may run")
            }
            let finalMax = await transport.maxConcurrentCalls()
            XCTAssertEqual(finalMax, 1)
            await runtime.close()
        }
    }

    func testApplyConfigReleasesLogicalReloadBeforeNonCooperativeTransportExits() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let transport = GatedFlagTransport()
            let requestIds = FlagTestRequestIds()
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: transport,
                versions: try self.versions(),
                requestIdGenerator: { requestIds.next() }
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))

            let invalidated = Task { await client.reload() }
            while await transport.callCount() != 1 { await Task.yield() }
            guard case .allowed = await client.applyConfig(
                self.fixture("config-enabled.json")
            ) else {
                return XCTFail("equal config should install a new owner-local activation")
            }

            let invalidatedResult = await invalidated.value
            let callsBeforeRelease = await transport.callCount()
            let maxBeforeRelease = await transport.maxConcurrentCalls()
            XCTAssertEqual(invalidatedResult, .stale)
            XCTAssertEqual(callsBeforeRelease, 1)
            XCTAssertEqual(maxBeforeRelease, 1)

            let pending = Task { await client.reload() }
            await Task.yield()
            let callsWithPending = await transport.callCount()
            XCTAssertEqual(callsWithPending, 1)
            await transport.completeCurrent()
            while await transport.callCount() != 2 { await Task.yield() }
            let promotedMax = await transport.maxConcurrentCalls()
            XCTAssertEqual(promotedMax, 1)
            await transport.completeCurrent()
            guard case .updated = await pending.value else {
                return XCTFail("new activation should run only after physical slot release")
            }
            let finalMax = await transport.maxConcurrentCalls()
            XCTAssertEqual(finalMax, 1)
            await runtime.close()
        }
    }

    func testCorruptGenerationRotatesEpochAndOldABATokenCannotCommit() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            var client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case let .begun(old) = await runtime.beginFlagReload(
                requestId: "flags_reused",
                versions: try self.versions()
            ) else {
                return XCTFail("expected old request token")
            }
            await runtime.close()

            let database = try self.databaseURL(root: root)
            var corrupt = try EluV1FlagStorageCodec.decodeRequestState(
                self.flagRequestMetadataBody(database)
            )
            corrupt.requestGeneration = 0
            try self.updateFlagRequestMetadataBody(
                database,
                try EluStateCoding.encoder().encode(corrupt)
            )

            runtime = try await self.makeRuntime(root: root, clock: clock)
            client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case let .begun(fresh) = await runtime.beginFlagReload(
                requestId: "flags_reused",
                versions: try self.versions()
            ) else {
                return XCTFail("known-current corruption should rotate the request epoch")
            }
            XCTAssertEqual(fresh.token.requestGeneration, 1)
            XCTAssertNotEqual(fresh.token.storeEpoch, old.token.storeEpoch)

            let oldResponse = try EluV1FlagCodec.decodeResponse(
                flagResponse(for: old.request.canonicalData),
                for: old.request
            )
            let oldCommit = await runtime.commitFlagReload(
                token: old.token,
                response: oldResponse
            )
            XCTAssertEqual(
                oldCommit,
                .stale
            )
            let afterOld = try EluV1FlagStorageCodec.decodeRequestState(
                self.flagRequestMetadataBody(database)
            )
            XCTAssertEqual(afterOld.storeEpoch, fresh.token.storeEpoch)
            XCTAssertEqual(afterOld.activeRequestId, fresh.token.requestId)

            var partial = afterOld
            partial.activeWitnessHash = nil
            XCTAssertThrowsError(try EluV1FlagStorageCodec.encodeRequestState(partial))
            await runtime.close()
        }
    }

    func testSyntheticSameHashEndpointCollisionConflictsAndOldCacheIsUnreadable() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            var client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected old-endpoint cache")
            }
            await runtime.close()

            let database = try self.databaseURL(root: root)
            var authority = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            authority.endpoint = "https://alternate.elu.dev/v1/flags"
            try self.updateFlagAuthorityBody(
                database,
                try EluV1FlagStorageCodec.encodeAuthority(authority)
            )

            runtime = try await self.makeRuntime(root: root, clock: clock)
            client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            let collision = await client.applyConfig(self.fixture("config-enabled.json"))
            XCTAssertEqual(collision, .restricted(.conflict))
            let cacheRead = await client.readAll()
            XCTAssertEqual(cacheRead, .restricted(.conflict))
            let conflicted = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(conflicted.restriction, .conflict)
            await runtime.close()
        }
    }

    func testDeepWideFutureEnvelopeBlocksReadAndReloadWithoutChangingAnyFlagRow() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            var client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected cache row to replace with future envelope")
            }
            await runtime.close()

            let deep = String(repeating: "[", count: 24) + "0"
                + String(repeating: "]", count: 24)
            let wide = Array(repeating: "0", count: 4_097).joined(separator: ",")
            let futureBody = Data(
                "{\"schemaVersion\":2,\"future\":{\"deep\":\(deep),\"wide\":[\(wide)]}}".utf8
            )
            XCTAssertTrue(EluV1FlagJSON.declaresFutureTopLevelSchema(futureBody))
            XCTAssertThrowsError(try EluV1FlagCodec.decodeCache(futureBody)) { error in
                XCTAssertEqual(error as? EluV1FlagContractError, .unsupportedSchemaVersion)
            }
            let database = try self.databaseURL(root: root)
            try self.replaceFlagCacheBody(database, body: futureBody)
            let before = try self.completeFlagRows(database)

            runtime = try await self.makeRuntime(root: root, clock: clock)
            client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            let futureRead = await client.readAll()
            let futureReload = await client.reload()
            XCTAssertEqual(futureRead, .terminal)
            XCTAssertEqual(futureReload, .terminal)
            await runtime.close()
            XCTAssertEqual(try self.completeFlagRows(database), before)
        }
    }

    func testOversizedInnerFutureCacheWinsBeforeV1LimitsDigestAndScannerBudgets() async throws {
        let ordinaryFuture = oversizedFutureCacheBody(exhaustScanner: false)
        let variants: [(name: String, body: Data, digest: String?)] = [
            (
                "future discriminator after chunk zero",
                ordinaryFuture,
                nil
            ),
            (
                "future discriminator wins over stale v1 digest",
                ordinaryFuture,
                "stale-v1-digest"
            ),
            (
                "scanner exhaustion remains opaque",
                oversizedFutureCacheBody(exhaustScanner: true),
                "stale-v1-digest"
            ),
        ]
        for variant in variants {
            XCTAssertGreaterThan(variant.body.count, EluV1FlagJSON.maximumCacheBytes)
            let discriminator = try XCTUnwrap(
                variant.body.range(of: Data(#""schemaVersion":2"#.utf8))
            )
            XCTAssertGreaterThan(
                discriminator.lowerBound,
                EluV1FlagJSON.maximumWireBytes,
                variant.name
            )

            try await withTemporaryDirectory { root in
                let clock = FlagTestClock(self.initialWall)
                var runtime = try await self.makeRuntime(root: root, clock: clock)
                var client = try await EluV1FlagClient.make(
                    runtime: runtime,
                    transport: ImmediateFlagTransport(),
                    versions: try self.versions()
                )
                _ = await client.applyConfig(self.fixture("config-enabled.json"))
                guard case .updated = await client.reload() else {
                    return XCTFail("expected baseline cache: \(variant.name)")
                }
                await runtime.close()

                let database = try self.databaseURL(root: root)
                try self.replaceFlagCacheBody(
                    database,
                    body: variant.body,
                    bodySha256: variant.digest
                )
                let before = try self.completeFlagRows(database)

                runtime = try await self.makeRuntime(root: root, clock: clock)
                client = try await EluV1FlagClient.make(
                    runtime: runtime,
                    transport: ImmediateFlagTransport(),
                    versions: try self.versions()
                )
                let result = await client.applyConfig(try self.newerRevokedConfig())
                XCTAssertEqual(result, .restricted(.terminal), variant.name)
                await runtime.close()
                XCTAssertEqual(
                    try self.completeFlagRows(database),
                    before,
                    variant.name
                )
            }
        }
    }

    func testUnprobeableFutureCacheHeaderIsTerminalAndBytePreserved() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            var client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected baseline cache")
            }
            await runtime.close()

            let database = try self.databaseURL(root: root)
            try self.executeSQL(
                database,
                "UPDATE flag_cache_records SET declared_body_bytes = "
                    + "\(EluRuntimeQueueLimits.defaultMaximumBytes + 1) "
                    + "WHERE record_type = 'request' AND record_index = 0"
            )
            let before = try self.completeFlagRows(database)

            runtime = try await self.makeRuntime(root: root, clock: clock)
            client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            let result = await client.applyConfig(try self.newerRevokedConfig())
            XCTAssertEqual(result, .restricted(.terminal))
            await runtime.close()
            XCTAssertEqual(try self.completeFlagRows(database), before)
        }
    }

    func testMissingFutureChunkIsOpaqueAndCannotRollBackCoreMutation() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            var client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected baseline cache")
            }
            await runtime.close()

            let database = try self.databaseURL(root: root)
            try self.replaceFlagCacheBody(
                database,
                body: self.oversizedFutureCacheBody(exhaustScanner: false)
            )
            try self.executeSQL(
                database,
                "DELETE FROM flag_cache_records WHERE record_type = 'chunk' "
                    + "AND record_index = 4"
            )
            let before = try self.completeFlagRows(database)

            runtime = try await self.makeRuntime(root: root, clock: clock)
            client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            let snapshot = try await runtime.snapshot()
            let optedOut = try await runtime.setOptedOut(
                true,
                expectedGeneration: snapshot.generation
            )
            XCTAssertTrue(optedOut.identity.optedOut)
            XCTAssertEqual(try self.completeFlagRows(database), before)

            let result = await client.applyConfig(try self.newerRevokedConfig())
            XCTAssertEqual(result, .restricted(.terminal))
            await runtime.close()
            XCTAssertEqual(try self.completeFlagRows(database), before)
        }
    }

    func testInnerFutureCachePrecedesAuthorityExpiryWithoutMutatingRows() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            var client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected baseline cache")
            }
            await runtime.close()

            let database = try self.databaseURL(root: root)
            try self.replaceFlagCacheBody(
                database,
                body: self.oversizedFutureCacheBody(exhaustScanner: false),
                bodySha256: "stale-v1-digest"
            )
            let before = try self.completeFlagRows(database)
            clock.set(Date(timeIntervalSince1970: 1_785_801_900)) // config expiry equality

            runtime = try await self.makeRuntime(root: root, clock: clock)
            client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            let futureRead = await client.readAll()
            let futureReload = await client.reload()
            XCTAssertEqual(futureRead, .terminal)
            XCTAssertEqual(futureReload, .terminal)
            await runtime.close()
            XCTAssertEqual(try self.completeFlagRows(database), before)
        }
    }

    func testCacheSchemaNumericAliasesUseNormalizedBinary64Classification() async throws {
        for token in ["1.0", "1e0"] {
            try await withTemporaryDirectory { root in
                let clock = FlagTestClock(self.initialWall)
                var runtime = try await self.makeRuntime(root: root, clock: clock)
                var client = try await EluV1FlagClient.make(
                    runtime: runtime,
                    transport: ImmediateFlagTransport(),
                    versions: try self.versions()
                )
                _ = await client.applyConfig(self.fixture("config-enabled.json"))
                guard case .updated = await client.reload() else {
                    return XCTFail("expected baseline cache for \(token)")
                }
                await runtime.close()

                let database = try self.databaseURL(root: root)
                let aliased = try self.replacingRootCacheSchema(
                    self.flagCacheBody(database),
                    with: token
                )
                try self.replaceFlagCacheBody(database, body: aliased)
                let before = try self.completeFlagRows(database)

                runtime = try await self.makeRuntime(root: root, clock: clock)
                client = try await EluV1FlagClient.make(
                    runtime: runtime,
                    transport: ImmediateFlagTransport(),
                    versions: try self.versions()
                )
                guard case .allowed = await client.applyConfig(
                    self.fixture("config-enabled.json")
                ) else {
                    return XCTFail("current alias must remain allowed: \(token)")
                }
                guard case .hit = await client.readAll() else {
                    return XCTFail("current alias must remain readable: \(token)")
                }
                await runtime.close()
                XCTAssertEqual(try self.completeFlagRows(database), before, token)
            }
        }

        for token in ["2.0", "2e0", "9.007199254740992e15"] {
            try await withTemporaryDirectory { root in
                let clock = FlagTestClock(self.initialWall)
                var runtime = try await self.makeRuntime(root: root, clock: clock)
                var client = try await EluV1FlagClient.make(
                    runtime: runtime,
                    transport: ImmediateFlagTransport(),
                    versions: try self.versions()
                )
                _ = await client.applyConfig(self.fixture("config-enabled.json"))
                guard case .updated = await client.reload() else {
                    return XCTFail("expected baseline cache for \(token)")
                }
                await runtime.close()

                let database = try self.databaseURL(root: root)
                let aliased = try self.replacingRootCacheSchema(
                    self.flagCacheBody(database),
                    with: token
                )
                try self.replaceFlagCacheBody(database, body: aliased)
                let before = try self.completeFlagRows(database)

                runtime = try await self.makeRuntime(root: root, clock: clock)
                client = try await EluV1FlagClient.make(
                    runtime: runtime,
                    transport: ImmediateFlagTransport(),
                    versions: try self.versions()
                )
                let apply = await client.applyConfig(self.fixture("config-enabled.json"))
                let read = await client.readAll()
                XCTAssertEqual(apply, .restricted(.terminal), token)
                XCTAssertEqual(read, .terminal, token)
                await runtime.close()
                XCTAssertEqual(try self.completeFlagRows(database), before, token)
            }
        }
    }

    func testZeroDeclaredHeaderWithPhysicalFutureChunksIsOpaqueAndPreserved() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            var client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected baseline cache")
            }
            await runtime.close()

            let database = try self.databaseURL(root: root)
            try self.replaceFlagCacheBody(
                database,
                body: self.oversizedFutureCacheBody(exhaustScanner: false)
            )
            try self.executeSQL(
                database,
                "UPDATE flag_cache_records SET declared_body_bytes = 0, "
                    + "body_sha256 = '', chunk_count = 0 "
                    + "WHERE record_type = 'request' AND record_index = 0"
            )
            let before = try self.completeFlagRows(database)

            runtime = try await self.makeRuntime(root: root, clock: clock)
            client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            let apply = await client.applyConfig(try self.newerRevokedConfig())
            let reload = await client.reload()
            XCTAssertEqual(apply, .restricted(.terminal))
            XCTAssertEqual(reload, .terminal)
            await runtime.close()
            XCTAssertEqual(try self.completeFlagRows(database), before)
        }
    }

    func testOversizedExplicitCurrentCacheRotatesEpochWithoutChangingAuthority() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            var client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected baseline cache")
            }
            await runtime.close()

            let database = try self.databaseURL(root: root)
            let oldRequest = try EluV1FlagStorageCodec.decodeRequestState(
                self.flagRequestMetadataBody(database)
            )
            let authorityBefore = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            try self.replaceFlagCacheBody(
                database,
                body: self.oversizedCacheBody(schemaToken: "1e0", nestingDepth: 24)
            )

            runtime = try await self.makeRuntime(root: root, clock: clock)
            client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            guard case .allowed = await client.applyConfig(
                self.fixture("config-enabled.json")
            ) else {
                return XCTFail("equal authority must remain allowed")
            }
            guard case .begun = await runtime.beginFlagReload(
                requestId: "flags_rotate_explicit_current",
                versions: try self.versions()
            ) else {
                return XCTFail("oversized current cache must rotate, not latch terminal")
            }
            let freshRequest = try EluV1FlagStorageCodec.decodeRequestState(
                self.flagRequestMetadataBody(database)
            )
            XCTAssertNotEqual(freshRequest.storeEpoch, oldRequest.storeEpoch)
            let authorityAfter = try EluV1FlagStorageCodec.decodeAuthority(
                self.flagAuthorityBody(database)
            )
            XCTAssertEqual(
                self.activityAuthorityProjection(authorityAfter),
                self.activityAuthorityProjection(authorityBefore)
            )
            XCTAssertEqual(authorityAfter.barrierGeneration, authorityBefore.barrierGeneration)
            await runtime.close()
        }
    }

    func testMalformedRequestMetadataCannotRollBackCoreMutation() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            var runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .begun = await runtime.beginFlagReload(
                requestId: "flags_empty_metadata",
                versions: try self.versions()
            ) else {
                return XCTFail("expected request metadata")
            }
            await runtime.close()

            let database = try self.databaseURL(root: root)
            try self.executeSQL(
                database,
                "UPDATE flag_cache_records SET body = X'' "
                    + "WHERE record_type = 'request' AND record_index = 0"
            )
            let before = try self.completeFlagRows(database)

            runtime = try await self.makeRuntime(root: root, clock: clock)
            let snapshot = try await runtime.snapshot()
            let optedOut = try await runtime.setOptedOut(
                true,
                expectedGeneration: snapshot.generation
            )
            XCTAssertTrue(optedOut.identity.optedOut)
            XCTAssertEqual(try self.completeFlagRows(database), before)
            await runtime.close()
        }
    }

    func testFutureStoragePrecedesClockRollbackWithoutPoisoningOrMutation() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .updated = await client.reload() else {
                return XCTFail("expected baseline cache")
            }

            let database = try self.databaseURL(root: root)
            let currentBody = try self.flagCacheBody(database)
            try self.replaceFlagCacheBody(
                database,
                body: self.oversizedFutureCacheBody(exhaustScanner: false)
            )
            let before = try self.completeFlagRows(database)
            let normalApply = await client.applyConfig(try self.newerRevokedConfig())
            XCTAssertEqual(normalApply, .restricted(.terminal))
            XCTAssertEqual(try self.completeFlagRows(database), before)

            try self.replaceFlagCacheBody(database, body: currentBody)
            guard case .hit = await client.readAll() else {
                return XCTFail("opaque preflight must not clear the active local authorization")
            }

            try self.replaceFlagCacheBody(
                database,
                body: self.oversizedFutureCacheBody(exhaustScanner: false)
            )
            let beforeRollback = try self.completeFlagRows(database)
            clock.set(Date(timeIntervalSince1970: 1_785_801_659))

            let rollbackApply = await client.applyConfig(try self.newerRevokedConfig())
            let reload = await client.reload()
            let begin = await runtime.beginFlagReload(
                requestId: "flags_future_before_rollback",
                versions: try self.versions()
            )
            XCTAssertEqual(rollbackApply, .restricted(.terminal))
            XCTAssertEqual(reload, .terminal)
            XCTAssertEqual(begin, .terminal)
            XCTAssertEqual(try self.completeFlagRows(database), beforeRollback)

            try self.replaceFlagCacheBody(database, body: currentBody)
            clock.set(self.initialWall)
            guard case .hit = await client.readAll() else {
                return XCTFail("opaque preflight must not sample or poison the rollback clock")
            }
            await runtime.close()
        }
    }

    func testFlagOnlyCurrentAndFutureCorruptionCannotRollBackCoreMutations() async throws {
        try await withTemporaryDirectory { root in
            let clock = FlagTestClock(self.initialWall)
            let runtime = try await self.makeRuntime(root: root, clock: clock)
            let client = try await EluV1FlagClient.make(
                runtime: runtime,
                transport: ImmediateFlagTransport(),
                versions: try self.versions()
            )
            _ = await client.applyConfig(self.fixture("config-enabled.json"))
            guard case .begun = await runtime.beginFlagReload(
                requestId: "flags_corrupt_header",
                versions: try self.versions()
            ) else {
                return XCTFail("expected request row")
            }
            let database = try self.databaseURL(root: root)
            try self.executeSQL(
                database,
                "UPDATE flag_cache_records SET body_sha256 = 'x' "
                    + "WHERE record_type = 'request' AND record_index = 0"
            )
            let corruptHeader = try self.completeFlagRows(database)
            let before = try await runtime.snapshot()
            let optedOut = try await runtime.setOptedOut(
                true,
                expectedGeneration: before.generation
            )
            XCTAssertTrue(optedOut.identity.optedOut)
            XCTAssertEqual(try self.completeFlagRows(database), corruptHeader)

            try self.executeSQL(
                database,
                "UPDATE flag_cache_records SET storage_schema = 2 "
                    + "WHERE record_type = 'request' AND record_index = 0"
            )
            let futureHeader = try self.completeFlagRows(database)
            let reset = try await runtime.reset(expectedGeneration: optedOut.generation)
            XCTAssertNotEqual(reset.identity.anonymousId, optedOut.identity.anonymousId)
            XCTAssertEqual(try self.completeFlagRows(database), futureHeader)

            let authorityBytes = self.flagAuthorityBody(database)
            try self.updateFlagAuthorityBody(database, Data("{".utf8))
            let corruptAuthorityBytes = self.flagAuthorityBody(database)
            XCTAssertNotEqual(corruptAuthorityBytes, authorityBytes)
            let restoredOpt = try await runtime.setOptedOut(
                false,
                expectedGeneration: reset.generation
            )
            XCTAssertFalse(restoredOpt.identity.optedOut)
            XCTAssertEqual(self.flagAuthorityBody(database), corruptAuthorityBytes)
            let terminalBegin = await runtime.beginFlagReload(
                requestId: "flags_after_authority_corruption",
                versions: try self.versions()
            )
            XCTAssertEqual(terminalBegin, .terminal)
            await runtime.close()
        }
    }

    private func makeRuntime(
        root: URL,
        clock: FlagTestClock,
        continuousClock: FlagTestContinuousClock? = nil,
        flagStoreEpochGenerator: @escaping @Sendable () -> String = {
            "flag_store_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        },
        faultInjector: (any EluRuntimeQueueFaultInjecting)? = nil
    ) async throws -> EluSQLiteRuntimeQueue {
        try await EluSQLiteRuntimeQueue.openCaptureRuntime(
            rootDirectoryURL: root,
            exactConstructorSiteKey: siteKey,
            clock: { clock.now() },
            continuousClock: {
                continuousClock?.now() ?? EluMachContinuousClock.now()
            },
            continuousBudgetConverter: { nanoseconds in
                if continuousClock != nil { return nanoseconds }
                return EluMachContinuousClock.floorTicks(forNanoseconds: nanoseconds)
            },
            anonymousIdGenerator: { "anon_flags_1" },
            streamIdGenerator: { "stream_flags_1" },
            sessionIdGenerator: { "session_flags_1" },
            flagStoreEpochGenerator: flagStoreEpochGenerator,
            faultInjector: faultInjector
        )
    }

    private func versions() throws -> EluVersionContext {
        try EluVersionContext(
            runtime: EluVersionComponent(name: "elu-ios", version: "0.1.0"),
            facade: EluVersionComponent(name: "EluAnalytics", version: "0.1.0"),
            build: "test-build"
        )
    }

    private func makeWitness() throws -> EluV1FlagEvaluationWitness {
        let authorization = EluV1FlagAuthorizationSnapshot(
            exactConstructorSiteKey: siteKey,
            siteNamespaceDigest: try EluV1SiteNamespace.digest(exactConstructorSiteKey: siteKey),
            siteId: "site_demo",
            endpoint: URL(string: "https://ingest.elu.dev/v1/flags")!,
            configRevision: "config-1",
            configIssuedAt: try EluV1Timestamp("2026-08-04T00:00:00.000Z"),
            configSemanticHash: "sha256:" + String(repeating: "a", count: 64),
            activationGeneration: 1,
            barrierGeneration: 1,
            configExpiresAt: try EluV1Timestamp("2026-08-04T00:05:00.000Z")
        )
        let identity = try EluIdentityState(
            revision: 1,
            contextRevision: 7,
            anonymousId: "anon_flags_1",
            userId: "user_123",
            groups: ["organization": "org_456"],
            superProperties: [:],
            session: nil,
            optedOut: false,
            updatedAt: initialWall
        )
        return try EluV1FlagEvaluationWitness(
            authorization: authorization,
            runtime: EluRuntimeQueueSnapshot(
                identity: identity,
                flagContext: EluFlagContext(
                    personProperties: [
                        "plan": .string("growth"),
                        "role": .string("owner"),
                    ],
                    groupProperties: ["organization": ["tier": .string("design-partner")]]
                ),
                streamId: "stream_flags_1",
                nextSequence: 0,
                headSequence: nil,
                queuedCount: 0,
                queuedBytes: 0,
                generation: 0
            ),
            versions: try versions()
        )
    }

    private func response(for requestData: Data) throws -> Data {
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        let identity = try XCTUnwrap(request["identity"] as? [String: Any])
        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "requestId": request["requestId"]!,
                "contextRevision": request["contextRevision"]!,
                "identityRevision": identity["revision"]!,
                "flagsRevision": "flags-test-1",
                "evaluatedAt": "2026-08-04T00:01:01.000Z",
                "expiresAt": "2026-08-04T00:04:00.000Z",
                "flags": [
                    "enabled": false,
                    "nothing": NSNull(),
                    "zero": 0,
                    "variant": "variant-a",
                ],
                "payloads": ["variant": ["color": "violet"]],
            ],
            options: [.sortedKeys]
        )
    }

    private func fixture(_ name: String) -> Data {
        try! Data(contentsOf: fixturesURL().appendingPathComponent(name))
    }

    private func newerRevokedConfig() throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture("config-disabled.json")) as? [String: Any]
        )
        object["issuedAt"] = "2026-08-04T00:01:30.000Z"
        object["expiresAt"] = "2026-08-04T00:06:30.000Z"
        object["revision"] = "config-revoked-2"
        object["status"] = "revoked"
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func newerEnabledConfig(siteId: String) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: fixture("config-enabled.json")
            ) as? [String: Any]
        )
        object["issuedAt"] = "2026-08-04T00:02:00.000Z"
        object["expiresAt"] = "2026-08-04T00:07:00.000Z"
        object["revision"] = "config-enabled-site-collision"
        object["site"] = ["id": siteId]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func fixturesURL() -> URL {
        repositoryRoot().appendingPathComponent("Conformance/V1/Fixtures", isDirectory: true)
    }

    private func vectorURL() -> URL {
        repositoryRoot().appendingPathComponent(
            "Conformance/V1/TestVectors/feature-flag-activity.json"
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func databaseURL(root: URL) throws -> URL {
        let digest = try EluV1SiteNamespace.digest(exactConstructorSiteKey: siteKey)
        return root.appendingPathComponent("site-\(digest)", isDirectory: true)
            .appendingPathComponent("runtime-state-v1.sqlite3")
    }

    private func userVersion(_ url: URL) throws -> Int64 {
        try withDatabase(url) { database in
            try scalarInteger(database, sql: "PRAGMA user_version")
        }
    }

    private func runtimeRecordSchema(_ url: URL) throws -> Int64 {
        try withDatabase(url) { database in
            try scalarInteger(database, sql: "SELECT schema_version FROM runtime_state")
        }
    }

    private func tableNames(_ url: URL) throws -> [String] {
        try withDatabase(url) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { throw FlagTestError.sqlite }
            defer { sqlite3_finalize(statement) }
            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                names.append(String(cString: sqlite3_column_text(statement, 0)))
            }
            return names
        }
    }

    private func flagRows(_ url: URL) throws -> [String] {
        try withDatabase(url) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT record_type, record_index, storage_schema, initialized, hex(body) FROM flag_cache_records ORDER BY record_type, record_index",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { throw FlagTestError.sqlite }
            defer { sqlite3_finalize(statement) }
            var rows: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    "\(String(cString: sqlite3_column_text(statement, 0)))|"
                        + "\(sqlite3_column_int64(statement, 1))|"
                        + "\(sqlite3_column_int64(statement, 2))|"
                        + "\(sqlite3_column_int64(statement, 3))|"
                        + String(cString: sqlite3_column_text(statement, 4))
                )
            }
            return rows
        }
    }

    private func completeFlagRows(_ url: URL) throws -> [String] {
        try withDatabase(url) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT record_type, record_index, storage_schema, initialized, "
                    + "COALESCE(declared_body_bytes, -1), COALESCE(body_sha256, '<null>'), "
                    + "COALESCE(chunk_count, -1), hex(body) FROM flag_cache_records "
                    + "ORDER BY record_type, record_index",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { throw FlagTestError.sqlite }
            defer { sqlite3_finalize(statement) }
            var rows: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    "\(String(cString: sqlite3_column_text(statement, 0)))|"
                        + "\(sqlite3_column_int64(statement, 1))|"
                        + "\(sqlite3_column_int64(statement, 2))|"
                        + "\(sqlite3_column_int64(statement, 3))|"
                        + "\(sqlite3_column_int64(statement, 4))|"
                        + "\(String(cString: sqlite3_column_text(statement, 5)))|"
                        + "\(sqlite3_column_int64(statement, 6))|"
                        + String(cString: sqlite3_column_text(statement, 7))
                )
            }
            return rows
        }
    }

    private func flagCacheBody(_ url: URL) throws -> Data {
        try withDatabase(url) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT body FROM flag_cache_records WHERE record_type = 'chunk' "
                    + "ORDER BY record_index",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { throw FlagTestError.sqlite }
            defer { sqlite3_finalize(statement) }
            var result = Data()
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW,
                      sqlite3_column_type(statement, 0) == SQLITE_BLOB
                else {
                    throw FlagTestError.sqlite
                }
                let count = Int(sqlite3_column_bytes(statement, 0))
                guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else {
                    throw FlagTestError.sqlite
                }
                result.append(Data(bytes: bytes, count: count))
            }
        }
    }

    private func replacingRootCacheSchema(
        _ body: Data,
        with token: String
    ) throws -> Data {
        guard var source = String(data: body, encoding: .utf8),
              let range = source.range(of: ",\"schemaVersion\":1,\"witness\"")
        else {
            throw FlagTestError.sqlite
        }
        source.replaceSubrange(
            range,
            with: ",\"schemaVersion\":\(token),\"witness\""
        )
        return Data(source.utf8)
    }

    private func scalarInteger(_ database: OpaquePointer, sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw FlagTestError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FlagTestError.sqlite }
        return sqlite3_column_int64(statement, 0)
    }

    private func flagAuthorityBody(_ url: URL) throws -> Data {
        try flagRecordBody(url, recordType: "authority")
    }

    private func flagRequestMetadataBody(_ url: URL) throws -> Data {
        try flagRecordBody(url, recordType: "request")
    }

    private func flagRecordBody(_ url: URL, recordType: String) throws -> Data {
        guard recordType == "authority" || recordType == "request" else {
            throw FlagTestError.sqlite
        }
        return try withDatabase(url) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT body FROM flag_cache_records "
                    + "WHERE record_type = '\(recordType)' AND record_index = 0",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { throw FlagTestError.sqlite }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw FlagTestError.sqlite }
            let count = Int(sqlite3_column_bytes(statement, 0))
            if count == 0 { return Data() }
            guard let bytes = sqlite3_column_blob(statement, 0) else {
                throw FlagTestError.sqlite
            }
            return Data(bytes: bytes, count: count)
        }
    }

    private func updateFlagAuthorityBody(_ url: URL, _ body: Data) throws {
        let hex = body.map { String(format: "%02x", $0) }.joined()
        try executeSQL(
            url,
            "UPDATE flag_cache_records SET body = X'\(hex)' "
                + "WHERE record_type = 'authority' AND record_index = 0"
        )
    }

    private func updateFlagRequestMetadataBody(_ url: URL, _ body: Data) throws {
        let hex = body.map { String(format: "%02x", $0) }.joined()
        try executeSQL(
            url,
            "UPDATE flag_cache_records SET body = X'\(hex)' "
                + "WHERE record_type = 'request' AND record_index = 0"
        )
    }

    private func replaceFlagCacheBody(
        _ url: URL,
        body: Data,
        bodySha256: String? = nil
    ) throws {
        guard !body.isEmpty,
              body.count <= EluRuntimeQueueLimits.defaultMaximumBytes
        else {
            throw FlagTestError.sqlite
        }
        let chunks = stride(
            from: 0,
            to: body.count,
            by: EluV1FlagJSON.maximumWireBytes
        ).map { offset in
            body.subdata(
                in: offset ..< min(offset + EluV1FlagJSON.maximumWireBytes, body.count)
            )
        }
        let digest = bodySha256 ?? EluV1FlagJSON.hash(body)

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database
        else { throw FlagTestError.sqlite }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw FlagTestError.sqlite
        }
        do {
            guard sqlite3_exec(
                database,
                "DELETE FROM flag_cache_records WHERE record_type = 'chunk'",
                nil,
                nil,
                nil
            ) == SQLITE_OK else { throw FlagTestError.sqlite }

            var update: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "UPDATE flag_cache_records SET declared_body_bytes = ?, body_sha256 = ?, "
                    + "chunk_count = ? WHERE record_type = 'request' AND record_index = 0",
                -1,
                &update,
                nil
            ) == SQLITE_OK, let update else { throw FlagTestError.sqlite }
            defer { sqlite3_finalize(update) }
            guard sqlite3_bind_int64(update, 1, Int64(body.count)) == SQLITE_OK,
                  sqlite3_bind_int64(update, 3, Int64(chunks.count)) == SQLITE_OK,
                  digest.withCString({ pointer in
                      guard sqlite3_bind_text(update, 2, pointer, -1, nil) == SQLITE_OK else {
                          return false
                      }
                      let didUpdate = sqlite3_step(update) == SQLITE_DONE
                      sqlite3_reset(update)
                      sqlite3_clear_bindings(update)
                      return didUpdate
                  })
            else { throw FlagTestError.sqlite }

            var insert: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO flag_cache_records (record_type, record_index, storage_schema, "
                    + "initialized, declared_body_bytes, body_sha256, chunk_count, body) "
                    + "VALUES ('chunk', ?, 1, 1, NULL, NULL, NULL, ?)",
                -1,
                &insert,
                nil
            ) == SQLITE_OK, let insert else { throw FlagTestError.sqlite }
            defer { sqlite3_finalize(insert) }
            for (index, chunk) in chunks.enumerated() {
                guard sqlite3_bind_int64(insert, 1, Int64(index)) == SQLITE_OK,
                      chunk.withUnsafeBytes({ bytes in
                          sqlite3_bind_blob(
                              insert,
                              2,
                              bytes.baseAddress,
                              Int32(bytes.count),
                              nil
                          ) == SQLITE_OK && sqlite3_step(insert) == SQLITE_DONE
                      })
                else { throw FlagTestError.sqlite }
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw FlagTestError.sqlite
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func oversizedFutureCacheBody(exhaustScanner: Bool) -> Data {
        oversizedCacheBody(
            schemaToken: "2",
            nestingDepth: exhaustScanner ? 4_097 : 0
        )
    }

    private func oversizedCacheBody(
        schemaToken: String,
        nestingDepth: Int
    ) -> Data {
        var body = Data("{\"opaque\":".utf8)
        if nestingDepth > 0 {
            body.append(Data(String(repeating: "[", count: nestingDepth).utf8))
            body.append(0x30)
            body.append(Data(String(repeating: "]", count: nestingDepth).utf8))
        } else {
            body.append(Data("null".utf8))
        }
        body.append(Data(",\"padding\":\"".utf8))
        body.append(
            Data(
                repeating: 0x78,
                count: EluV1FlagJSON.maximumCacheBytes + 128
            )
        )
        body.append(Data("\",\"schemaVersion\":\(schemaToken)}".utf8))
        return body
    }

    private func executeSQL(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database
        else { throw FlagTestError.sqlite }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FlagTestError.sqlite
        }
    }

    private func withDatabase<Value>(
        _ url: URL,
        operation: (OpaquePointer) throws -> Value
    ) throws -> Value {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { throw FlagTestError.sqlite }
        defer { sqlite3_close_v2(database) }
        return try operation(database)
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "elu-flags-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try await operation(url)
    }
}

private enum FlagActivityVectorError: Error {
    case invalid(String)
}

/// Executable reference model for the frozen cross-SDK activity vector. This
/// intentionally consumes the scenario documents themselves (including every
/// step input and every expected field) instead of mapping IDs to hand-written
/// tests. The runtime tests above independently exercise the same transitions.
private final class FlagActivityVectorInterpreter {
    private struct Token {
        let requestId: String
        let requestGeneration: Int64
        let barrierGeneration: Int64
        let contextRevision: Int64
        let identityRevision: Int64
    }

    private struct Model {
        var initialized = false
        var barrierGeneration: Int64 = 0
        var lastObservedWall: EluV1Timestamp?
        var lastObservedWallSource: String?
        var configIssuedAt: EluV1Timestamp?
        var configExpiresAt: EluV1Timestamp?
        var restriction: String?
        var requestGeneration: Int64 = 0
        var storeEpoch: String
        var activeRequestId: String?
        var tokens: [String: Token] = [:]
        var cache: [String: Any]?
        var contextRevision: Int64
        var identityRevision: Int64
        var personProperties: [String: Any]
        var cacheCorrupt = false
        var authorityCorrupt = false
        var futureRecord = false
        var clockPoisoned = false
    }

    private let root: [String: Any]
    private let fixturesURL: URL
    private let scenarios: [[String: Any]]
    private let scenariosById: [String: [String: Any]]
    private let documentVariants: [String: [String: Any]]
    private let fixtureCatalog: [String: [String: Any]]
    private let constants: [String: Any]
    private let initialState: [String: Any]
    private let requestOracle: [String: Any]

    init(root: [String: Any], fixturesURL: URL) throws {
        guard Self.integer(root["schemaVersion"]) == 1,
              root["vectorId"] as? String == "elu-feature-flag-activity-v1",
              let scenarios = root["scenarios"] as? [[String: Any]],
              let documentVariants = root["documentVariants"] as? [String: [String: Any]],
              let fixtureCatalog = root["fixtureCatalog"] as? [String: [String: Any]],
              let constants = root["constants"] as? [String: Any],
              let initialState = root["initialState"] as? [String: Any],
              let requestOracle = root["requestOracle"] as? [String: Any]
        else {
            throw FlagActivityVectorError.invalid("malformed vector root")
        }
        var index: [String: [String: Any]] = [:]
        for scenario in scenarios {
            guard Set(scenario.keys) == Set(["id", "steps"]),
                  let identifier = scenario["id"] as? String,
                  index.updateValue(scenario, forKey: identifier) == nil
            else {
                throw FlagActivityVectorError.invalid("malformed or duplicate scenario")
            }
        }
        self.root = root
        self.fixturesURL = fixturesURL
        self.scenarios = scenarios
        scenariosById = index
        self.documentVariants = documentVariants
        self.fixtureCatalog = fixtureCatalog
        self.constants = constants
        self.initialState = initialState
        self.requestOracle = requestOracle
    }

    func runAll() throws -> Set<String> {
        var executed: Set<String> = []
        for scenario in scenarios {
            guard let identifier = scenario["id"] as? String else {
                throw FlagActivityVectorError.invalid("scenario without id")
            }
            var model = try makeInitialModel()
            try executeScenario(identifier, model: &model, stack: [])
            executed.insert(identifier)
        }
        return executed
    }

    var productionScenarios: [[String: Any]] { scenarios }
    var productionInitialState: [String: Any] { initialState }
    var productionRequestOracle: [String: Any] { requestOracle }

    func productionScenario(named identifier: String) -> [String: Any]? {
        scenariosById[identifier]
    }

    func productionDocumentData(named name: String, kind: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: resolveDocument(named: name, kind: kind),
            options: [.sortedKeys]
        )
    }

    func compareProductionExpectation(
        _ step: [String: Any],
        actual: [String: Any],
        context: String
    ) throws {
        try compareExpectation(step, actual: actual, context: context)
    }

    func compareProductionValue(_ expected: Any, actual: Any, context: String) throws {
        guard try Self.canonicalJSON(expected) == Self.canonicalJSON(actual) else {
            throw FlagActivityVectorError.invalid("\(context) does not match production state")
        }
    }

    private func makeInitialModel() throws -> Model {
        try Self.requireKeys(
            initialState,
            exactly: [
                "authority", "cache", "contextRevision", "groupProperties", "groups",
                "identity", "optedOut", "personProperties",
            ],
            context: "initialState"
        )
        guard let authority = initialState["authority"] as? [String: Any],
              Set(authority.keys) == Set([
                  "barrierGeneration", "initialized", "lastObservedWall",
              ]),
              let identity = initialState["identity"] as? [String: Any],
              let contextRevision = Self.integer(initialState["contextRevision"]),
              let identityRevision = Self.integer(identity["revision"]),
              let personProperties = initialState["personProperties"] as? [String: Any],
              let storeEpoch = constants["initialStoreEpoch"] as? String,
              Self.integer(authority["barrierGeneration"]) == 0,
              authority["initialized"] as? Bool == false,
              authority["lastObservedWall"] is NSNull,
              initialState["cache"] is NSNull,
              initialState["optedOut"] as? Bool == false,
              initialState["groups"] is [String: Any],
              initialState["groupProperties"] is [String: Any],
              identity["anonymousId"] as? String == constants["anonymousId"] as? String,
              identity["userId"] as? String == constants["userId"] as? String
        else {
            throw FlagActivityVectorError.invalid("invalid initial state")
        }
        return Model(
            storeEpoch: storeEpoch,
            contextRevision: contextRevision,
            identityRevision: identityRevision,
            personProperties: personProperties
        )
    }

    private func executeScenario(
        _ identifier: String,
        model: inout Model,
        stack: [String]
    ) throws {
        guard !stack.contains(identifier),
              let scenario = scenariosById[identifier],
              let steps = scenario["steps"] as? [[String: Any]]
        else {
            throw FlagActivityVectorError.invalid("unknown or recursive scenario \(identifier)")
        }
        let nextStack = stack + [identifier]
        for (index, step) in steps.enumerated() {
            try executeStep(
                step,
                model: &model,
                scenario: identifier,
                index: index,
                stack: nextStack
            )
        }
    }

    private func executeStep(
        _ step: [String: Any],
        model: inout Model,
        scenario: String,
        index: Int,
        stack: [String]
    ) throws {
        guard let type = step["type"] as? String else {
            throw FlagActivityVectorError.invalid("\(scenario)[\(index)] has no type")
        }
        let context = "\(scenario)[\(index)] \(type)"
        switch type {
        case "seedScenario":
            try Self.requireKeys(
                step,
                exactly: ["scenario", "type"],
                context: context
            )
            guard let seed = step["scenario"] as? String else {
                throw FlagActivityVectorError.invalid("\(context) has no seed")
            }
            try executeScenario(seed, model: &model, stack: stack)

        case "applyConfig":
            try Self.requireKeys(
                step,
                exactly: ["config", "expect", "type", "wallNow"],
                context: context
            )
            guard let name = step["config"] as? String,
                  let wallSource = step["wallNow"] as? String
            else {
                throw FlagActivityVectorError.invalid("\(context) has invalid inputs")
            }
            let document = try resolveDocument(named: name, kind: "config")
            let wall = try EluV1Timestamp(wallSource)
            var actual: [String: Any]
            if !observe(wall, source: wallSource, model: &model) {
                actual = [
                    "authorization": "restricted",
                    "reason": "wall-rollback",
                    "barrierGeneration": model.barrierGeneration,
                ]
            } else {
                guard let status = document["status"] as? String,
                      let issuedSource = document["issuedAt"] as? String,
                      let expiresSource = document["expiresAt"] as? String
                else {
                    throw FlagActivityVectorError.invalid("\(context) config shape")
                }
                let issued = try EluV1Timestamp(issuedSource)
                let expires = try EluV1Timestamp(expiresSource)
                guard issued < expires else {
                    throw FlagActivityVectorError.invalid("\(context) invalid config window")
                }
                let isNewBoundary = model.configIssuedAt.map { $0 < issued } ?? true
                if isNewBoundary {
                    model.barrierGeneration += 1
                    model.initialized = true
                    model.configIssuedAt = issued
                    model.configExpiresAt = expires
                }
                if status == "enabled" {
                    model.restriction = nil
                    actual = [
                        "authorization": "allowed",
                        "barrierGeneration": model.barrierGeneration,
                    ]
                } else if status == "revoked" || status == "disabled" {
                    model.restriction = status
                    model.cache = nil
                    model.activeRequestId = nil
                    model.requestGeneration += 1
                    actual = [
                        "authorization": "restricted",
                        "reason": status,
                        "barrierGeneration": model.barrierGeneration,
                    ]
                } else {
                    throw FlagActivityVectorError.invalid("\(context) unknown config status")
                }
                actual["lastObservedWall"] = model.lastObservedWallSource
            }
            try compareExpectation(step, actual: actual, context: context)

        case "beginReload":
            try Self.requireKeys(
                step,
                required: ["expect", "requestId", "type", "wallNow"],
                optional: ["realm", "storeEpoch"],
                context: context
            )
            guard let requestId = step["requestId"] as? String,
                  let wallSource = step["wallNow"] as? String
            else {
                throw FlagActivityVectorError.invalid("\(context) invalid begin inputs")
            }
            let wall = try EluV1Timestamp(wallSource)
            if model.authorityCorrupt || model.futureRecord {
                let actual: [String: Any] = [
                    "result": "terminal",
                    "storageMutation": false,
                    "bodyMaterialized": false,
                    "futureRecordPreservedByteForByte": model.futureRecord,
                ]
                try compareExpectation(step, actual: actual, context: context)
                return
            }
            guard observe(wall, source: wallSource, model: &model) else {
                try compareExpectation(
                    step,
                    actual: ["result": "restricted", "restriction": "wall-rollback"],
                    context: context
                )
                return
            }
            if let expiry = model.configExpiresAt, !(wall < expiry) {
                if model.restriction != "config-expired" {
                    model.barrierGeneration += 1
                    model.restriction = "config-expired"
                    model.cache = nil
                    model.activeRequestId = nil
                    model.requestGeneration += 1
                }
                try compareExpectation(
                    step,
                    actual: [
                        "result": "restricted",
                        "restriction": "config-expired",
                        "barrierGeneration": model.barrierGeneration,
                    ],
                    context: context
                )
                return
            }
            var authorityPreserved = false
            if model.cacheCorrupt {
                guard let replacementEpoch = step["storeEpoch"] as? String,
                      replacementEpoch != model.storeEpoch
                else {
                    throw FlagActivityVectorError.invalid("\(context) lacks replacement epoch")
                }
                model.storeEpoch = replacementEpoch
                model.requestGeneration = 0
                model.cache = nil
                model.activeRequestId = nil
                model.cacheCorrupt = false
                authorityPreserved = true
            } else if let declaredEpoch = step["storeEpoch"] as? String,
                      declaredEpoch != model.storeEpoch
            {
                throw FlagActivityVectorError.invalid("\(context) store epoch mismatch")
            }
            guard model.initialized, model.restriction == nil else {
                try compareExpectation(
                    step,
                    actual: [
                        "result": "restricted",
                        "restriction": model.restriction ?? "missing",
                    ],
                    context: context
                )
                return
            }
            model.requestGeneration += 1
            let token = Token(
                requestId: requestId,
                requestGeneration: model.requestGeneration,
                barrierGeneration: model.barrierGeneration,
                contextRevision: model.contextRevision,
                identityRevision: model.identityRevision
            )
            let realm = step["realm"] as? String ?? requestId
            model.tokens[realm] = token
            model.activeRequestId = requestId
            var actual: [String: Any] = [
                "result": "begun",
                "requestGeneration": model.requestGeneration,
                "barrierGeneration": model.barrierGeneration,
                "storeEpoch": model.storeEpoch,
                "authorityPreserved": authorityPreserved,
            ]
            if let expected = step["expect"] as? [String: Any],
               expected["requestCanonicalSha256"] != nil
            {
                actual["requestCanonicalSha256"] = try requestOracleHash(
                    requestId: requestId
                )
            }
            try compareExpectation(step, actual: actual, context: context)

        case "completeReload":
            try Self.requireKeys(
                step,
                required: ["expect", "requestId", "response", "type", "wallNow"],
                optional: ["realm"],
                context: context
            )
            guard let requestId = step["requestId"] as? String,
                  let responseName = step["response"] as? String,
                  let wallSource = step["wallNow"] as? String
            else {
                throw FlagActivityVectorError.invalid("\(context) invalid completion inputs")
            }
            let response = try resolveDocument(named: responseName, kind: "flagsResponse")
            let wall = try EluV1Timestamp(wallSource)
            _ = observe(wall, source: wallSource, model: &model)
            let realm = step["realm"] as? String ?? requestId
            guard let token = model.tokens[realm], token.requestId == requestId else {
                throw FlagActivityVectorError.invalid("\(context) has no matching token")
            }
            let stale = model.restriction != nil
                || token.requestGeneration != model.requestGeneration
                || token.barrierGeneration != model.barrierGeneration
                || token.contextRevision != model.contextRevision
                || model.activeRequestId != token.requestId
            if stale {
                try compareExpectation(
                    step,
                    actual: [
                        "result": "stale",
                        "cache": model.cache as Any? ?? NSNull(),
                        "requestGeneration": model.requestGeneration,
                    ],
                    context: context
                )
                return
            }
            guard response["requestId"] as? String == token.requestId,
                  Self.integer(response["contextRevision"]) == token.contextRevision,
                  Self.integer(response["identityRevision"]) == token.identityRevision,
                  let flags = response["flags"] as? [String: Any],
                  let payloads = response["payloads"] as? [String: Any],
                  let flagsRevision = response["flagsRevision"] as? String
            else {
                throw FlagActivityVectorError.invalid("\(context) response echo mismatch")
            }
            model.cache = response
            model.activeRequestId = nil
            try compareExpectation(
                step,
                actual: [
                    "result": "updated",
                    "flagsRevision": flagsRevision,
                    "flagCount": flags.count,
                    "payloadCount": payloads.count,
                    "requestGeneration": model.requestGeneration,
                ],
                context: context
            )

        case "readAll":
            try Self.requireKeys(
                step,
                exactly: ["expect", "type", "wallNow"],
                context: context
            )
            guard let wallSource = step["wallNow"] as? String,
                  let expectation = step["expect"] as? [String: Any]
            else {
                throw FlagActivityVectorError.invalid("\(context) invalid read inputs")
            }
            let wall = try EluV1Timestamp(wallSource)
            _ = observe(wall, source: wallSource, model: &model)
            if let cache = model.cache,
               let expirySource = cache["expiresAt"] as? String,
               let expiry = try? EluV1Timestamp(expirySource),
               !(wall < expiry)
            {
                model.cache = nil
                model.activeRequestId = nil
                model.requestGeneration += 1
            }
            var actual: [String: Any] = [
                "barrierGeneration": model.barrierGeneration,
                "requestGeneration": model.requestGeneration,
                "activeRequestId": model.activeRequestId as Any? ?? NSNull(),
            ]
            if let cache = model.cache,
               let flags = cache["flags"] as? [String: Any],
               let payloads = cache["payloads"] as? [String: Any]
            {
                actual["status"] = "hit"
                for key in expectation.keys where ![
                    "activeRequestId", "barrierGeneration", "requestGeneration", "status",
                ].contains(key) {
                    if key == "orphanPayloadExposed" {
                        actual[key] = false
                    } else if let value = flags[key] {
                        var lookup: [String: Any] = ["status": "found", "value": value]
                        if let payload = payloads[key] { lookup["payload"] = payload }
                        actual[key] = lookup
                    } else {
                        actual[key] = ["status": "missing"]
                    }
                }
            } else {
                actual["status"] = "miss"
            }
            try compareExpectation(step, actual: actual, context: context)

        case "setPersonProperties":
            try Self.requireKeys(
                step,
                exactly: ["expect", "set", "type", "wallNow"],
                context: context
            )
            guard let properties = step["set"] as? [String: Any],
                  properties.values.allSatisfy({ $0 is String }),
                  let wallSource = step["wallNow"] as? String
            else {
                throw FlagActivityVectorError.invalid("\(context) invalid context inputs")
            }
            let wall = try EluV1Timestamp(wallSource)
            guard observe(wall, source: wallSource, model: &model) else {
                throw FlagActivityVectorError.invalid("\(context) wall rollback")
            }
            for (key, value) in properties { model.personProperties[key] = value }
            model.contextRevision += 1
            model.cache = nil
            model.activeRequestId = nil
            model.requestGeneration += 1
            try compareExpectation(
                step,
                actual: ["contextRevision": model.contextRevision],
                context: context
            )

        case "injectCacheCorruption":
            try Self.requireKeys(
                step,
                exactly: ["kind", "type"],
                context: context
            )
            guard step["kind"] as? String == "digest-mismatch", model.cache != nil else {
                throw FlagActivityVectorError.invalid("\(context) invalid cache corruption")
            }
            model.cacheCorrupt = true

        case "injectAuthorityCorruption":
            try Self.requireKeys(
                step,
                exactly: ["kind", "type"],
                context: context
            )
            guard step["kind"] as? String == "missing-after-initialized",
                  model.initialized
            else {
                throw FlagActivityVectorError.invalid("\(context) invalid authority corruption")
            }
            model.authorityCorrupt = true

        case "injectFutureCacheRecord":
            try Self.requireKeys(
                step,
                exactly: ["declaredBodyBytes", "storageSchemaVersion", "type"],
                context: context
            )
            guard let declaredBytes = Self.integer(step["declaredBodyBytes"]),
                  let maximumBytes = Self.integer(constants["maximumCacheBytes"]),
                  let schema = Self.integer(step["storageSchemaVersion"]),
                  declaredBytes > maximumBytes,
                  schema > 1
            else {
                throw FlagActivityVectorError.invalid("\(context) invalid future record")
            }
            model.futureRecord = true

        default:
            throw FlagActivityVectorError.invalid("\(context) unknown operation")
        }
    }

    private func observe(
        _ wall: EluV1Timestamp,
        source: String,
        model: inout Model
    ) -> Bool {
        guard !model.clockPoisoned else { return false }
        if let last = model.lastObservedWall, wall < last {
            model.clockPoisoned = true
            return false
        }
        if model.lastObservedWall.map({ $0 < wall }) ?? true {
            model.lastObservedWall = wall
            model.lastObservedWallSource = source
        }
        return true
    }

    private func resolveDocument(named name: String, kind: String) throws -> [String: Any] {
        guard let variant = documentVariants[name],
              let baseName = variant["baseFixtureId"] as? String,
              let catalog = fixtureCatalog[baseName],
              Set(catalog.keys) == Set(["fixtureId", "kind"]),
              catalog["kind"] as? String == kind,
              let fixtureId = catalog["fixtureId"] as? String
        else {
            throw FlagActivityVectorError.invalid("invalid document variant \(name)")
        }
        let allowedVariantKeys = Set(["baseFixtureId", "orderedReplacements", "serialization"])
        guard Set(variant.keys).isSubset(of: allowedVariantKeys) else {
            throw FlagActivityVectorError.invalid("unknown variant input \(name)")
        }
        let data = try Data(
            contentsOf: fixturesURL.appendingPathComponent("\(fixtureId).json")
        )
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw FlagActivityVectorError.invalid("invalid base fixture \(fixtureId)")
        }
        if let replacements = variant["orderedReplacements"] as? [[String: Any]] {
            for replacement in replacements {
                guard Set(replacement.keys) == Set(["pointer", "value"]),
                      let pointer = replacement["pointer"] as? String,
                      pointer.first == "/",
                      !pointer.dropFirst().contains("/")
                else {
                    throw FlagActivityVectorError.invalid("invalid replacement in \(name)")
                }
                document[String(pointer.dropFirst())] = replacement["value"]
            }
        } else if variant["orderedReplacements"] != nil {
            throw FlagActivityVectorError.invalid("invalid replacements in \(name)")
        }
        if let serialization = variant["serialization"] as? String {
            guard serialization == "reverse-object-member-order-and-add-json-whitespace" else {
                throw FlagActivityVectorError.invalid("unknown serialization in \(name)")
            }
            // Ordering/whitespace are deliberately semantic no-ops. A real
            // serialize/parse cycle makes that consumption executable.
            let equivalent = try JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted]
            )
            guard let reparsed = try JSONSerialization.jsonObject(
                with: equivalent
            ) as? [String: Any] else {
                throw FlagActivityVectorError.invalid("serialization failed for \(name)")
            }
            document = reparsed
        } else if variant["serialization"] != nil {
            throw FlagActivityVectorError.invalid("invalid serialization in \(name)")
        }
        return document
    }

    private func requestOracleHash(requestId: String) throws -> String {
        guard Set(requestOracle.keys) == Set([
            "canonicalBase64", "canonicalSha256", "requestId",
        ]),
        requestOracle["requestId"] as? String == requestId,
        let base64 = requestOracle["canonicalBase64"] as? String,
        let canonical = Data(base64Encoded: base64),
        let expectedHash = requestOracle["canonicalSha256"] as? String,
        EluV1FlagJSON.hash(canonical) == expectedHash
        else {
            throw FlagActivityVectorError.invalid("request oracle mismatch")
        }
        return expectedHash
    }

    private func compareExpectation(
        _ step: [String: Any],
        actual: [String: Any],
        context: String
    ) throws {
        guard let expected = step["expect"] as? [String: Any] else {
            throw FlagActivityVectorError.invalid("\(context) has no expectation")
        }
        for (key, expectedValue) in expected {
            guard let actualValue = actual[key] else {
                throw FlagActivityVectorError.invalid("\(context) does not produce \(key)")
            }
            let expectedData = try Self.canonicalJSON(expectedValue)
            let actualData = try Self.canonicalJSON(actualValue)
            guard expectedData == actualData else {
                throw FlagActivityVectorError.invalid(
                    "\(context) expected \(key)=\(expectedValue), got \(actualValue)"
                )
            }
        }
    }

    private static func canonicalJSON(_ value: Any) throws -> Data {
        let wrapper = ["value": value]
        guard JSONSerialization.isValidJSONObject(wrapper) else {
            throw FlagActivityVectorError.invalid("non-JSON expectation")
        }
        return try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys])
    }

    private static func integer(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private static func requireKeys(
        _ value: [String: Any],
        exactly keys: Set<String>,
        context: String
    ) throws {
        guard Set(value.keys) == keys else {
            throw FlagActivityVectorError.invalid("\(context) has unconsumed fields")
        }
    }

    private static func requireKeys(
        _ value: [String: Any],
        required: Set<String>,
        optional: Set<String>,
        context: String
    ) throws {
        let actual = Set(value.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
            throw FlagActivityVectorError.invalid("\(context) has missing/unconsumed fields")
        }
    }
}

private enum FlagTestError: Error {
    case sqlite
}

private final class FlagTestArmedFaultInjector: @unchecked Sendable,
    EluRuntimeQueueFaultInjecting
{
    private let lock = NSLock()
    private let point: EluRuntimeQueueFaultPoint
    private var isArmed = false
    private var hits = 0

    init(point: EluRuntimeQueueFaultPoint) {
        self.point = point
    }

    func arm() {
        lock.lock()
        isArmed = true
        lock.unlock()
    }

    func hit(_ point: EluRuntimeQueueFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard isArmed, point == self.point else { return }
        hits += 1
        throw EluRuntimeQueueError.faultInjected(point)
    }

    var hitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return hits
    }
}

private final class FlagTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    private var scheduledValue: Date?
    private var readsUntilScheduledValue: Int?

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        if let remaining = readsUntilScheduledValue,
           let scheduledValue
        {
            if remaining == 1 {
                value = scheduledValue
                self.scheduledValue = nil
                readsUntilScheduledValue = nil
            } else {
                readsUntilScheduledValue = remaining - 1
            }
        }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        scheduledValue = nil
        readsUntilScheduledValue = nil
        lock.unlock()
    }

    func set(_ value: Date, onNthRead read: Int) {
        precondition(read > 0)
        lock.lock()
        scheduledValue = value
        readsUntilScheduledValue = read
        lock.unlock()
    }
}

private final class FlagTestContinuousClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64 = 0) { self.value = value }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: UInt64) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func advance(nanoseconds: UInt64) {
        lock.lock()
        value &+= nanoseconds
        lock.unlock()
    }
}

private final class FlagTestRequestIds: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        nextValue += 1
        return "flags_scheduled_\(nextValue)"
    }
}

private final class FlagTestStoreEpochs: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        nextValue += 1
        return "store_epoch_\(nextValue)"
    }
}

private actor ImmediateFlagTransport: EluV1FlagTransport {
    private var calls = 0

    func send(endpoint: URL, requestBody: Data) async throws -> Data {
        XCTAssertEqual(endpoint.absoluteString, "https://ingest.elu.dev/v1/flags")
        calls += 1
        return try flagResponse(for: requestBody)
    }

    func callCount() -> Int { calls }
}

private actor GatedFlagTransport: EluV1FlagTransport {
    private var requests: [Data] = []
    private var continuations: [CheckedContinuation<Data, Error>] = []
    private var activeCalls = 0
    private var maximumActiveCalls = 0

    func send(endpoint _: URL, requestBody: Data) async throws -> Data {
        requests.append(requestBody)
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func callCount() -> Int { requests.count }

    func maxConcurrentCalls() -> Int { maximumActiveCalls }

    func completeCurrent() {
        guard !continuations.isEmpty else { return }
        let continuation = continuations.removeFirst()
        let requestIndex = requests.count - continuations.count - 1
        guard requests.indices.contains(requestIndex) else { return }
        let request = requests[requestIndex]
        activeCalls -= 1
        do {
            continuation.resume(returning: try flagResponse(for: request))
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

private func flagResponse(for requestData: Data) throws -> Data {
    guard let request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
          let identity = request["identity"] as? [String: Any],
          let requestId = request["requestId"],
          let contextRevision = request["contextRevision"],
          let identityRevision = identity["revision"]
    else {
        throw FlagTestError.sqlite
    }
    return try JSONSerialization.data(
        withJSONObject: [
            "schemaVersion": 1,
            "requestId": requestId,
            "contextRevision": contextRevision,
            "identityRevision": identityRevision,
            "flagsRevision": "flags-test-1",
            "evaluatedAt": "2026-08-04T00:01:01.000Z",
            "expiresAt": "2026-08-04T00:04:00.000Z",
            "flags": [
                "enabled": false,
                "nothing": NSNull(),
                "zero": 0,
                "variant": "variant-a",
            ],
            "payloads": ["variant": ["color": "violet"]],
        ],
        options: [.sortedKeys]
    )
}

private func emptyFlagResponse(for requestData: Data) throws -> Data {
    guard let request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
          let identity = request["identity"] as? [String: Any],
          let requestId = request["requestId"],
          let contextRevision = request["contextRevision"],
          let identityRevision = identity["revision"]
    else {
        throw FlagTestError.sqlite
    }
    return try JSONSerialization.data(
        withJSONObject: [
            "schemaVersion": 1,
            "requestId": requestId,
            "contextRevision": contextRevision,
            "identityRevision": identityRevision,
            "flagsRevision": "flags-empty-2",
            "evaluatedAt": "2026-08-04T00:02:00.000Z",
            "expiresAt": "2026-08-04T00:04:00.000Z",
            "flags": [String: Any](),
            "payloads": [String: Any](),
        ],
        options: [.sortedKeys]
    )
}
