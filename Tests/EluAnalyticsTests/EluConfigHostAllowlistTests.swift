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
}
