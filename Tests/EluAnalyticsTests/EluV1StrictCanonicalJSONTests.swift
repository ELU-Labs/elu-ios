import Foundation
import XCTest
@testable import EluAnalytics

final class EluV1StrictCanonicalJSONTests: XCTestCase {
    func testUTF16OrderingEscapingAndHashGolden() throws {
        let input = Data(
            #"{"😀":"astral","z":"line\nquote\"slash\\","a":[3,true,null],"":"bmp"}"#.utf8
        )
        let document = try EluV1StrictCanonicalJSON.parse(input)
        XCTAssertEqual(
            document.canonicalData.base64EncodedString(),
            "eyJhIjpbMyx0cnVlLG51bGxdLCJ6IjoibGluZVxucXVvdGVcInNsYXNoXFwiLCLwn5iAIjoiYXN0cmFsIiwi7oCAIjoiYm1wIn0="
        )
        XCTAssertEqual(
            EluV1StrictCanonicalJSON.hash(document.canonicalData),
            "sha256:933b6c88095d83223339c4dd1cc4af77f5b8d07bf7f3a44535eb2595aaec5b16"
        )
    }

    func testExactNumericLexemesAndJCSLayoutGolden() throws {
        let input = Data(
            "[-0,1.0,4.5,2e-3,0.0000001,1e30,1e23,5e-324,1.7976931348623157e308,1424953923781206.25,333333333.33333329,9007199254740991,9007199254740993,9223372036854775807,-9223372036854775808,1e3]".utf8
        )
        let document = try EluV1StrictCanonicalJSON.parse(input)
        XCTAssertEqual(
            document.canonicalData.base64EncodedString(),
            "WzAsMSw0LjUsMC4wMDIsMWUtNywxZSszMCwxZSsyMyw1ZS0zMjQsMS43OTc2OTMxMzQ4NjIzMTU3ZSszMDgsMTQyNDk1MzkyMzc4MTIwNi4yLDMzMzMzMzMzMy4zMzMzMzMzLDkwMDcxOTkyNTQ3NDA5OTEsOTAwNzE5OTI1NDc0MDk5Myw5MjIzMzcyMDM2ODU0Nzc1ODA3LC05MjIzMzcyMDM2ODU0Nzc1ODA4LDEwMDBd"
        )
        XCTAssertEqual(
            EluV1StrictCanonicalJSON.hash(document.canonicalData),
            "sha256:f534f0c3097f167ad6354d1ccf232df1804d71092e2b3e5df4ed2dfd6ecb51bc"
        )
    }

    func testCanonicalizationDoesNotNormalizeUnicode() throws {
        let input = Data(#"{"é":"composed","é":"decomposed"}"#.utf8)
        let document = try EluV1StrictCanonicalJSON.parse(input)
        XCTAssertEqual(
            document.canonicalData.base64EncodedString(),
            "eyJlzIEiOiJkZWNvbXBvc2VkIiwiw6kiOiJjb21wb3NlZCJ9"
        )
        XCTAssertEqual(
            EluV1StrictCanonicalJSON.hash(document.canonicalData),
            "sha256:8117f7eb721338d1c046fc7a3905d1f77b7a920abc82436194992a55af52f571"
        )
    }

    func testAmbiguousOrUnsupportedJSONRejectsBeforeFoundationDecode() {
        for input in [
            #"{"a":1,"\u0061":2}"#,
            #"{"😀":1,"\ud83d\ude00":2}"#,
            #"{"value":"\ud800"}"#,
            #"{"value":"\udc00"}"#,
            #"{"value":1e400}"#,
        ] {
            XCTAssertThrowsError(try EluV1StrictCanonicalJSON.parse(Data(input.utf8)), input)
        }
    }

    func testFrozenConfigAndPrivacyProjections() throws {
        let config = try EluV1StrictCanonicalJSON.parse(fixture("config-enabled.json"))
        XCTAssertEqual(
            EluV1StrictCanonicalJSON.hash(config.canonicalData),
            "sha256:69da989f31a6a3133dcebcdb64cd7665c666eb6af5a8aa766bc0036d8736ca4f"
        )
        XCTAssertEqual(
            try config.canonicalObjectProperty("privacy").map(EluV1StrictCanonicalJSON.hash),
            "sha256:6b13dc5469370452e41767356bedd92bbbdf3acf8ff4024447d03b1f19ea72ce"
        )
        XCTAssertEqual(
            try EluV1ConfigManager.computedEffectivePolicyHash(
                for: fixture("privacy-allowed.json")
            ),
            "sha256:852aa75195a8a72e48ded6f286ea8634d83e64c55277207756632f7a60883ed3"
        )
        XCTAssertEqual(
            try EluV1ConfigManager.computedEffectivePolicyHash(
                for: fixture("privacy-blocked.json")
            ),
            "sha256:e0c5e50f3127f85b1530be39fced4cc7abeae535d3d50ca48acb30cfcca685f6"
        )
    }

    private func fixture(_ name: String) -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try! Data(
            contentsOf: root
                .appendingPathComponent("Conformance/V1/Fixtures", isDirectory: true)
                .appendingPathComponent(name)
        )
    }
}
