import CryptoKit
import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeV3ConfigParserTests: XCTestCase {
    private let expectedHash = "sha256:b6913d8dc296baf84dce6c84e9ce598000c1698cca3407475588f46573d846c7"

    func testPublicIssuerGoldenHashAndInheritedPolicyAreExact() throws {
        let result = try parse(envelope())
        let raster = try XCTUnwrap(result.raster)
        XCTAssertEqual(raster.effectivePolicyHash, expectedHash)
        XCTAssertEqual(raster.revision, "privacy-golden-1")
        XCTAssertEqual(raster.endpoint.absoluteString, "https://ingest.elu.dev/v3/replay")
        XCTAssertEqual(raster.maximumRequestBytes, 5_242_880)
        XCTAssertEqual(result.base.privacy?.replay.minimumDurationSeconds, 5)
        XCTAssertEqual(result.base.privacy?.replay.sampleRate, 0.25)
        XCTAssertEqual(result.base.privacy?.regionPolicy.mode, .blockEuOnDevice)
        XCTAssertEqual(result.base.session?.idleTimeoutSeconds, 1_800)
        XCTAssertEqual(result.base.issuedAt.source, "2026-09-04T00:05:00.000Z")
        XCTAssertEqual(result.base.expiresAt.source, "2026-09-04T00:15:00.000Z")
        XCTAssertTrue(result.base.privacy?.masking.secureInputsMasked == true)
        XCTAssertEqual(result.base.capturePerformance?.sampleIntervalMilliseconds, 30_000)
    }

    func testOriginalEmbeddedBytesAndBothSemanticHashesRemainDistinct() throws {
        let original = Self.baseJSON.replacingOccurrences(of: "0.25", with: "2.5e-1")
            .replacingOccurrences(of: "site_golden", with: #"site_\u0067olden"#)
        let raster = try encode(try envelope()["raster"]!)
        let outer = Data((" { \"schemaVersion\": 3, \"configV2\": " + original
            + ", \"raster\": " + String(decoding: raster, as: UTF8.self) + " } ").utf8)
        let parsed = try EluNativeV3ConfigParser.parse(outer)
        XCTAssertEqual(parsed.data, outer)
        XCTAssertEqual(parsed.configV2Data, Data(original.utf8))
        XCTAssertNotEqual(parsed.configV2Data, parsed.baseCanonicalData)
        let originalBase = try EluV1ConfigManager.prepareConfig(Data(original.utf8), endpointPolicy: .cloud)
        XCTAssertEqual(parsed.baseCanonicalData, originalBase.canonicalData)
        XCTAssertEqual(parsed.baseSemanticHash, originalBase.semanticHash)
        XCTAssertEqual(parsed.basePrivacyHash, originalBase.policySourceHash)
        XCTAssertEqual(parsed.semanticHash, try parse(envelope()).semanticHash)
        XCTAssertNotEqual(EluV1StrictCanonicalJSON.hash(parsed.data),
                          EluV1StrictCanonicalJSON.hash(try encode(envelope())))
    }

    func testOriginalParserStillRejectsOuterV3AndAcceptsExtractedV2() throws {
        let bytes = try encode(envelope())
        XCTAssertThrowsError(try EluV1ConfigManager.prepareConfig(bytes, endpointPolicy: .cloud))
        let parsed = try EluNativeV3ConfigParser.parse(bytes)
        XCTAssertEqual(try EluV1ConfigManager.prepareConfig(parsed.configV2Data, endpointPolicy: .cloud)
            .semanticHash, parsed.baseSemanticHash)
    }

    func testAbsentBranchNeverGrantsRasterIncludingBrowserAndTerminalDocuments() throws {
        var native = try envelope(); native.removeValue(forKey: "raster")
        XCTAssertNil(try parse(native).raster)
        var browser = try base()
        set(&browser, ["capabilities", "replay", "replayProtocolGeneration"], "replay-v2-generation-1")
        set(&browser, ["capabilities", "replay", "transports"], [["codec": "elu-browser-dom-v1", "compression": "gzip"]])
        XCTAssertNil(try parse(["schemaVersion": 3, "configV2": browser]).raster)
        for status in ["disabled", "revoked"] {
            let terminal: [String: Any] = ["schemaVersion": 2, "revision": "terminal", "status": status,
                "issuedAt": "2026-09-04T00:05:00.000Z", "expiresAt": "2026-09-04T00:15:00.000Z", "reason": "policy"]
            XCTAssertNil(try parse(["schemaVersion": 3, "configV2": terminal]).raster)
            XCTAssertThrowsError(try parse(["schemaVersion": 3, "configV2": terminal, "raster": try envelope()["raster"]!]))
        }
    }

    func testExactNativeTuplesOnlyWhenRasterIsPresent() throws {
        var v1 = try envelope()
        set(&v1, ["configV2", "capabilities", "replay", "replayProtocolGeneration"], "protocol-generation-v1")
        set(&v1, ["configV2", "capabilities", "replay", "transports"], [["codec": "elu-native-wireframe-v1", "compression": "gzip"]])
        XCTAssertNotNil(try parse(v1).raster)
        for (codec, compression, generation) in [
            ("elu-native-wireframe-v1", "gzip", "protocol-generation-v2"),
            ("elu-native-wireframe-v2", "none", "protocol-generation-v2"),
            ("elu-browser-dom-v1", "gzip", "replay-v2-generation-1"),
            ("elu-native-raster-v1", "gzip", "native-raster-generation-v1"),
            ("unknown", "gzip", "unknown"),
        ] {
            var value = try envelope()
            set(&value, ["configV2", "capabilities", "replay", "replayProtocolGeneration"], generation)
            set(&value, ["configV2", "capabilities", "replay", "transports"], [["codec": codec, "compression": compression]])
            XCTAssertThrowsError(try parse(value), codec)
        }
        var mixed = try envelope()
        set(&mixed, ["configV2", "capabilities", "replay", "transports"], [
            ["codec": "elu-native-wireframe-v1", "compression": "gzip"],
            ["codec": "elu-native-wireframe-v2", "compression": "gzip"]])
        XCTAssertThrowsError(try parse(mixed))
    }

    func testEveryInheritedCaptureAndMaskingRestrictionIsPreserved() throws {
        let changes: [([String], Any)] = [
            (["features", "capture"], false), (["features", "replay"], false),
            (["privacy", "capture", "enabled"], false), (["privacy", "replay", "enabled"], false),
            (["privacy", "masking", "text"], "all"), (["privacy", "masking", "images"], "block"),
            (["privacy", "masking", "secureInputsMasked"], false), (["privacy", "regionPolicy", "mode"], "block"),
        ]
        for (path, value) in changes {
            var changed = try envelope(); set(&changed, ["configV2"] + path, value)
            try refreshPolicyHash(&changed)
            XCTAssertThrowsError(try parse(changed), path.joined(separator: "."))
        }
        for platform in ["ios", "android"] {
            var changed = try envelope()
            set(&changed, ["configV2", "privacy", "masking", "platformRules"], [
                ["platform": platform, "action": "mask", "targetDialect": "elu-native-class-v1", "target": "private"]])
            try refreshPolicyHash(&changed)
            XCTAssertThrowsError(try parse(changed), platform) { error in
                XCTAssertEqual(error as? EluNativeV3ConfigParser.Failure, .incompatibleBase)
            }
        }
    }

    func testAudienceAndPrivacyMutationsRequireNewWholePolicyHash() throws {
        var changed = try envelope()
        set(&changed, ["configV2", "replayAudience"], "new-devices")
        XCTAssertThrowsError(try parse(changed))
        try refreshPolicyHash(&changed)
        let accepted = try parse(changed)
        XCTAssertEqual(accepted.base.replayAudience, "new-devices")
        XCTAssertNotEqual(accepted.raster?.effectivePolicyHash, expectedHash)
        set(&changed, ["configV2", "privacy", "replay", "sampleRate"], 0.1)
        XCTAssertThrowsError(try parse(changed))
        try refreshPolicyHash(&changed)
        let reduced = try parse(changed)
        XCTAssertEqual(reduced.base.privacy?.replay.sampleRate, 0.1)
        // Independently derived with ECMAScript JSON.stringify and SHA-256.
        XCTAssertEqual(reduced.raster?.effectivePolicyHash,
            "sha256:bc2da02d73f818a5c392e345d416bf343de4f252dd087c56fc531aaa543daaee")
    }

    func testEffectiveRequestLimitCannotWidenOriginalSessionBudget() throws {
        for bound in [1_024, 5_242_880, 10_485_760] {
            var changed = try envelope(); set(&changed, ["configV2", "limits", "replayChunkBytes"], bound)
            XCTAssertEqual(try parse(changed).raster?.maximumRequestBytes, min(bound, 5_242_880))
            XCTAssertEqual(try parse(changed).base.limits?.replayChunkBytes, bound)
            XCTAssertEqual(try parse(changed).raster?.effectivePolicyHash, expectedHash)
        }
    }

    func testExactTimestampsAndOptionalOriginalGrantsAreNotReconstructed() throws {
        var value = try envelope()
        set(&value, ["configV2", "issuedAt"], "2026-09-04T01:05:00.123999999+01:00")
        set(&value, ["configV2", "expiresAt"], "2026-09-04T00:15:00.987654321Z")
        set(&value, ["configV2", "captureExceptions"], ["suppressionRules": [Any]()])
        let original = try encode(value["configV2"]!)
        let parsed = try parse(value)
        XCTAssertEqual(parsed.configV2Data, original)
        XCTAssertEqual(parsed.base.issuedAt.source, "2026-09-04T01:05:00.123999999+01:00")
        XCTAssertEqual(parsed.base.expiresAt.source, "2026-09-04T00:15:00.987654321Z")
        XCTAssertNotNil(parsed.base.captureExceptions)
        XCTAssertEqual(parsed.raster?.effectivePolicyHash, expectedHash)
        // This pure parser retains timestamps; currentness/expiry is exclusively
        // an original source-owner decision, not a renewed parser receipt.
    }

    func testRasterShapeIsClosedAtEveryLevel() throws {
        let paths: [[String]] = [[], ["raster"], ["raster", "privacy"], ["raster", "limits"]]
        for path in paths {
            var changed = try envelope(); set(&changed, path + ["unknown"], true)
            XCTAssertThrowsError(try parse(changed), path.joined(separator: "."))
        }
        let original = try envelope()["raster"] as! [String: Any]
        for key in original.keys {
            var raster = original; raster.removeValue(forKey: key)
            var changed = try envelope(); changed["raster"] = raster
            XCTAssertThrowsError(try parse(changed), key)
        }
        for key in ["privacy", "limits"] {
            for member in (original[key] as! [String: Any]).keys {
                var changed = try envelope(); set(&changed, ["raster", key, member], NSNull())
                XCTAssertThrowsError(try parse(changed), member)
            }
        }
        var null = try envelope(); null["raster"] = NSNull()
        XCTAssertThrowsError(try parse(null))
    }

    func testEveryFrozenRasterConstantAndPrivacyWitnessIsExact() throws {
        let changes: [([String], Any)] = [
            (["schemaVersion"], 2), (["replayContractVersion"], "2.0.0"), (["replaySchemaVersion"], 2),
            (["ackSchemaVersion"], 2), (["replayProtocolGeneration"], "protocol-generation-v2"),
            (["codec"], "elu-native-wireframe-v2"), (["compression"], "none"),
            (["platforms"], ["ios", "android"]), (["privacy", "revision"], "other"),
            (["privacy", "effectivePolicyHash"], "sha256:" + String(repeating: "0", count: 64)),
            (["privacy", "maskingProfileHash"], "sha256:" + String(repeating: "0", count: 64)),
            (["privacy", "declaredRegionsAllowed"], false), (["privacy", "inputCoverage"], "all"),
            (["privacy", "automaticInputDiscovery"], true), (["privacy", "unknownContentClassification"], true),
            (["privacy", "redactionBoundary"], "after-upload"), (["privacy", "requiredBindingBehavior"], "allow"),
        ]
        for (path, value) in changes {
            var changed = try envelope(); set(&changed, ["raster"] + path, value)
            XCTAssertThrowsError(try parse(changed), path.joined(separator: "."))
        }
        for key in Self.limits.keys {
            var changed = try envelope(); set(&changed, ["raster", "limits", key], Self.limits[key]! + 1)
            XCTAssertThrowsError(try parse(changed), key)
        }
    }

    func testOriginalEndpointTrustAndRasterOriginStayJoined() throws {
        for endpoint in ["https://other.example/v3/replay", "https://ingest.elu.dev/v2/replay",
                         "https://ingest.elu.dev/v3/replay?x=1", "https://ingest.elu.dev:443/v3/replay"] {
            var changed = try envelope(); set(&changed, ["raster", "endpoint"], endpoint)
            XCTAssertThrowsError(try parse(changed), endpoint)
        }
        var changed = try envelope(); set(&changed, ["configV2", "endpoints", "flags"], "https://other.example/v1/flags")
        XCTAssertThrowsError(try parse(changed))
        var cell = try envelope()
        for role in ["events", "flags", "replay"] {
            let path = role == "replay" ? "/v2/replay" : "/v1/" + role
            set(&cell, ["configV2", "endpoints", role], "https://35-224-68-29.sslip.io" + path)
        }
        set(&cell, ["configV2", "endpoints", "assets"], "https://35-224-68-29.sslip.io/sdk/")
        set(&cell, ["raster", "endpoint"], "https://35-224-68-29.sslip.io/v3/replay")
        XCTAssertThrowsError(try parse(cell))
        let policy = try EluEndpointPolicy(apiHost: XCTUnwrap(URL(string: "https://35-224-68-29.sslip.io")))
        XCTAssertEqual(try EluNativeV3ConfigParser.parse(encode(cell), endpointPolicy: policy)
            .raster?.endpoint.host, "35-224-68-29.sslip.io")
    }

    func testMalformedDuplicateOversizedAndWrongBaseVersionFailClosed() throws {
        for path in [["schemaVersion"], ["configV2", "schemaVersion"]] {
            var changed = try envelope(); set(&changed, path, 1)
            XCTAssertThrowsError(try parse(changed))
        }
        var changed = try envelope(); set(&changed, ["configV2", "expiresAt"], "2026-09-04T00:00:00.000Z")
        XCTAssertThrowsError(try parse(changed))
        let bytes = try encode(envelope()); let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertThrowsError(try EluNativeV3ConfigParser.parse(Data(text.dropLast().utf8) + Data(#","schemaVersion":3}"#.utf8)))
        XCTAssertThrowsError(try EluNativeV3ConfigParser.parse(bytes + Data("false".utf8)))
        let exact = bytes + Data(repeating: 0x20, count: 65_536 - bytes.count)
        XCTAssertNotNil(try EluNativeV3ConfigParser.parse(exact).raster)
        XCTAssertThrowsError(try EluNativeV3ConfigParser.parse(exact + Data([0x20])))
    }

    private func parse(_ value: [String: Any]) throws -> EluNativeV3ConfigParser.Parsed {
        try EluNativeV3ConfigParser.parse(encode(value))
    }
    private func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func base() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(Self.baseJSON.utf8)) as! [String: Any]
    }
    private func envelope() throws -> [String: Any] {
        ["schemaVersion": 3, "configV2": try base(), "raster": [
            "schemaVersion": 1, "endpoint": "https://ingest.elu.dev/v3/replay", "replayContractVersion": "3.0.0",
            "replaySchemaVersion": 3, "ackSchemaVersion": 3, "replayProtocolGeneration": "native-raster-generation-v1",
            "codec": "elu-native-raster-v1", "compression": "gzip", "platforms": ["android", "ios"],
            "privacy": ["schemaVersion": 1, "revision": "privacy-golden-1", "effectivePolicyHash": expectedHash,
                "maskingProfileHash": "sha256:e374338e6100edcad1d11de079f6bdfc24df043107628b83a559bb3e87206422",
                "declaredRegionsAllowed": true, "inputCoverage": "declared-regions", "automaticInputDiscovery": false,
                "unknownContentClassification": false, "redactionBoundary": "before-encoding",
                "requiredBindingBehavior": "deny-incomplete-or-stale"], "limits": Self.limits,
        ]]
    }
    private func set(_ object: inout [String: Any], _ path: [String], _ value: Any) {
        if path.count == 1 { object[path[0]] = value; return }
        var child = object[path[0]] as! [String: Any]
        set(&child, Array(path.dropFirst()), value); object[path[0]] = child
    }
    /// Foundation serialization is input, not canonical hash material. Keep the
    /// independent issuer goldens above to detect shared implementation drift.
    private func refreshPolicyHash(_ envelope: inout [String: Any]) throws {
        let base = envelope["configV2"] as! [String: Any]
        let privacy = base["privacy"] as! [String: Any]
        let material: [String: Any] = ["schemaVersion": 1, "policyRevision": privacy["revision"]!,
            "basePolicyRevision": privacy["revision"]!, "basePrivacy": privacy,
            "replayAudience": base["replayAudience"] ?? "all-devices", "declaredRegionsAllowed": true,
            "inputCoverage": "declared-regions", "automaticInputDiscovery": false, "unknownContentClassification": false,
            "redactionBoundary": "before-encoding", "requiredBindingBehavior": "deny-incomplete-or-stale",
            "maskingProfileHash": "sha256:e374338e6100edcad1d11de079f6bdfc24df043107628b83a559bb3e87206422", "limits": Self.limits]
        let canonical = try EluV1StrictCanonicalJSON.parse(encode(material)).canonicalData
        let digest = SHA256.hash(data: Data("elu-native-raster-effective-policy-v1\0".utf8) + canonical)
        set(&envelope, ["raster", "privacy", "effectivePolicyHash"],
            "sha256:" + digest.map { String(format: "%02x", $0) }.joined())
    }
    private static let limits = ["requestBytes": 5_242_880, "decodedPayloadBytes": 2_800_000,
        "pngBytes": 2_097_152, "imageEdgePixels": 2_048, "imagePixels": 1_048_576,
        "viewportEdge": 16_384, "minimumFrameIntervalSeconds": 1, "framesPerChunk": 1]
    private static let baseJSON = #"""
{
  "schemaVersion": 2,
  "revision": "config-v2-enabled-golden-1",
  "issuedAt": "2026-09-04T00:05:00.000Z",
  "expiresAt": "2026-09-04T00:15:00.000Z",
  "status": "enabled",
  "site": {
    "id": "site_golden"
  },
  "endpoints": {
    "events": "https://ingest.elu.dev/v1/events",
    "replay": "https://ingest.elu.dev/v2/replay",
    "flags": "https://ingest.elu.dev/v1/flags",
    "assets": "https://assets.elu.dev/sdk/"
  },
  "privacy": {
    "schemaVersion": 1,
    "revision": "privacy-golden-1",
    "capture": {
      "enabled": true
    },
    "replay": {
      "enabled": true,
      "sampleRate": 0.25,
      "minimumDurationSeconds": 5,
      "maximumDurationSeconds": 3600
    },
    "masking": {
      "text": "sensitive",
      "inputs": "all",
      "images": "allow",
      "secureInputsMasked": true,
      "platformRules": [
        {
          "platform": "browser",
          "action": "mask",
          "targetDialect": "elu-css-selector-v1",
          "target": ".private"
        }
      ]
    },
    "regionPolicy": {
      "mode": "block-eu-on-device",
      "evaluator": "elu-eu-timezone-v1"
    }
  },
  "features": {
    "capture": true,
    "replay": true,
    "flags": true,
    "assets": true
  },
  "capabilities": {
    "events": {
      "contractVersion": "1.0.0",
      "schemaVersion": 1
    },
    "mutations": {
      "contractVersion": "1.0.0",
      "schemaVersion": 1
    },
    "flags": {
      "contractVersion": "1.0.0",
      "schemaVersion": 1
    },
    "replay": {
      "replayContractVersion": "2.0.0",
      "replaySchemaVersion": 2,
      "replayProtocolGeneration": "protocol-generation-v2",
      "transports": [
        {
          "codec": "elu-native-wireframe-v2",
          "compression": "gzip"
        }
      ]
    }
  },
  "session": {
    "idleTimeoutSeconds": 1800,
    "maximumDurationSeconds": 86400
  },
  "limits": {
    "eventBatchCount": 100,
    "eventBatchBytes": 1048576,
    "replayChunkBytes": 5242880,
    "queueBytes": 16777216
  },
  "capturePerformance": {
    "memory": true,
    "long_tasks": false,
    "sample_interval_ms": 30000
  }
}
"""#
}
