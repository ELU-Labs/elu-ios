import Foundation
import XCTest
import SQLite3
@testable import EluAnalytics

final class EluSelfHostedEndpointTests: XCTestCase {
    private let key = "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa"
    private let host = URL(string: "https://analytics.example.test")!
    private var policy: EluEndpointPolicy { try! EluEndpointPolicy(apiHost: host) }

    func testExplicitMalformedDeclarationCannotHideBehindApprovedConfigHost() {
        for raw in ["http://analytics.example.test", "https://analytics.example.test:443", "https://analytics.example.test/path//child", "https://user@analytics.example.test", "https://analytics.example.test?q=1", "https://analytics.example.test#x", "https://analytics.example.test.", "https://localhost"] {
            let value = URL(string: raw)!
            XCTAssertThrowsError(try EluEndpointPolicy(apiHost: value), raw)
            guard case .rejected = EluConfigHostAllowlist.resolve(configHost: URL(string: "https://elu.dev")!, apiHost: value) else { return XCTFail(raw) }
        }
    }

    func testPrefixIsBoundThroughConfigManagersAndEachRole() throws {
        let base = URL(string: "https://analytics.example.test/elu/tenant-1")!
        let selected = try EluEndpointPolicy(apiHost: URL(string: base.absoluteString + "/")!)
        XCTAssertEqual(selected.declaredAPIOrigin, base)
        XCTAssertEqual(try EluV2ConfigRequest(siteKey: key, configHost: base, endpointPolicy: selected).url.absoluteString,
                       base.absoluteString + "/sdk/v2/" + key + "/config")
        let data = try config(base: base), now = Date(timeIntervalSince1970: 1_785_888_090)
        _ = try EluV1ConfigManager(endpointPolicy: selected).update(configData: data, now: now)
        _ = try EluV1ConfigManager(exactConstructorSiteKey: key, endpointPolicy: selected).prepareFlagConfig(configData: data, now: now)
        for (role, path) in [(EluV1EndpointRole.events, "/v1/events"), (.flags, "/v1/flags"), (.replay, "/v2/replay"), (.assets, "/sdk/")] {
            XCTAssertNotNil(selected.endpoint(base.absoluteString + path, role: role))
            for other in [host.absoluteString, host.absoluteString + "/elu/tenant-2", base.absoluteString + "/child"] {
                XCTAssertNil(selected.endpoint(other + path, role: role), other + path)
            }
            XCTAssertNil(selected.endpoint(base.absoluteString + "/wrong" + path, role: role))
        }
        XCTAssertThrowsError(try EluV1ConfigManager(endpointPolicy: policy).update(configData: data, now: now))
        XCTAssertThrowsError(try EluV1ConfigManager(endpointPolicy: selected).update(configData: config(), now: now))
        let other = try EluEndpointPolicy(apiHost: URL(string: host.absoluteString + "/elu/tenant-2")!)
        XCTAssertThrowsError(try EluV1ConfigManager(endpointPolicy: other).update(configData: data, now: now))
        // Preserve encoded non-ASCII segment bytes when deriving the config path.
        let encodedBase = URL(string: host.absoluteString + "/%CE%B1")!
        let encodedPolicy = try EluEndpointPolicy(apiHost: encodedBase)
        XCTAssertEqual(try EluV2ConfigRequest(siteKey: key, configHost: encodedBase, endpointPolicy: encodedPolicy).url.absoluteString,
                       encodedBase.absoluteString + "/sdk/v2/" + key + "/config")
    }

