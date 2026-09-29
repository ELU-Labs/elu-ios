import Foundation
import XCTest
@testable import EluAnalytics

final class EluConfigHostAllowlistTests: XCTestCase {
    func testDefaultOptionsResolveToTheProductionOrigin() {
        XCTAssertEqual(
            EluConfigHostAllowlist.resolve(EluSetupOptions()),
            .approved(URL(string: "https://elu.dev")!)
        )
    }

    func testApprovedHostsAreNormalizedToABareOrigin() {
        let cases: [(String, String)] = [
            ("https://elu.dev/", "https://elu.dev"),
            ("HTTPS://Staging.ELU.dev:443", "https://staging.elu.dev"),
            ("https://dev.elu.dev", "https://dev.elu.dev"),
            ("https://lab.elu.dev/", "https://lab.elu.dev"),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(
                EluConfigHostAllowlist.resolve(configHost: URL(string: raw)!, loopbackPermitted: false),
                .approved(URL(string: expected)!),
                raw
            )
        }
    }

    func testUnapprovedOriginsFailClosedWithAMachineReadableReason() {
        let cases: [(String, EluConfigHostRejection)] = [
            ("http://elu.dev", .unsupportedScheme),
            ("file:///tmp", .unsupportedScheme),
            ("https://elu.dev:8443", .untrustedPort),
            ("https://user:secret@elu.dev", .credentialsPresent),
            ("https://elu.dev/staging", .pathPresent),
            ("https://elu.dev?tenant=1", .queryPresent),
            ("https://elu.dev#fragment", .fragmentPresent),
            ("https://evil-elu.dev", .hostNotApproved),
            ("https://elu.dev.example.com", .hostNotApproved),
            ("https://api.elu.dev", .hostNotApproved),
            ("https://ingest.elu.dev", .hostNotApproved),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(
                EluConfigHostAllowlist.resolve(configHost: URL(string: raw)!, loopbackPermitted: true),
                .rejected(expected),
                raw
            )
        }
    }

    func testLoopbackIsAcceptedOnlyWhenTheBinaryPermitsIt() {
        let loopback = URL(string: "http://localhost:8080")!
        XCTAssertEqual(
            EluConfigHostAllowlist.resolve(configHost: loopback, loopbackPermitted: true),
            .approved(URL(string: "http://localhost:8080")!)
        )
        XCTAssertEqual(
            EluConfigHostAllowlist.resolve(configHost: loopback, loopbackPermitted: false),
            .rejected(.loopbackNotPermitted)
        )
        XCTAssertEqual(
            EluConfigHostAllowlist.resolve(
                configHost: URL(string: "https://127.0.0.1:8443/")!,
                loopbackPermitted: true
            ),
            .approved(URL(string: "https://127.0.0.1:8443")!)
        )
        XCTAssertEqual(
            EluConfigHostAllowlist.resolve(
                configHost: URL(string: "http://localhost:8080/staging/")!,
                loopbackPermitted: true
            ),
            .rejected(.pathPresent)
        )
    }

    func testLoopbackPermissionIsACompileTimeBuildProperty() {
        #if DEBUG
            XCTAssertTrue(EluConfigHostAllowlist.loopbackPermitted)
        #else
            XCTAssertFalse(EluConfigHostAllowlist.loopbackPermitted)
        #endif
    }

    // MARK: - Self-hosted instance

    private let cell = URL(string: "https://analytics.example.com")!

    func testDeclaredPathPrefixIsCanonicalAndCannotWidenTheConfigAllowlist() {
        let base = URL(string: "https://analytics.example.com/elu/tenant-1")!
        XCTAssertEqual(EluConfigHostAllowlist.resolve(
            configHost: URL(string: "HTTPS://Analytics.Example.com/elu/tenant-1/")!,
            apiHost: base, loopbackPermitted: false), .approved(base))
        for raw in ["https://analytics.example.com", "https://analytics.example.com/elu",
                    "https://analytics.example.com/elu/tenant-2", "https://analytics.example.com/elu/tenant-1/child"] {
            guard case .rejected = EluConfigHostAllowlist.resolve(configHost: URL(string: raw)!, apiHost: base) else {
                return XCTFail("Prefix widened: \(raw)")
            }
        }
        XCTAssertEqual(EluConfigHostAllowlist.resolve(configHost: base), .rejected(.pathPresent))
        let declaredCloudPath = URL(string: "https://elu.dev/tenant")!
        XCTAssertEqual(EluConfigHostAllowlist.resolve(configHost: declaredCloudPath, apiHost: declaredCloudPath), .approved(declaredCloudPath))
        XCTAssertEqual(EluConfigHostAllowlist.resolve(configHost: declaredCloudPath), .rejected(.pathPresent))
        // Selecting custom ingestion must not change an explicitly selected Cloud config origin.
        XCTAssertEqual(EluConfigHostAllowlist.resolve(configHost: URL(string: "https://elu.dev")!, apiHost: base),
                       .approved(URL(string: "https://elu.dev")!))
    }

