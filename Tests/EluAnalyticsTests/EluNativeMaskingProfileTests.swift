import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeMaskingProfileTests: XCTestCase {
    private let expectedHash = "sha256:f6e340ee9a350f07e3645dc5e30bc6383e27d0bb42b94e08d552c26a52418281"
    private let sensitiveHash = "sha256:3aae84c0ddeb5414d509433eb6285532bd90eea846a246787b9622c64d32da04"
    /// Exact bytes sealed by earlier SDK versions; queued chunks still carry them.
    private let tokenBlanket = Data(#"{"blockTraversal":"stop","configuredBlockRuleHandling":"deny-unresolved","contentAccess":"none","imageRule":"block","inputRule":"all","maskInheritance":"subtree","maskToken":"[masked]","opaqueViewRule":"block","placeholderToken":"Content hidden","profileKind":"elu-native-blanket-mask-v1","schemaVersion":1,"secureInputsMasked":true,"textRule":"all","webViewRule":"block"}"#.utf8)
    private let tokenSensitive = Data(#"{"blockTraversal":"stop","configuredBlockRuleHandling":"deny-unresolved","contentAccess":"native-text","imageRule":"block","inputRule":"all","maskInheritance":"subtree","maskToken":"[masked]","opaqueViewRule":"block","placeholderToken":"Content hidden","profileKind":"elu-native-sensitive-mask-v1","schemaVersion":1,"secureInputsMasked":true,"textRule":"sensitive","webViewRule":"block"}"#.utf8)

    func testSensitiveProfileIsClosedAndRequiresSensitivePolicyWithoutNativeRules() throws {
        let profile = EluNativeMaskingProfile.sensitiveMask()
        XCTAssertEqual(try EluNativeMaskingProfile.parse(profile.canonicalBytes), profile)
        XCTAssertEqual(profile.canonicalBytes.count, 468)
        XCTAssertEqual(profile.hash, sensitiveHash)
        XCTAssertTrue(profile.allowsOrdinaryText)
        XCTAssertEqual(profile.maskingClass, .sensitive); XCTAssertEqual(profile.rule, .star)
        XCTAssertEqual(profile.compatibility(with: try policy(text: "sensitive"), platform: .ios), .compatible)
        XCTAssertEqual(profile.compatibility(with: try policy(text: "all"), platform: .ios), .restrictivePolicy)
        let configured = try policy(text: "sensitive", rules: [rule("ios", "mask", "elu-unknown-native-v9")])
        XCTAssertEqual(profile.compatibility(with: configured, platform: .ios), .restrictivePolicy)
        XCTAssertEqual(EluNativeMaskingProfile.select(for: configured, platform: .ios), .blanketMask())
        XCTAssertEqual(EluNativeMaskingProfile.select(for: try policy(text: "sensitive"), platform: .ios), profile)
        XCTAssertEqual(EluNativeMaskingProfile.retention(of: profile.canonicalBytes,
            required: try policy(text: "all"), platform: .ios), .restrictivePolicy)
        XCTAssertEqual(EluNativeMaskingProfile.retention(of: EluNativeMaskingProfile.blanketMask().canonicalBytes,
            required: try policy(text: "sensitive"), platform: .ios), .compatible)
    }

    func testGoldenCanonicalBytesAndHash() throws {
        let profile = EluNativeMaskingProfile.blanketMask()
        XCTAssertEqual(profile.canonicalBytes.count, 461)
        XCTAssertEqual(profile.hash, expectedHash)
        XCTAssertEqual(profile.maskingClass, .blanket); XCTAssertEqual(profile.rule, .star)
        XCTAssertFalse(profile.allowsOrdinaryText)
        XCTAssertEqual(try EluV1StrictCanonicalJSON.parse(profile.canonicalBytes).canonicalData, profile.canonicalBytes)
        XCTAssertEqual(try EluNativeMaskingProfile.parse(profile.canonicalBytes), profile)
        let object = try object(profile.canonicalBytes)
        XCTAssertEqual(object.count, 16); XCTAssertNil(object["targetDialect"]); XCTAssertNil(object["maskToken"])
        XCTAssertEqual(object["contentAccess"] as? String, "masked-shape")
        XCTAssertEqual(object["textMask"] as? String, "star-non-whitespace-utf16")
        XCTAssertEqual(object["inputMask"] as? String, "star-per-utf16-unit")
        XCTAssertEqual((object["maskedTextMaxBytes"] as? NSNumber)?.intValue, EluNativeMaskText.maximumBytes)
    }

    func testStarProfileBytesMatchTheSharedContract() throws {
        let blanket = #"{"blockTraversal":"stop","configuredBlockRuleHandling":"deny-unresolved","contentAccess":"masked-shape","imageRule":"block","inputMask":"star-per-utf16-unit","inputRule":"all","maskInheritance":"subtree","maskedTextMaxBytes":4096,"opaqueViewRule":"block","placeholderToken":"Content hidden","profileKind":"elu-native-blanket-star-mask-v1","schemaVersion":2,"secureInputsMasked":true,"textMask":"star-non-whitespace-utf16","textRule":"all","webViewRule":"block"}"#
        let sensitive = #"{"blockTraversal":"stop","configuredBlockRuleHandling":"deny-unresolved","contentAccess":"native-text","imageRule":"block","inputMask":"star-per-utf16-unit","inputRule":"all","maskInheritance":"subtree","maskedTextMaxBytes":4096,"opaqueViewRule":"block","placeholderToken":"Content hidden","profileKind":"elu-native-sensitive-star-mask-v1","schemaVersion":2,"secureInputsMasked":true,"textMask":"star-non-whitespace-utf16","textRule":"sensitive","webViewRule":"block"}"#
        XCTAssertEqual(EluNativeMaskingProfile.blanketMask().canonicalBytes, Data(blanket.utf8))
        XCTAssertEqual(EluNativeMaskingProfile.sensitiveMask().canonicalBytes, Data(sensitive.utf8))
        XCTAssertEqual(EluV1StrictCanonicalJSON.hash(Data(blanket.utf8)), expectedHash)
        XCTAssertEqual(EluV1StrictCanonicalJSON.hash(Data(sensitive.utf8)), sensitiveHash)
    }

    func testEarlierTokenProfilesStillParseByClassButAreNeverSelected() throws {
        let blanket = try EluNativeMaskingProfile.parse(tokenBlanket)
        let sensitive = try EluNativeMaskingProfile.parse(tokenSensitive)
        XCTAssertEqual(blanket.hash, "sha256:fdb4151f4d1525b0bcf95d16099278b9d82a1e13e5eba381a1d19c4f35084d77")
        XCTAssertEqual(blanket.canonicalBytes.count, 372); XCTAssertEqual(sensitive.canonicalBytes.count, 387)
        XCTAssertEqual(blanket.maskingClass, .blanket); XCTAssertEqual(blanket.rule, .token)
        XCTAssertEqual(sensitive.maskingClass, .sensitive); XCTAssertEqual(sensitive.rule, .token)
        XCTAssertFalse(blanket.allowsOrdinaryText); XCTAssertTrue(sensitive.allowsOrdinaryText)
        XCTAssertEqual(blanket.textMasking, EluNativeMaskingProfile.blanketMask().textMasking)
        XCTAssertEqual(sensitive.textMasking, EluNativeMaskingProfile.sensitiveMask().textMasking)
        XCTAssertNotEqual(blanket, .blanketMask()); XCTAssertNotEqual(sensitive, .sensitiveMask())
        let ruleSets: [[[String: Any]]] = [[], [rule("ios", "mask", "elu-unknown-native-v9")]]
        for text in ["all", "sensitive"] {
            for rules in ruleSets {
                let selected = EluNativeMaskingProfile.select(for: try policy(text: text, rules: rules), platform: .ios)
                XCTAssertEqual(selected.rule, .star)
            }
        }
        // Queued chunks sealed before an upgrade remain retainable under the same class rules.
        XCTAssertEqual(EluNativeMaskingProfile.retention(of: tokenBlanket, required: try policy(), platform: .ios), .compatible)
        XCTAssertEqual(EluNativeMaskingProfile.retention(of: tokenSensitive, required: try policy(text: "sensitive"), platform: .ios), .compatible)
        XCTAssertEqual(EluNativeMaskingProfile.retention(of: tokenSensitive, required: try policy(text: "all"), platform: .ios), .restrictivePolicy)
    }

    func testEveryMissingOrAlteredFieldIsRejected() throws {
        for bytes in allProfiles {
            let original = try object(bytes)
            for key in original.keys {
                var altered = original; altered[key] = "unsupported"
                XCTAssertThrowsError(try EluNativeMaskingProfile.parse(canonical(altered)), key)
                var missing = original; missing.removeValue(forKey: key)
                XCTAssertThrowsError(try EluNativeMaskingProfile.parse(canonical(missing)), key)
            }
        }
    }

    func testMixingTokenAndStarFieldsIsRejected() throws {
        var star = try object(EluNativeMaskingProfile.blanketMask().canonicalBytes)
        star["maskToken"] = "[masked]"
        XCTAssertThrowsError(try EluNativeMaskingProfile.parse(canonical(star)))
        var token = try object(tokenBlanket)
        token["textMask"] = "star-non-whitespace-utf16"
        XCTAssertThrowsError(try EluNativeMaskingProfile.parse(canonical(token)))
        var widened = try object(EluNativeMaskingProfile.blanketMask().canonicalBytes)
        widened["maskedTextMaxBytes"] = 8_192
        XCTAssertThrowsError(try EluNativeMaskingProfile.parse(canonical(widened)))
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
        for bytes in allProfiles {
            let text = String(decoding: bytes, as: UTF8.self)
            var values = [text + "\n", " " + text]
            for number in [":1,", ":2,", ":4096,"] where text.contains(number) {
                let digits = number.dropFirst().dropLast()
                values += [text.replacingOccurrences(of: number, with: ":\(digits).0,"),
                           text.replacingOccurrences(of: number, with: ":\(digits)e0,")]
            }
            XCTAssertGreaterThanOrEqual(values.count, 4)
            for value in values {
                XCTAssertNotEqual(Data(value.utf8), bytes)
                XCTAssertThrowsError(try EluNativeMaskingProfile.parse(Data(value.utf8)))
            }
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

    private var allProfiles: [Data] {
        [EluNativeMaskingProfile.blanketMask().canonicalBytes, EluNativeMaskingProfile.sensitiveMask().canonicalBytes,
         tokenBlanket, tokenSensitive]
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
