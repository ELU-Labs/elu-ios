import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeMaskingProfileTests: XCTestCase {
    private let expectedHash = "sha256:fdb4151f4d1525b0bcf95d16099278b9d82a1e13e5eba381a1d19c4f35084d77"

    func testGoldenCanonicalBytesAndHash() throws {
        let profile = EluNativeMaskingProfile.blanketMask()
        XCTAssertEqual(profile.canonicalBytes.count, 372)
        XCTAssertEqual(profile.hash, expectedHash)
        XCTAssertEqual(try EluV1StrictCanonicalJSON.parse(profile.canonicalBytes).canonicalData, profile.canonicalBytes)
        XCTAssertEqual(try EluNativeMaskingProfile.parse(profile.canonicalBytes), profile)
        let object = try object(profile.canonicalBytes)
        XCTAssertEqual(object.count, 14); XCTAssertNil(object["targetDialect"])
    }

    func testEveryMissingOrAlteredFieldIsRejected() throws {
        let original = try object(EluNativeMaskingProfile.blanketMask().canonicalBytes)
        for key in original.keys {
            var altered = original; altered[key] = "unsupported"
            XCTAssertThrowsError(try EluNativeMaskingProfile.parse(canonical(altered)), key)
            var missing = original; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try EluNativeMaskingProfile.parse(canonical(missing)), key)
        }
    }

    func testExtraDialectAndArbitraryContentAreRejected() throws {
        for key in ["targetDialect", "text", "url", "nativeClass", "resolvedMaskSelectors"] {
            var value = try object(EluNativeMaskingProfile.blanketMask().canonicalBytes)
            value[key] = "PRIVATE_UNTRUSTED_CONTENT"
            XCTAssertThrowsError(try EluNativeMaskingProfile.parse(canonical(value)))
        }
    }

    func testDuplicateAndEscapedDuplicateAreRejectedBeforeDictionaryBridging() {
        let prefix = String(decoding: EluNativeMaskingProfile.blanketMask().canonicalBytes.dropLast(), as: UTF8.self)
        for suffix in [",\"textRule\":\"all\"}", ",\"text\\u0052ule\":\"all\"}"] {
            XCTAssertThrowsError(try EluNativeMaskingProfile.parse(Data((prefix + suffix).utf8))) {
                XCTAssertEqual($0 as? EluV1StrictCanonicalJSONError, .duplicateObjectKey)
            }
        }
    }

    func testNoncanonicalEncodingAndNumericSpellingsAreRejected() {
        let text = String(decoding: EluNativeMaskingProfile.blanketMask().canonicalBytes, as: UTF8.self)
        for value in [text + "\n", " " + text, text.replacingOccurrences(of: ":1", with: ":1.0"),
                      text.replacingOccurrences(of: ":1", with: ":1e0")] {
            XCTAssertThrowsError(try EluNativeMaskingProfile.parse(Data(value.utf8)))
        }
    }

    func testInvalidUTF8RootsAndBoundsAreRejected() {
        for value in [Data(), Data([255]), Data("[]".utf8), Data("null".utf8), Data(repeating: 32, count: 1_025)] {
            XCTAssertThrowsError(try EluNativeMaskingProfile.parse(value))
        }
    }

    func testImmutableBytesCannotBeChangedThroughCopy() throws {
        let profile = EluNativeMaskingProfile.blanketMask()
        var copy = profile.canonicalBytes; copy[0] = 0
        XCTAssertEqual(profile.hash, expectedHash)
        XCTAssertThrowsError(try EluNativeMaskingProfile.parse(copy))
    }

    func testParsedProfileNeverRetainsCallerOwnedMutableBuffer() throws {
        let original = EluNativeMaskingProfile.blanketMask().canonicalBytes
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: original.count, alignment: 1)
        defer { pointer.deallocate() }
        original.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: original.count)
        let aliased = Data(bytesNoCopy: pointer, count: original.count, deallocator: .none)
        let parsed = try EluNativeMaskingProfile.parse(aliased)
        pointer.storeBytes(of: UInt8(0), as: UInt8.self)
        XCTAssertEqual(aliased[0], 0, "fixture must expose the externally mutable buffer")
        XCTAssertEqual(parsed.canonicalBytes, original)
        XCTAssertEqual(parsed.hash, expectedHash)
    }

    func testBlanketProfileSatisfiesEveryClosedTopLevelMaskingPolicy() throws {
        let profile = EluNativeMaskingProfile.blanketMask()
        for text in ["all", "sensitive"] {
            for inputs in ["all", "sensitive"] {
                for images in ["allow", "block"] {
                    let required = try policy(text: text, inputs: inputs, images: images)
                    XCTAssertEqual(profile.compatibility(with: required, platform: .ios), .compatible)
                    XCTAssertEqual(profile.compatibility(with: required, platform: .android), .compatible)
                }
            }
        }
    }

    func testAllApplicableBlockRulesDenyWithoutInterpretingTargets() throws {
        let profile = EluNativeMaskingProfile.blanketMask()
        for platform in [EluV1Platform.ios, .android] {
            for dialect in ["elu-css-selector-v1", "elu-unknown-native-v9"] {
                let required = try policy(rules: [rule(platform.rawValue, "block", dialect)])
                XCTAssertEqual(profile.compatibility(with: required, platform: platform), .unresolvedBlockRule)
                XCTAssertEqual(EluNativeMaskingProfile.retention(of: profile.canonicalBytes, required: required, platform: platform), .restrictivePolicy)
            }
        }
    }

    func testMaskOnlyAndOtherPlatformRulesDoNotClaimTargetRecognition() throws {
        let profile = EluNativeMaskingProfile.blanketMask()
        let required = try policy(rules: [rule("ios", "mask", "elu-unknown-native-v9"), rule("android", "block", "elu-unknown-native-v9")])
        XCTAssertEqual(profile.compatibility(with: required, platform: .ios), .compatible)
        XCTAssertEqual(profile.compatibility(with: required, platform: .android), .unresolvedBlockRule)
        XCTAssertNil(try object(profile.canonicalBytes)["targetDialect"])
    }

    func testUnavailablePolicyIsDistinctFromRestrictivePolicy() throws {
        let profile = EluNativeMaskingProfile.blanketMask()
        XCTAssertEqual(profile.compatibility(with: nil, platform: .ios), .policyUnavailable)
        XCTAssertEqual(EluNativeMaskingProfile.retention(of: profile.canonicalBytes, required: nil, platform: .ios), .policyUnavailable)
        XCTAssertEqual(EluNativeMaskingProfile.retention(of: Data(), required: nil, platform: .ios), .policyUnavailable)
        XCTAssertEqual(profile.compatibility(with: try policy(), platform: .browser), .unsupportedPlatform)
    }

    func testUnknownStoredProfileNeverBecomesCompatible() throws {
        let profile = EluNativeMaskingProfile.blanketMask()
        XCTAssertEqual(EluNativeMaskingProfile.retention(of: Data("{}".utf8), required: try policy(), platform: .ios), .unrecognizedStoredProfile)
        XCTAssertEqual(EluNativeMaskingProfile.retention(of: profile.canonicalBytes, required: try policy(), platform: .ios), .compatible)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func canonical(_ value: [String: Any]) throws -> Data {
        try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: value)).canonicalData
    }
    private func rule(_ platform: String, _ action: String, _ dialect: String) -> [String: Any] {
        ["platform": platform, "action": action, "targetDialect": dialect, "target": "opaque-private-target"]
    }
    private func policy(text: String = "all", inputs: String = "all", images: String = "block",
                        rules: [[String: Any]] = []) throws -> EluV1MaskingPolicy {
        let value: [String: Any] = ["text": text, "inputs": inputs, "images": images,
                                  "secureInputsMasked": true, "platformRules": rules]
        return try JSONDecoder().decode(EluV1MaskingPolicy.self, from: canonical(value))
    }
}