    func testIrregularOrAmbiguousPathPrefixesAreRefusedRatherThanRewritten() {
        for path in ["//elu", "/elu//tenant", "/elu//", "/./elu", "/elu/../tenant",
                     "/%2e/elu", "/elu/.%2E/tenant", "/elu/%2f/tenant", "/elu%5cprivate",
                     "/elu%00", "/elu%20private", "/elu%7f"] {
            let value = URL(string: "https://analytics.example.com" + path)!
            XCTAssertNil(EluConfigHostAllowlist.selfHostedOrigin(value), path)
            guard case .rejected = EluConfigHostAllowlist.resolve(configHost: value, apiHost: value) else {
                return XCTFail("Irregular prefix accepted: \(path)")
            }
        }
    }

    func testASelfHostedConfigHostIsApprovedWhenItIsExactlyTheDeclaredApiHost() {
        for loopbackPermitted in [false, true] {
            XCTAssertEqual(
                EluConfigHostAllowlist.resolve(configHost: cell, apiHost: cell, loopbackPermitted: loopbackPermitted),
                .approved(cell)
            )
            // Case and a bare trailing slash are normalization, not a different origin.
            XCTAssertEqual(
                EluConfigHostAllowlist.resolve(
                    configHost: URL(string: "HTTPS://Analytics.Example.com/")!,
                    apiHost: URL(string: "https://analytics.example.com/")!,
                    loopbackPermitted: loopbackPermitted
                ),
                .approved(cell)
            )
        }
        XCTAssertEqual(
            EluConfigHostAllowlist.resolve(EluSetupOptions(configHost: cell, apiHost: cell)),
            .approved(cell)
        )
    }

    func testASelfHostedConfigHostIsRefusedWithoutADeclaredApiHost() {
        XCTAssertNil(EluSetupOptions().apiHost)
        XCTAssertNil(EluSetupOptions(configHost: cell).apiHost)
        XCTAssertEqual(
            EluConfigHostAllowlist.resolve(EluSetupOptions(configHost: cell)),
            .rejected(.hostNotApproved)
        )
    }

    func testASelfHostedConfigHostIsRefusedWhenItDiffersFromTheApiHostInAnyWay() {
        let attempts: [(String, String)] = [
            // plain http, on either side
            ("http://analytics.example.com", "https://analytics.example.com"),
            ("https://analytics.example.com", "http://analytics.example.com"),
            ("http://analytics.example.com", "http://analytics.example.com"),
            // a different or explicit port, even the https default
            ("https://analytics.example.com:8443", "https://analytics.example.com"),
            ("https://analytics.example.com:8443", "https://analytics.example.com:8443"),
            ("https://analytics.example.com:443", "https://analytics.example.com:443"),
            // a subdomain or parent of the declared host
            ("https://evil.analytics.example.com", "https://analytics.example.com"),
            ("https://example.com", "https://analytics.example.com"),
            // userinfo that makes the real host another
            ("https://analytics.example.com@evil.example", "https://analytics.example.com"),
            ("https://user:pw@analytics.example.com", "https://user:pw@analytics.example.com"),
            // a trailing-dot host
            ("https://analytics.example.com.", "https://analytics.example.com"),
            ("https://analytics.example.com.", "https://analytics.example.com."),
            // paths, queries and fragments
            ("https://analytics.example.com/v1", "https://analytics.example.com"),
            ("https://analytics.example.com?x=1", "https://analytics.example.com"),
            ("https://analytics.example.com#f", "https://analytics.example.com"),
            // loopback names stay under the debug-only loopback rule
            ("https://localhost", "https://localhost"),
            ("https://127.0.0.1", "https://127.0.0.1"),
            ("https://10.0.2.2", "https://10.0.2.2"),
            // a different host altogether
            ("https://other.example", "https://analytics.example.com"),
        ]
        for (configHost, apiHost) in attempts {
            let resolution = EluConfigHostAllowlist.resolve(
                configHost: URL(string: configHost)!,
                apiHost: URL(string: apiHost)!,
                loopbackPermitted: false
            )
            guard case .rejected = resolution else {
                XCTFail("\(configHost) vs \(apiHost) was \(resolution)")
                continue
            }
        }
    }

    func testValidApiDeclarationPreservesCloudAndInvalidLoopbackDeclarationFailsClosed() {
        XCTAssertEqual(
            EluConfigHostAllowlist.resolve(
                configHost: URL(string: "https://elu.dev")!,
                apiHost: cell,
                loopbackPermitted: false
            ),
            .approved(URL(string: "https://elu.dev")!)
        )
        XCTAssertEqual(
            EluConfigHostAllowlist.resolve(
                configHost: URL(string: "http://localhost:8080")!,
                apiHost: URL(string: "http://localhost:8080")!,
                loopbackPermitted: false
            ),
            .rejected(.hostNotApproved)
        )
    }

    // MARK: - Setup enforces the allowlist

    func testSetupWithAnUnapprovedConfigHostLeavesTheSdkIdle() throws {
        let factory = SelectorSpy()
        let core = EluCore(backendFactory: factory.factory)
        core.setup(siteKey: "elu_pk_allowlist_idle", options: EluSetupOptions(configHost: cell))
        core.dispatch(.capture(event: "held", properties: nil))
        _ = core.bufferDropCountForTesting()

        // Rejection precedes the owned configuration source and runtime construction.
        XCTAssertNil(core.backendForTesting())
        XCTAssertTrue(factory.requestedSelections().isEmpty)
    }
}
