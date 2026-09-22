import Foundation
import XCTest
@testable import EluAnalytics

final class EluSealedReplayPolicyTests: XCTestCase {
    func testNoSessionOrNativeLedgerIsNeededForCurrentPolicy() async throws {
        let h = try await SealedPolicyTestHarness.make(seed: false); defer { h.base.remove() }
        let identity = try await h.identity()
        XCTAssertNil(identity.identity.session)
        let (manager, observation) = try h.observation(identity)
        XCTAssertNotNil(try manager.authorizeSealedReplayDelivery(policyObservation: observation, identity: identity, now: h.base.now))
        let noProof = EluV1ConfigManager(); _ = try noProof.update(configData: h.base.config, now: h.base.now)
        XCTAssertNil(try noProof.authorizeSealedReplayDelivery(policyObservation: observation, identity: identity, now: h.base.now))
        await h.base.queue.close()
    }

    func testCaptureOnlySampleDurationAndMinimumChangesDoNotChangeSealedPermission() async throws {
        for rate in [0.0, 1.0] {
            let h = try await SealedPolicyTestHarness.make(seed: false); defer { h.base.remove() }
            try h.changeConfig { root in
                var privacy = root["privacy"] as! [String: Any], replay = privacy["replay"] as! [String: Any]
                replay["sampleRate"] = rate; replay["minimumDurationSeconds"] = 0; replay["maximumDurationSeconds"] = 1
                privacy["replay"] = replay; root["privacy"] = privacy
            }
            let identity = try await h.identity(), (manager, observed) = try h.observation(identity)
            XCTAssertNotNil(try manager.authorizeSealedReplayDelivery(policyObservation: observed, identity: identity, now: h.base.now))
            await h.base.queue.close()
        }
    }

    func testRegionAndConsentRemainActualCurrentRestrictions() async throws {
        let h = try await SealedPolicyTestHarness.make(seed: false); defer { h.base.remove() }
        let identity = try await h.identity()
        try h.changeConfig { root in
            var privacy = root["privacy"] as! [String: Any]
            privacy["regionPolicy"] = ["mode": "block-eu-on-device", "evaluator": "elu-eu-timezone-v1"]; root["privacy"] = privacy
        }
        for zone in [nil, "", "Europe/Paris", "America/Los_Angeles"] as [String?] {
            let (manager, observed) = try h.observation(identity, zone: zone)
            XCTAssertEqual(try manager.authorizeSealedReplayDelivery(policyObservation: observed, identity: identity, now: h.base.now) != nil,
                zone == "America/Los_Angeles")
        }
        var opted = identity.identity; opted.optedOut = true
        let optedIdentity = EluIdentitySnapshot(identity: opted, streamId: identity.streamId, nextSequence: identity.nextSequence, flagContext: identity.flagContext)
        let (manager, observed) = try h.observation(optedIdentity)
        XCTAssertNil(try manager.authorizeSealedReplayDelivery(policyObservation: observed, identity: optedIdentity, now: h.base.now))
        await h.base.queue.close()
    }

    func testOriginalConfigAndCurrentIdentityMustMatchObservation() async throws {
        let h = try await SealedPolicyTestHarness.make(seed: false); defer { h.base.remove() }
        let identity = try await h.identity(), (manager, observed) = try h.observation(identity)
        var changed = identity.identity; changed.contextRevision += 1
        let laterIdentity = EluIdentitySnapshot(identity: changed, streamId: identity.streamId, nextSequence: identity.nextSequence, flagContext: identity.flagContext)
        XCTAssertNil(try manager.authorizeSealedReplayDelivery(policyObservation: observed, identity: laterIdentity, now: h.base.now))
        try h.changeConfig { root in
            var features = root["features"] as! [String: Any]; features["replay"] = false; root["features"] = features
        }
        _ = try manager.update(configData: h.base.config, now: h.base.now)
        XCTAssertNil(try manager.authorizeSealedReplayDelivery(policyObservation: observed, identity: identity, now: h.base.now))
        await h.base.queue.close()
    }

    func testUnresolvedBlockRuleCannotBecomeBlanketMaskPermission() async throws {
        let h = try await SealedPolicyTestHarness.make(seed: false); defer { h.base.remove() }
        try h.addBlockRule()
        let identity = try await h.identity(), (manager, observed) = try h.observation(identity)
        XCTAssertEqual(observed.profileCompatibility, .unresolvedBlockRule)
        XCTAssertNil(try manager.authorizeSealedReplayDelivery(policyObservation: observed, identity: identity, now: h.base.now))
        await h.base.queue.close()
    }
}