    func testPhysicalConfigEventAndFlagRequestsKeepExactPrefixAndRefuseRedirects() async throws {
        let base = URL(string: host.absoluteString + "/elu/tenant-1")!
        let selected = try EluEndpointPolicy(apiHost: base)
        let request = try EluV2ConfigRequest(siteKey: key, configHost: base, endpointPolicy: selected)
        let configTransport = EluV2URLSessionConfigTransport(expectedRequestURL: request.url, protocolClasses: [SelfHostProtocol.self])
        let events = EluV1URLSessionBatchTransport(endpointPolicy: selected, protocolClasses: [SelfHostProtocol.self])
        let flags = try EluV1URLSessionFlagTransport(siteKey: key, endpointPolicy: selected, protocolClasses: [SelfHostProtocol.self])
        let count = SelfHostEmission()
        SelfHostProtocol.hooks.set { [key] req, client, instance in
            XCTAssertTrue(req.url!.absoluteString.hasPrefix(base.absoluteString + "/")); count.append()
            if req.httpMethod == "POST" { XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer " + key) }
            SelfHostProtocol.reply(req, client, instance, Data("{}".utf8))
        }
        _ = try await configTransport.fetch(request)
        func event(_ url: URL) -> EluV1BatchHTTPRequest {
            .init(url: url, headers: ["Authorization": "Bearer " + key], body: Data("{}".utf8), timeoutSeconds: 10, maximumResponseBytes: 1024)
        }
        _ = try await events.send(event(base.appendingPathComponent("v1/events")))
        _ = try await flags.send(endpoint: base.appendingPathComponent("v1/flags"), requestBody: Data("{}".utf8))
        XCTAssertEqual(count.count, 3)
        SelfHostProtocol.hooks.set { _, _, _ in XCTFail("Wrong prefix reached physical transport") }
        for wrong in [host, host.appendingPathComponent("elu/tenant-2")] {
            do { _ = try await events.send(event(wrong.appendingPathComponent("v1/events"))); XCTFail("Wrong event prefix") } catch {}
            do { _ = try await flags.send(endpoint: wrong.appendingPathComponent("v1/flags"), requestBody: Data("{}".utf8)); XCTFail("Wrong flag prefix") } catch {}
        }
        let redirects = SelfHostEmission()
        SelfHostProtocol.hooks.set { req, client, instance in
            redirects.append()
            client.urlProtocol(instance, wasRedirectedTo: URLRequest(url: self.host.appendingPathComponent("v1/flags")),
                redirectResponse: HTTPURLResponse(url: req.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await flags.send(endpoint: base.appendingPathComponent("v1/flags"), requestBody: Data("{}".utf8)); XCTFail("Prefix redirect accepted") } catch {}
        XCTAssertEqual(redirects.count, 1)
        do { _ = try await configTransport.fetch(request); XCTFail("Config prefix redirect accepted") } catch {}
        XCTAssertEqual(redirects.count, 2)
    }

    func testPublicSetupTransfersOriginalValidatedPolicyBeforeRuntimeConstruction() {
        let calls = SelfHostEmission(), expected = policy
        let factory = EluRuntimeBackendFactory { _, context in
            calls.append(); XCTAssertEqual(context.endpointPolicy, expected)
            XCTAssertEqual(context.configHost, self.host)
            return nil
        }
        let core = EluCore(backendFactory: factory)
        core.setup(siteKey: key, options: .init(configHost: host, apiHost: URL(string: "HTTPS://ANALYTICS.EXAMPLE.TEST/")!))
        XCTAssertNil(core.backendForTesting()); XCTAssertEqual(calls.count, 1)
        let invalid = EluCore(backendFactory: factory)
        invalid.setup(siteKey: key, options: .init(configHost: URL(string: "https://elu.dev")!, apiHost: URL(string: "http://bad.example.test")!))
        XCTAssertNil(invalid.backendForTesting()); XCTAssertEqual(calls.count, 1)
    }

    func testEveryRoleRemainsBoundToItsOriginalLocalOriginAndPath() throws {
        let normalized = try EluEndpointPolicy(apiHost: URL(string: "HTTPS://Analytics.Example.Test/")!)
        XCTAssertEqual(normalized, policy)
        for (role, path) in [(EluV1EndpointRole.events, "/v1/events"), (.flags, "/v1/flags"), (.replay, "/v2/replay"), (.assets, "/sdk/")] {
            XCTAssertNotNil(policy.endpoint(host.absoluteString + path, role: role))
            XCTAssertNotNil(policy.endpoint(host.absoluteString + ":443" + path, role: role))
            for prefix in ["https://ingest.elu.dev", "https://other.example.test", "http://analytics.example.test", "https://analytics.example.test:444", "https://user@analytics.example.test", "https://analytics.example.test.evil.test"] {
                XCTAssertNil(policy.endpoint(prefix + path, role: role))
            }
            for suffix in ["/extra", "#private", "?%73ite_key=bad"] {
                XCTAssertNil(policy.endpoint(host.absoluteString + path + suffix, role: role))
            }
            XCTAssertNil(EluEndpointPolicy.cloud.endpoint(host.absoluteString + path, role: role))
        }
        XCTAssertNotNil(EluEndpointPolicy.cloud.endpoint("https://assets.elu.dev/sdk/", role: .assets))
    }

    func testConfigSourceAndPhysicalRequestRemainExactlyPinned() async throws {
        let request = try EluV2ConfigRequest(siteKey: key, configHost: host, endpointPolicy: policy)
        XCTAssertEqual(request.url.absoluteString, host.absoluteString + "/sdk/v2/" + key + "/config")
        XCTAssertThrowsError(try EluV2ConfigRequest(siteKey: key, configHost: host))
        XCTAssertThrowsError(try EluV2ConfigRequest(siteKey: key, configHost: URL(string: "https://other.example.test")!, endpointPolicy: policy))
        let data = try config(), transport = EluV2URLSessionConfigTransport(expectedRequestURL: request.url, protocolClasses: [SelfHostProtocol.self])
        SelfHostProtocol.hooks.set { req, client, instance in
            XCTAssertEqual(req.url, request.url); XCTAssertEqual(req.httpMethod, "GET")
            SelfHostProtocol.reply(req, client, instance, data)
        }
        let clock = EluV2ConfigClock(wallNow: { Date(timeIntervalSince1970: 1_785_888_090) }, continuousNow: { 1 }, floorTicks: { $0 })
        let source = try EluV2ConfigSource(siteKey: key, configHost: host, endpointPolicy: policy, transport: transport, clock: clock)
        let result = await source.refresh(); XCTAssertEqual(result, .document(data)); await source.close()
        SelfHostProtocol.hooks.set { _, _, _ in XCTFail("Substituted config request reached network") }
        for other in [try EluV2ConfigRequest(siteKey: key, configHost: URL(string: "https://elu.dev")!), try EluV2ConfigRequest(siteKey: "elu_pk_test_bbbbbbbbbbbbbbbbbbbbbb", configHost: host, endpointPolicy: policy)] {
            do { _ = try await transport.fetch(other); XCTFail("Substituted config request accepted") }
            catch { XCTAssertEqual(error as? EluV2ConfigSourceError, .untrustedConfigHost) }
        }
    }

    func testConfigAndFlagProjectionRejectRemoteOriginWidening() throws {
        let original = try config(), now = Date(timeIntervalSince1970: 1_785_888_090)
        let manager = EluV1ConfigManager(endpointPolicy: policy)
        _ = try manager.update(configData: original, now: now)
        let flags = try EluV1ConfigManager(exactConstructorSiteKey: key, endpointPolicy: policy)
        _ = try flags.prepareFlagConfig(configData: original, now: now)
        for role in ["events", "flags", "replay", "assets"] {
            var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            var endpoints = object["endpoints"] as! [String: String]
            let old = endpoints[role] ?? (host.absoluteString + "/sdk/")
            endpoints[role] = old.replacingOccurrences(of: host.absoluteString, with: "https://other.example.test")
            object["endpoints"] = endpoints
            let foreign = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try EluV1ConfigManager(endpointPolicy: policy).update(configData: foreign, now: now))
            if role == "flags" { XCTAssertThrowsError(try flags.prepareFlagConfig(configData: foreign, now: now)) }
        }
    }

    func testActualEventAndFlagTransportsUseCustomOriginAndRejectCloudFallback() async throws {
        let events = EluV1URLSessionBatchTransport(endpointPolicy: policy, protocolClasses: [SelfHostProtocol.self])
        let flags = try EluV1URLSessionFlagTransport(siteKey: key, endpointPolicy: policy, protocolClasses: [SelfHostProtocol.self])
        SelfHostProtocol.hooks.set { [key, host] req, client, instance in
            XCTAssertEqual(req.url?.host, host.host); XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
            XCTAssertFalse(req.httpShouldHandleCookies)
            SelfHostProtocol.reply(req, client, instance, Data("{}".utf8))
        }
        let event = EluV1BatchHTTPRequest(url: host.appendingPathComponent("v1/events"), headers: ["Authorization": "Bearer " + key], body: Data("{}".utf8), timeoutSeconds: 10, maximumResponseBytes: 1024)
        _ = try await events.send(event)
        _ = try await flags.send(endpoint: host.appendingPathComponent("v1/flags"), requestBody: Data("{}".utf8))
        SelfHostProtocol.hooks.set { _, _, _ in XCTFail("Foreign origin reached physical transport") }
        do { _ = try await EluV1URLSessionBatchTransport(protocolClasses: [SelfHostProtocol.self]).send(event); XCTFail("Cloud transport accepted self-host") } catch {}
        do { _ = try await flags.send(endpoint: URL(string: "https://ingest.elu.dev/v1/flags")!, requestBody: Data("{}".utf8)); XCTFail("Cloud fallback accepted") } catch {}
        XCTAssertThrowsError(try EluV1BatchAuthorizationSnapshot(siteKey: key, eventsEndpoint: event.url, expiresAt: Date().addingTimeInterval(30), eventBatchCount: 1, eventBatchBytes: 1024))
        _ = try EluV1BatchAuthorizationSnapshot(siteKey: key, eventsEndpoint: event.url, endpointPolicy: policy, expiresAt: Date().addingTimeInterval(30), eventBatchCount: 1, eventBatchBytes: 1024)
    }

    func testReplayOriginalOwnerAuthorizesCustomTransportThroughReopen() async throws {
        try await verifyReplayTransport(base: host)
        try await verifyReplayTransport(base: URL(string: host.absoluteString + "/elu/tenant-1")!)
    }

    private func verifyReplayTransport(base host: URL) async throws {
        let policy = try EluEndpointPolicy(apiHost: host)
        let h = try await DeliveryHarness.make(endpointPolicy: policy); defer { h.remove() }
        h.config = try config(base: host); try await h.install(); _ = try await h.append()
        await h.queue.close(); h.queue = try await h.reopen(); try await h.activate(support: h.generation)
        try await h.queue.ensureReplayDeliverySchema()
        let authority = try await h.deliveryAuthority()
        guard case let .claimed(claim) = try await h.queue.claimNextReplay(authority),
              let dispatch = try await h.queue.enrollReplayDispatch(claim, dispatchAllowed: { true }) else { return XCTFail("No original dispatch") }
        SelfHostProtocol.hooks.set { [host, key] req, client, instance in
            XCTAssertEqual(req.url, host.appendingPathComponent("v2/replay"))
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
            SelfHostProtocol.reply(req, client, instance, Data("{}".utf8))
        }
        let response = try await EluV2URLSessionReplayTransport(endpointPolicy: policy, protocolClasses: [SelfHostProtocol.self]).send(dispatch)
        XCTAssertEqual(response.status, 200)
        _ = try await h.queue.finishReplayClaim(claim, completion: .released)
        await h.queue.close()
    }

    func testStoreIdentityConsentBacklogAndFirstSessionAreIsolatedPerOrigin() async throws {
        try await verifyStoreIsolation(base: host, otherBase: URL(string: "https://other.example.test")!)
    }

    func testSameHostDifferentPrefixesHaveIndependentStoresAndNormalizedRestart() async throws {
        try await verifyStoreIsolation(base: URL(string: host.absoluteString + "/elu/tenant-1")!,
                                       otherBase: URL(string: host.absoluteString + "/elu/tenant-2")!)
    }

    func testFlagCacheAndAuthorityDoNotCrossPrefixesOrRootButSurviveNormalizedRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elu-prefix-flags-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = URL(string: host.absoluteString + "/a")!, b = URL(string: host.absoluteString + "/b")!
        let now = Date(timeIntervalSince1970: 1_785_888_090)
        let versions = try EluVersionContext(runtime: .init(name: "elu-ios", version: "0.2.0"), facade: .init(name: "Elu", version: "1"))
        let transport = PrefixFlagTransport()
        func open(_ base: URL) async throws -> (EluSQLiteRuntimeQueue, EluV1FlagClient) {
            let queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: directory,
                exactConstructorSiteKey: key, endpointPolicy: EluEndpointPolicy(apiHost: base),
                limits: EluRuntimeQueueLimits(), clock: { now })
            let client = try await EluV1FlagClient.make(runtime: queue, transport: transport, versions: versions)
            return (queue, client)
        }
        let (first, client) = try await open(a)
        guard case .allowed = await client.applyConfig(try config(base: a)),
              case .updated = await client.reload() else { return XCTFail("Prefix A flag evaluation failed") }
        let selected = await client.read("scope")
        XCTAssertEqual(selected, .found(value: .string(Array("only-a".utf16)), payload: nil))
        await first.close()
        for base in [host, b] {
            let (queue, other) = try await open(base)
            // An A authority/cache cannot be adopted merely by selecting the same site key.
            let before = await other.read("scope"); XCTAssertEqual(before, .missing)
            guard case .allowed = await other.applyConfig(try config(base: base)) else { return XCTFail("Own flags authority rejected") }
            let after = await other.read("scope"); XCTAssertEqual(after, .missing)
            await queue.close()
        }
        let (reopened, restored) = try await open(URL(string: a.absoluteString + "/")!)
        guard case .allowed = await restored.applyConfig(try config(base: a)) else { return XCTFail("Same prefix failed to reopen") }
        let cached = await restored.read("scope"); XCTAssertEqual(cached, selected)
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
        await reopened.close()
    }

