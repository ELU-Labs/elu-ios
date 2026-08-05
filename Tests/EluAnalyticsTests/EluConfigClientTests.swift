import Foundation
import XCTest
@testable import EluAnalytics

final class EluConfigClientTests: XCTestCase {
    func testBuildsConfigURLWithSiteKeyAsOneEncodedComponent() {
        let url = EluConfigClient.requestURL(
            configHost: URL(string: "https://elu.dev")!,
            siteKey: "a/b c%?"
        )

        XCTAssertEqual(url?.absoluteString, "https://elu.dev/v1/a%2Fb%20c%25%3F/config")
    }

    func testPreservesExplicitDevelopmentBasePathAndPort() {
        let url = EluConfigClient.requestURL(
            configHost: URL(string: "http://localhost:8080/staging/")!,
            siteKey: "site_key-1"
        )

        XCTAssertEqual(url?.absoluteString, "http://localhost:8080/staging/v1/site_key-1/config")
    }

    func testRejectsAmbiguousOrInvalidOrigins() {
        XCTAssertNil(EluConfigClient.requestURL(configHost: URL(string: "https://elu.dev?x=1")!, siteKey: "site"))
        XCTAssertNil(EluConfigClient.requestURL(configHost: URL(string: "https://elu.dev#fragment")!, siteKey: "site"))
        XCTAssertNil(EluConfigClient.requestURL(configHost: URL(string: "file:///tmp")!, siteKey: "site"))
        XCTAssertNil(EluConfigClient.requestURL(configHost: URL(string: "https://elu.dev")!, siteKey: ""))
    }

    func testCacheFileNameCannotAddPathComponents() {
        XCTAssertEqual(EluConfigClient.cacheFileName(siteKey: "a/b c"), "config-a_b_c.json")
        XCTAssertEqual(EluConfigClient.cacheFileName(siteKey: "safe_Key-9"), "config-safe_Key-9.json")
    }
}