    private func verifyStoreIsolation(base host: URL, otherBase: URL) async throws {
        let policy = try EluEndpointPolicy(apiHost: host)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("elu-origin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = EluEndpointPolicy.cloud, other = try EluEndpointPolicy(apiHost: otherBase)
        let normalized = try EluEndpointPolicy(apiHost: URL(string: host.absoluteString.replacingOccurrences(of: "https://analytics.example.test", with: "HTTPS://ANALYTICS.EXAMPLE.TEST") + "/")!)
        func open(_ selected: EluEndpointPolicy) async throws -> EluSQLiteRuntimeQueue {
            try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root, exactConstructorSiteKey: key, endpointPolicy: selected, limits: EluRuntimeQueueLimits(), clock: { Date(timeIntervalSince1970: 1_785_888_090) })
        }
        let a = try await open(policy), b = try await open(other), c = try await open(cloud)
        let first = try await a.snapshot(), second = try await b.snapshot(), third = try await c.snapshot()
        XCTAssertNotEqual(first.identity.anonymousId, second.identity.anonymousId)
        XCTAssertNotEqual(first.identity.anonymousId, third.identity.anonymousId)
        _ = try await a.registerStandaloneSuperProperties(["onlyA": .bool(true)])
        let now = Date(timeIntervalSince1970: 1_785_888_090), data = try config(base: host)
        let manager = EluV1ConfigManager(endpointPolicy: policy)
        _ = try manager.update(configData: data, now: now)
        let before = try await a.snapshot()
        let projection = try EluPrivacyStateProjector.project(context: manager.activePrivacyProjectionContext(now: now),
            input: .init(contextRevision: before.identity.contextRevision, identityOptedOut: false,
                timeZoneIdentifier: "America/Los_Angeles", evaluatedAt: now,
                appliedMasking: .init(text: .all, inputs: .all, images: .block),
                replaySampleDraw: 0, replaySessionEligible: true, replayBudgetRemainingSeconds: 60,
                localReplayTransports: []))
        guard case .activated = await a.submitCaptureAuthority(configData: data, effectivePrivacyStateData: projection.stateData) else { return XCTFail("Capture authority rejected") }
        let versions = try EluVersionContext(runtime: .init(name: "elu-ios", version: "0.2.0"), facade: .init(name: "Elu", version: "1"))
        guard case let .accepted(_, captured) = await a.capture(.init(kind: .capture, name: "only-a", occurredAt: now, properties: [:], versions: versions)) else { return XCTFail("Event rejected") }
        XCTAssertGreaterThan(captured.queuedCount, 0); XCTAssertNotNil(captured.identity.session)
        _ = try await a.setOptedOut(true, expectedGeneration: a.snapshot().generation)
        let saved = try await a.snapshot(); await a.close()
        let reopened = try await open(normalized), restored = try await reopened.snapshot()
        XCTAssertEqual(restored, saved)
        let otherState = try await b.snapshot(), cloudState = try await c.snapshot()
        XCTAssertEqual(otherState.queuedCount, 0); XCTAssertEqual(cloudState.queuedCount, 0)
        XCTAssertNil(otherState.identity.session); XCTAssertNil(cloudState.identity.session)
        XCTAssertFalse(otherState.identity.optedOut); XCTAssertFalse(cloudState.identity.optedOut)
        XCTAssertNil(otherState.identity.superProperties["onlyA"]); XCTAssertNil(cloudState.identity.superProperties["onlyA"])
        let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(namespace).path))
        XCTAssertNotEqual(policy.storageRoot(under: root), other.storageRoot(under: root))
        await reopened.close(); await b.close(); await c.close()
        func history(_ selected: EluEndpointPolicy) throws -> EluCaptureSessionHistory {
            let path = selected.storageRoot(under: root).appendingPathComponent(namespace).appendingPathComponent("runtime-state-v1.sqlite3").path
            var db: OpaquePointer?, statement: OpaquePointer?
            defer { sqlite3_close(db) }
            func check(_ actual: Int32, expected: Int32, operation: String) throws {
                guard actual == expected else {
                    let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
                    throw NSError(domain: "EluSelfHostFixtureSQLite", code: Int(actual), userInfo: [NSLocalizedDescriptionKey: "\(operation): \(message) (\(path))"])
                }
            }
            // These closed WAL stores can require shared-memory initialization
            // before the first SELECT. Match the runtime's read/write open mode,
            // then forbid SQL writes for this independent persisted-state probe.
            try check(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil), expected: SQLITE_OK, operation: "open")
            try check(sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil), expected: SQLITE_OK, operation: "query-only")
            try check(sqlite3_prepare_v2(db, "SELECT metadata FROM capture_session_history", -1, &statement, nil), expected: SQLITE_OK, operation: "prepare")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_step(statement), expected: SQLITE_ROW, operation: "step")
            let bytes = try XCTUnwrap(sqlite3_column_blob(statement, 0))
            return try EluCaptureSessionHistory.decode(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
        XCTAssertTrue(try history(policy).permits(XCTUnwrap(captured.identity.session)))
        XCTAssertEqual(try history(other), .unseen); XCTAssertEqual(try history(cloud), .unseen)
    }

    func testBothSDKOriginsAreExcludedBeforeObservationAndAfterRedirect() throws {
        let gate = EluNetworkObservationGate(budget: .init(), now: { 1 }), output = SelfHostEmission()
        gate.setForeground(true)
        gate.publish(context: .init(identityRevision: 0, contextRevision: 0, sessionID: nil), current: { true }) { _, _, _ in output.append() }
        let excluded: Set<String> = ["config.example.test", "analytics.example.test"]
        for name in excluded {
            XCTAssertNil(gate.begin(URLRequest(url: URL(string: "https://" + name + "/v1/events")!), excludedHosts: excluded))
            let observation = try XCTUnwrap(gate.begin(URLRequest(url: URL(string: "https://customer.example.test")!), excludedHosts: excluded)); observation.start()
            observation.finish(response: HTTPURLResponse(url: URL(string: "https://" + name)!, statusCode: 200, httpVersion: nil, headerFields: nil), failed: false)
        }
        XCTAssertEqual(output.count, 0)
    }

    func testPrefixedAPIBaseStillExcludesTheWholeSDKHostFromRequestMetrics() throws {
        let selected = try EluEndpointPolicy(apiHost: URL(string: host.absoluteString + "/elu/tenant-1")!)
        let excluded = Set([try XCTUnwrap(selected.declaredAPIOrigin?.host)])
        let gate = EluNetworkObservationGate(budget: .init(), now: { 1 }), output = SelfHostEmission()
        gate.setForeground(true)
        gate.publish(context: .init(identityRevision: 0, contextRevision: 0, sessionID: nil), current: { true }) { _, _, _ in output.append() }
        for path in ["/v1/events", "/elu/tenant-1/v1/events", "/elu/tenant-2/v1/flags", "/customer"] {
            XCTAssertNil(gate.begin(URLRequest(url: URL(string: host.absoluteString + path)!), excludedHosts: excluded))
        }
        let observation = try XCTUnwrap(gate.begin(URLRequest(url: URL(string: "https://customer.example.test/")!), excludedHosts: excluded))
        observation.start()
        observation.finish(response: HTTPURLResponse(url: URL(string: host.absoluteString + "/elu/tenant-2")!, statusCode: 200, httpVersion: nil, headerFields: nil), failed: false)
        XCTAssertEqual(output.count, 0)
    }

    private func config(base: URL? = nil) throws -> Data {
        let host = base ?? self.host
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Conformance/V2/fixtures/config-enabled.json"))
        return Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "https://ingest.elu.dev", with: host.absoluteString).replacingOccurrences(of: "https://assets.elu.dev", with: host.absoluteString).utf8)
    }
}
private actor PrefixFlagTransport: EluV1FlagTransport {
    private(set) var calls = 0
    func send(endpoint: URL, requestBody: Data) async throws -> Data {
        calls += 1
        XCTAssertEqual(endpoint.path, "/a/v1/flags")
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let identity = try XCTUnwrap(request["identity"] as? [String: Any])
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "requestId": try XCTUnwrap(request["requestId"]),
            "contextRevision": try XCTUnwrap(request["contextRevision"]),
            "identityRevision": try XCTUnwrap(identity["revision"]), "flagsRevision": "prefix-test",
            "evaluatedAt": EluRFC3339.string(from: Date(timeIntervalSince1970: 1_785_888_090)),
            "expiresAt": EluRFC3339.string(from: Date(timeIntervalSince1970: 1_785_888_120)),
            "flags": ["scope": "only-a"], "payloads": [:] as [String: Any],
        ])
    }
}
private final class SelfHostEmission: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func append() { lock.lock(); value += 1; lock.unlock() }
}
private final class SelfHostProtocol: URLProtocol, @unchecked Sendable {
    static let hooks = Hooks()
    final class Hooks: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (URLRequest, URLProtocolClient, URLProtocol) -> Void = { _, _, _ in }
        func set(_ next: @escaping (URLRequest, URLProtocolClient, URLProtocol) -> Void) { lock.lock(); value = next; lock.unlock() }
        func run(_ req: URLRequest, _ client: URLProtocolClient, _ original: URLProtocol) { lock.lock(); let next = value; lock.unlock(); next(req, client, original) }
    }
    static func reply(_ req: URLRequest, _ client: URLProtocolClient, _ original: URLProtocol, _ data: Data) {
        client.urlProtocol(original, didReceive: HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(original, didLoad: data); client.urlProtocolDidFinishLoading(original)
    }
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { if let client { Self.hooks.run(request, client, self) } }
    override func stopLoading() {}
}
