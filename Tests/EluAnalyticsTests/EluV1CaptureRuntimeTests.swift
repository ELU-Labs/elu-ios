import Foundation
import SQLite3
import XCTest
@testable import EluAnalytics

final class EluV1CaptureRuntimeTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_785_801_660)

    func testRemoteQueueQuotaAppliesBeforeReplayStorageOrAnyNativeRootExists() async throws {
        for schemaVersion in [1, 2] {
            try await withTemporaryDirectory { root in
                let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
                let queue = try await makeCaptureQueue(root: root, clock: clock)
                let data = try quotaConfig(bytes: 1_024, schemaVersion: schemaVersion)
                guard case .activated = await queue.submitCaptureAuthority(configData: data,
                    effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)) else {
                    return XCTFail("Expected validated config")
                }
                let before = try await queue.snapshot()
                let result = await queue.capture(command(kind: .capture, name: "headless_oversize", occurredAt: clock.wall(),
                    properties: ["value": .string(String(repeating: "x", count: 2_048))]))
                guard case let .rejected(.queueLimit, after) = result else {
                    await queue.close()
                    return XCTFail("Remote quota must bind event admission without replay schema or a UIKit root")
                }
                XCTAssertEqual(after, before, "Quota rejection must not create a session or advance sequence")
                let records = try await queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
                XCTAssertTrue(records.isEmpty)
                await queue.close()
            }
        }
    }

    func testRemoteQueueQuotaReappliesOnRestartBeforeNewCapture() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let data = try quotaConfig(bytes: 4_096)
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            _ = await queue.submitCaptureAuthority(configData: data,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true))
            guard case .accepted = await queue.capture(command(kind: .capture, name: "before_restart", occurredAt: clock.wall())) else {
                return XCTFail("Expected an event below the current quota")
            }
            let expected = try await queue.snapshot()
            await queue.close()
            let reopened = try await makeCaptureQueue(root: root, clock: clock)
            guard case .rejected(.authorityAbsent, _) = await reopened.capture(command(kind: .capture, name: "no_authority", occurredAt: clock.wall())) else {
                return XCTFail("Stored queue state cannot authorize fresh capture")
            }
            guard case .activated = await reopened.submitCaptureAuthority(configData: data,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)) else {
                return XCTFail("Expected the same still-valid config to be revalidated")
            }
            let result = await reopened.capture(command(kind: .capture, name: "after_restart", occurredAt: clock.wall(),
                properties: ["value": .string(String(repeating: "x", count: 4_096))]))
            guard case let .rejected(.queueLimit, actual) = result else {
                await reopened.close()
                return XCTFail("Revalidated remote quota must apply after restart")
            }
            XCTAssertEqual(actual, expected)
            await reopened.close()
        }
    }

    func testRemoteQueueQuotaLoweringPreservesBacklogAndRaisingReplacesOldReplayLimit() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            let large = command(kind: .capture, name: "existing", occurredAt: clock.wall(),
                properties: ["value": .string(String(repeating: "x", count: 4_096))])
            _ = await queue.submitCaptureAuthority(configData: try quotaConfig(bytes: 32_768),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true))
            guard case .accepted = await queue.capture(large) else { return XCTFail("Expected initial event") }
            let before = try await queue.snapshot()
            let records = try await queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            let lower = try quotaConfig(bytes: 1_024, issuedSecond: 10)
            guard case .activated = await queue.submitCaptureAuthority(configData: lower,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)) else {
                return XCTFail("Expected lower quota to activate")
            }
            let result = await queue.capture(command(kind: .capture, name: "blocked_by_backlog", occurredAt: clock.wall()))
            guard case let .rejected(.queueLimit, unchanged) = result else {
                await queue.close()
                return XCTFail("Existing backlog exceeding a lower quota must prevent new admission")
            }
            XCTAssertEqual(unchanged, before)
            let retained = try await queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(retained, records, "A new quota must not delete already accepted records")

            // Install the old limit in replay storage, then replace only the
            // event authority. Fresh event quota cannot depend on a replay pass.
            try await queue.ensureReplaySchema()
            let manager = EluV1ConfigManager()
            _ = try manager.update(configData: lower, now: clock.wall())
            let identity = try XCTUnwrap(manager.validatedCandidateIdentity())
            _ = try await queue.reconcileReplayConfiguration(configData: lower,
                expectedConfigWitness: EluV2ReplayConfigWitness(issuedAt: identity.issuedAt, semanticHash: identity.semanticHash),
                supportedProtocolGeneration: nil, mayRetainProfile: { _ in false })
            guard case .activated = await queue.submitCaptureAuthority(configData: try quotaConfig(bytes: 65_536, issuedSecond: 20),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)) else {
                return XCTFail("Expected increased quota to activate")
            }
            guard case .accepted = await queue.capture(large) else {
                await queue.close()
                return XCTFail("A stale replay ledger must not permanently pin the old event quota")
            }
            await queue.close()
        }
    }

    func testRemoteQueueQuotaFromSupersededSourceCannotReplaceCurrentLimit() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let gate = sourceGate(clock)
            let lower = try quotaConfig(bytes: 1_024)
            let oldSource = try publishSource(gate, data: lower, clock: clock)
            let queue = try await makeCaptureQueue(root: root, clock: clock, configurationGate: gate)
            _ = await queue.submitCaptureAuthority(configData: lower,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true), sourceWitness: oldSource)
            let higher = try quotaConfig(bytes: 32_768, issuedSecond: 10)
            let current = try publishSource(gate, data: higher, clock: clock)
            guard case .activated = await queue.submitCaptureAuthority(configData: higher,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true), sourceWitness: current) else {
                return XCTFail("Expected current source to activate")
            }
            guard case .terminated = await queue.submitCaptureAuthority(configData: lower,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true), sourceWitness: oldSource) else {
                return XCTFail("Superseded source must be rejected")
            }
            guard case .accepted = await queue.capture(command(kind: .capture, name: "current_quota", occurredAt: clock.wall(),
                properties: ["value": .string(String(repeating: "x", count: 2_048))])) else {
                return XCTFail("The current larger quota must survive rejected stale input")
            }
            await queue.close()
        }
    }

    func testRemoteQueueQuotaAlsoBoundsOwnedWireMutationsAtomically() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            _ = await queue.submitCaptureAuthority(configData: try quotaConfig(bytes: 1_024),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true))
            let before = try await queue.snapshot()
            do {
                _ = try await queue.applyOwnedMutation(.setPersonProperties(
                    set: ["value": .string(String(repeating: "x", count: 2_048))], setOnce: [:], unset: []),
                    versions: command(kind: .capture, name: "unused", occurredAt: clock.wall()).versions,
                    expectedGeneration: before.generation)
                XCTFail("Wire mutations share the current server queue quota")
            } catch { XCTAssertEqual(error as? EluRuntimeQueueError, .queueByteLimitExceeded) }
            let after = try await queue.snapshot()
            XCTAssertEqual(after, before)
            await queue.close()
        }
    }

    private func quotaConfig(bytes: Int, issuedSecond: Int = 0, schemaVersion: Int = 2) throws -> Data {
        try config { object in
            var limits = try XCTUnwrap(object["limits"] as? [String: Any])
            limits["queueBytes"] = bytes; object["limits"] = limits
            object["revision"] = "queue-quota-\(issuedSecond)"
            object["issuedAt"] = String(format: "2026-08-04T00:00:%02d.000Z", issuedSecond)
            if schemaVersion == 2 {
                let fixture = fixtureURL("config-enabled.json").deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("V2/fixtures/config-enabled.json")
                let v2 = try jsonObject(Data(contentsOf: fixture))
                object["schemaVersion"] = 2; object["capabilities"] = v2["capabilities"]; object["endpoints"] = v2["endpoints"]
            }
        }
    }

    func testPassivePerformancePreservesIdleBoundaryAcrossRestartAndNeverCreatesSession() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let configData = try config { object in
                var session = try XCTUnwrap(object["session"] as? [String: Any])
                session["idleTimeoutSeconds"] = 60
                object["session"] = session
            }
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            _ = await queue.submitCaptureAuthority(configData: configData, effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true))
            let initialSample = await queue.capturePerformanceSample(command(kind: .capture, name: "$performance_sample", occurredAt: clock.wall()), admissionGuard: { true })
            guard case .rejected(.invalidEvent, _) = initialSample else { return XCTFail("A sample cannot create a session") }
            guard case let .accepted(_, first) = await queue.capture(command(kind: .capture, name: "user_action", occurredAt: clock.wall())) else {
                return XCTFail("Expected initial user activity")
            }
            clock.advance(seconds: 59)
            guard case let .accepted(_, sampled) = await queue.capturePerformanceSample(command(kind: .capture, name: "$performance_sample", occurredAt: clock.wall()), admissionGuard: { true }) else {
                return XCTFail("Expected a sample in the existing live session")
            }
            XCTAssertEqual(sampled.identity.session, first.identity.session)
            XCTAssertEqual(sampled.identity.updatedAt, first.identity.updatedAt)
            await queue.close()

            let reopened = try await makeCaptureQueue(root: root, clock: clock)
            let restored = try await reopened.snapshot()
            XCTAssertEqual(restored.identity.session, first.identity.session)
            _ = await reopened.submitCaptureAuthority(configData: configData, effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true))
            clock.advance(seconds: 1)
            guard case .rejected(.invalidEvent, _) = await reopened.capturePerformanceSample(command(kind: .capture, name: "$performance_sample", occurredAt: clock.wall()), admissionGuard: { true }) else {
                return XCTFail("A sample at the idle deadline cannot resume the session")
            }
            guard case let .accepted(_, next) = await reopened.capture(command(kind: .capture, name: "next_user_action", occurredAt: clock.wall())) else {
                return XCTFail("Expected a fresh session")
            }
            XCTAssertNotEqual(next.identity.session?.id, first.identity.session?.id)
            await reopened.close()
        }
    }

    func testCaptureAuthorityOwnsSessionPropertiesConsentAndGeneration() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let queue = try await makeCaptureQueue(root: root, clock: clock)

            let activated = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            guard case .activated = activated else { return XCTFail("Expected authority") }

            clock.advance(seconds: 1)
            let first = await queue.capture(
                command(
                    kind: .capture,
                    name: "first",
                    occurredAt: clock.wall(),
                    properties: ["source": .string("explicit")]
                )
            )
            guard case let .accepted(firstRecord, firstSnapshot) = first,
                  case let .event(firstEvent) = firstRecord
            else {
                return XCTFail("Expected first capture")
            }
            XCTAssertEqual(firstSnapshot.queuedCount, 1)
            XCTAssertNotNil(firstSnapshot.identity.session)
            XCTAssertEqual(firstEvent.properties["source"], .string("explicit"))
            XCTAssertEqual(firstEvent.properties["$elu_contract_version"], .string("1.0.0"))
            XCTAssertEqual(firstEvent.properties["$elu_sdk_version"], .string("0.1.0"))
            XCTAssertEqual(firstEvent.properties["$elu_facade_version"], .string("0.1.0"))

            _ = try await queue.acknowledge([
                EluQueueAcknowledgementReference(
                    streamId: firstSnapshot.streamId,
                    sequence: firstRecord.sequence,
                    kind: firstRecord.kind,
                    recordId: firstRecord.recordId
                ),
            ])
            clock.advance(seconds: 1)
            guard case .accepted = await queue.capture(
                command(kind: .capture, name: "after_ack", occurredAt: clock.wall())
            ) else {
                return XCTFail("Queue generation must not invalidate authority")
            }

            clock.advance(seconds: 1)
            let registered = try await queue.registerStandaloneSuperProperties([
                "plan": .string("free"),
                "source": .string("super"),
            ])
            XCTAssertEqual(registered.identity.contextRevision, 1)
            XCTAssertEqual(registered.queuedCount, 1)
            guard case let .rejected(reason, _) = await queue.capture(
                command(kind: .capture, name: "stale", occurredAt: clock.wall())
            ) else {
                return XCTFail("Context mutation must invalidate authority")
            }
            XCTAssertEqual(reason, .authorityWitnessChanged)

            _ = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 1, allowed: true)
            )
            clock.advance(seconds: 1)
            let screen = await queue.capture(
                command(
                    kind: .screen,
                    name: "Billing",
                    occurredAt: clock.wall(),
                    properties: [
                        "plan": .string("pro"),
                        "$elu_sdk_version": .string("attacker"),
                    ]
                )
            )
            guard case let .accepted(screenRecord, _) = screen,
                  case let .event(screenEvent) = screenRecord
            else {
                return XCTFail("Expected screen capture")
            }
            XCTAssertEqual(screenEvent.kind, .screen)
            XCTAssertEqual(screenEvent.properties["plan"], .string("pro"))
            XCTAssertEqual(screenEvent.properties["source"], .string("super"))
            XCTAssertEqual(screenEvent.properties["$elu_sdk_version"], .string("0.1.0"))

            clock.advance(seconds: 1)
            let beforeOptOut = try await queue.snapshot()
            let optedOut = try await queue.setOptedOut(
                true,
                expectedGeneration: beforeOptOut.generation
            )
            XCTAssertTrue(optedOut.identity.optedOut)
            XCTAssertNil(optedOut.identity.session)
            XCTAssertEqual(optedOut.identity.contextRevision, 2)

            clock.advance(seconds: 1)
            let optedIn = try await queue.setOptedOut(
                false,
                expectedGeneration: optedOut.generation
            )
            XCTAssertFalse(optedIn.identity.optedOut)
            XCTAssertNil(optedIn.identity.session)
            XCTAssertEqual(optedIn.identity.contextRevision, 3)
            guard case .rejected(.authorityWitnessChanged, _) = await queue.capture(
                command(
                    kind: .capture,
                    name: "stale_after_opt_gap",
                    occurredAt: clock.wall()
                )
            ) else {
                return XCTFail("Pre-consent authority must remain stale")
            }

            _ = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 3, allowed: true)
            )
            clock.advance(seconds: 1)
            guard case let .accepted(_, postOptSnapshot) = await queue.capture(
                command(
                    kind: .capture,
                    name: "fresh_after_opt_gap",
                    occurredAt: clock.wall()
                )
            ) else {
                return XCTFail("Expected fresh post-opt capture")
            }
            XCTAssertNotNil(postOptSnapshot.identity.session)
            await queue.close()
        }
    }

    func testRestrictionDominatesSameWitnessAndHigherContextCanReauthorize() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 10)
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            let blocked = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: false)
            )
            guard case .terminated = blocked else { return XCTFail("Expected restriction") }

            let malformed = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try malformedDuplicatePrivacy(contextRevision: 0)
            )
            guard case let .terminated(malformedBarrier) = malformed else {
                return XCTFail("Malformed input must not erase restriction")
            }
            XCTAssertEqual(malformedBarrier.reason, .privacyBlocked)

            clock.enqueueWallReadOverrides([
                baseDate,
                Date(timeIntervalSinceReferenceDate: .infinity),
            ])
            let authorizeFailure = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            guard case let .terminated(authorizeFailureBarrier) = authorizeFailure else {
                return XCTFail("Authorize failure must preserve the restriction")
            }
            XCTAssertEqual(authorizeFailureBarrier, malformedBarrier)

            let sameWitnessAllow = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            guard case .terminated = sameWitnessAllow else {
                return XCTFail("Same-witness allow must not loosen restriction")
            }

            clock.advance(seconds: 1)
            _ = try await queue.registerStandaloneSuperProperties(["plan": .string("pro")])
            let higherContext = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 1, allowed: true)
            )
            guard case .activated = higherContext else {
                return XCTFail("Higher context may install a fresh decision")
            }
            await queue.close()
        }
    }

    func testAuthorizeFailureUsesValidatedCandidateAndSameWitnessCanRecover() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 10)
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            clock.enqueueWallReadOverrides([
                baseDate,
                Date(timeIntervalSinceReferenceDate: .infinity),
            ])

            let failed = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            guard case let .terminated(terminal) = failed else {
                return XCTFail("Second wall read must fail authorization")
            }
            XCTAssertEqual(terminal.reason, .malformed)
            XCTAssertEqual(
                terminal.candidateConfigBoundary?.semanticHash,
                "sha256:69da989f31a6a3133dcebcdb64cd7665c666eb6af5a8aa766bc0036d8736ca4f"
            )
            XCTAssertEqual(terminal.trustedConfigBoundary, terminal.candidateConfigBoundary)
            XCTAssertNotNil(terminal.policySourceHash)

            guard case .activated = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            ) else {
                return XCTFail("A valid same-witness response must clear malformed")
            }
            await queue.close()
        }
    }

    func testSiteNamespacePinAndReopenAuthorityAbsence() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 100)
            var queue = try await makeCaptureQueue(root: root, clock: clock)
            _ = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )

            clock.advance(seconds: 1)
            let changedSite = try config { object in
                object["revision"] = "changed-site"
                object["issuedAt"] = "2026-08-04T00:01:30.000Z"
                object["expiresAt"] = "2026-08-04T00:06:30.000Z"
                var site = object["site"] as! [String: Any]
                site["id"] = "site_other"
                object["site"] = site
            }
            let changed = await queue.submitCaptureAuthority(
                configData: changedSite,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            guard case let .terminated(terminal) = changed else {
                return XCTFail("Expected site pin failure")
            }
            XCTAssertEqual(terminal.reason, .siteChanged)
            await queue.close()

            queue = try await makeCaptureQueue(root: root, clock: clock)
            let reopenedAuthority = await queue.captureAuthorityForTesting()
            XCTAssertEqual(reopenedAuthority, .absent)
            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.streamId, "stream_capture_vector")
            let directory = root.appendingPathComponent(
                "site-0d28cb28b0d301938550ddaf297a1c9b59a78c1d02534cf2be40aef423d6b943"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            guard case .activated = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            ) else {
                return XCTFail("A new owner repins through its trusted channel")
            }
            await queue.close()
        }
    }

    func testExactExpiryAndNativeBackgroundOrdering() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            _ = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            clock.advance(seconds: 1)
            guard case let .accepted(_, snapshot) = await queue.capture(
                command(kind: .capture, name: "session", occurredAt: clock.wall())
            ) else {
                return XCTFail("Expected capture")
            }
            guard case .changed = try await queue.markStandaloneBackgrounded(at: clock.wall()) else {
                return XCTFail("Expected background mutation")
            }
            guard case .unchanged = try await queue.markStandaloneBackgrounded(at: clock.wall()) else {
                return XCTFail("Same-time background must be idempotent")
            }
            guard case let .accepted(_, resumed) = await queue.capture(
                command(
                    kind: .capture,
                    name: "same_time_resume",
                    occurredAt: clock.wall()
                )
            ) else {
                return XCTFail("Capture ordered later at the same instant must resume")
            }
            XCTAssertEqual(resumed.identity.session?.lifecycle, .active)
            XCTAssertEqual(resumed.identity.session?.id, snapshot.identity.session?.id)

            clock.set(
                wall: Date(timeIntervalSince1970: 1_785_801_900),
                continuous: 241_000_000_000
            )
            guard case .rejected(.authorityExpired, _) = await queue.capture(
                command(kind: .capture, name: "at_expiry", occurredAt: clock.wall())
            ) else {
                return XCTFail("Exact wall/continuous expiry must reject")
            }
            await queue.close()
        }
    }

    func testExpiredLatchDominatesSameConfigAcrossContextChanges() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            guard case .activated = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            ) else {
                return XCTFail("Expected initial authority")
            }

            clock.set(
                wall: baseDate.addingTimeInterval(1),
                continuous: 241_000_000_000
            )
            guard case .rejected(.authorityExpired, _) = await queue.capture(
                command(kind: .capture, name: "monotonic_expiry", occurredAt: clock.wall())
            ) else {
                return XCTFail("Expected monotonic expiry")
            }

            clock.advance(seconds: 1)
            _ = try await queue.registerStandaloneSuperProperties(["plan": .string("pro")])
            let sameConfig = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 1, allowed: true)
            )
            guard case let .terminated(terminal) = sameConfig else {
                return XCTFail("Expired config must stay terminal")
            }
            XCTAssertEqual(terminal.reason, .expired)

            let newer = try config { object in
                object["revision"] = "config-newer-after-expiry"
                object["issuedAt"] = "2026-08-04T00:02:00.000Z"
                object["expiresAt"] = "2026-08-04T00:10:00.000Z"
            }
            guard case .activated = await queue.submitCaptureAuthority(
                configData: newer,
                effectivePrivacyStateData: try privacy(contextRevision: 1, allowed: true)
            ) else {
                return XCTFail("A newer config boundary may authorize")
            }
            await queue.close()
        }
    }

    func testLowerContextAndOlderConfigCandidatesDoNotPoisonCurrentWitness() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            _ = try await queue.registerStandaloneSuperProperties(["plan": .string("pro")])

            let lowerContext = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            guard case let .terminated(lowerTerminal) = lowerContext else {
                return XCTFail("Expected lower-context rejection")
            }
            XCTAssertEqual(lowerTerminal.reason, .stale)
            XCTAssertEqual(lowerTerminal.contextRevision, 0)
            guard case .activated = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 1, allowed: true)
            ) else {
                return XCTFail("Current context must clear lower-context rejection")
            }

            let malformed = try malformedDuplicatePrivacy(contextRevision: 1)
            guard case let .terminated(malformedTerminal) = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: malformed
            ) else {
                return XCTFail("Expected malformed latch")
            }
            XCTAssertEqual(malformedTerminal.reason, .malformed)
            guard case .activated = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 1, allowed: true)
            ) else {
                return XCTFail("Current valid candidate must clear malformed latch")
            }

            let newer = try config { object in
                object["revision"] = "config-newer-ordering"
                object["issuedAt"] = "2026-08-04T00:01:30.000Z"
                object["expiresAt"] = "2026-08-04T00:06:30.000Z"
            }
            guard case .activated = await queue.submitCaptureAuthority(
                configData: newer,
                effectivePrivacyStateData: try privacy(contextRevision: 1, allowed: true)
            ) else {
                return XCTFail("Expected newer authority")
            }
            let stale = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 1, allowed: true)
            )
            guard case let .terminated(staleTerminal) = stale else {
                return XCTFail("Expected stale candidate")
            }
            XCTAssertEqual(staleTerminal.reason, .stale)
            XCTAssertEqual(
                staleTerminal.candidateConfigBoundary?.semanticHash,
                "sha256:69da989f31a6a3133dcebcdb64cd7665c666eb6af5a8aa766bc0036d8736ca4f"
            )
            XCTAssertNotEqual(
                staleTerminal.candidateConfigBoundary,
                staleTerminal.trustedConfigBoundary
            )
            guard case .activated = await queue.submitCaptureAuthority(
                configData: newer,
                effectivePrivacyStateData: try privacy(contextRevision: 1, allowed: true)
            ) else {
                return XCTFail("Current candidate must clear stale latch")
            }
            await queue.close()
        }
    }

    func testValidationDelayConsumesMonotonicBudgetFromPrevalidationOrigin() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(
                wall: Date(timeIntervalSince1970: 1_785_801_899),
                continuous: 1_000_000_000
            )
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            clock.armContinuousAdvanceOnNextWallRead(nanoseconds: 1_000_000_000)
            guard case let .terminated(terminal) = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            ) else {
                return XCTFail("Validation delay must consume the complete lease")
            }
            XCTAssertEqual(terminal.reason, .expired)
            await queue.close()
        }
    }

    func testPrewriteExpiryRollsBackSessionAndRecordAndLatches() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let fixedBaseDate = baseDate
            let fault = CaptureRuntimeFaultInjector { point in
                if point == .afterStateRead {
                    clock.set(
                        wall: fixedBaseDate.addingTimeInterval(1),
                        continuous: 241_000_000_000
                    )
                }
            }
            let queue = try await makeCaptureQueue(root: root, clock: clock, faultInjector: fault)
            _ = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            clock.advance(seconds: 1)
            guard case let .rejected(.authorityExpired, snapshot) = await queue.capture(
                command(kind: .capture, name: "expires_prewrite", occurredAt: clock.wall())
            ) else {
                return XCTFail("Expected distinct prewrite expiry rejection")
            }
            XCTAssertEqual(snapshot.queuedCount, 0)
            XCTAssertNil(snapshot.identity.session)
            XCTAssertEqual(snapshot.generation, 0)
            let terminalState = await queue.captureAuthorityForTesting()
            guard case let .terminal(terminal) = terminalState else {
                return XCTFail("Expiry must latch")
            }
            XCTAssertEqual(terminal.reason, .expired)
            await queue.close()
        }
    }

    func testRetryRechecksExpiryBeforeSecondCommitAttempt() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let fixedBaseDate = baseDate
            let fault = CaptureRuntimeFaultInjector { point in
                guard point == .afterStateRead else { return }
                clock.set(
                    wall: fixedBaseDate.addingTimeInterval(1),
                    continuous: 241_000_000_000
                )
                throw EluRuntimeQueueError.faultInjected(point)
            }
            let queue = try await makeCaptureQueue(root: root, clock: clock, faultInjector: fault)
            _ = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            clock.advance(seconds: 1)
            guard case let .rejected(.authorityExpired, snapshot) = await queue.capture(
                command(kind: .capture, name: "expires_before_retry", occurredAt: clock.wall())
            ) else {
                return XCTFail("Retry observation must latch expiry")
            }
            XCTAssertEqual(fault.hitCount(for: .afterStateRead), 1)
            XCTAssertEqual(snapshot.queuedCount, 0)
            XCTAssertNil(snapshot.identity.session)
            await queue.close()
        }
    }

    func testCaptureRuntimeRejectsLegacyRecordAndSessionEntryPoints() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            let initial = try await queue.snapshot()
            let versions = command(
                kind: .capture,
                name: "versions",
                occurredAt: clock.wall()
            ).versions
            let draft = EluEventDraft(
                kind: .capture,
                name: "legacy",
                occurredAt: clock.wall(),
                expectedSessionId: "session_legacy",
                properties: [:],
                versions: versions
            )

            do {
                _ = try await queue.appendEvent(draft, sessionUpdate: .preserve)
                XCTFail("Standalone runtime must reject legacy append")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .standaloneLegacyEntryPointUnavailable)
            }
            do {
                _ = try await queue.applyMutation(
                    .identify(userId: "user_legacy", set: [:], setOnce: [:]),
                    versions: versions,
                    expectedGeneration: initial.generation
                )
                XCTFail("Standalone runtime must reject legacy mutation")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .standaloneLegacyEntryPointUnavailable)
            }
            do {
                _ = try await queue.recordEligibleActivity(
                    expectedGeneration: initial.generation
                )
                XCTFail("Standalone runtime must reject legacy session mutation")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .standaloneLegacyEntryPointUnavailable)
            }
            let unchanged = try await queue.snapshot()
            XCTAssertEqual(unchanged, initial)
            await queue.close()

            let unscoped = try await EluSQLiteRuntimeQueue.open(
                directoryURL: root.appendingPathComponent("unscoped"),
                clock: { clock.wall() },
                anonymousIdGenerator: { "anon_unscoped" },
                streamIdGenerator: { "stream_unscoped" },
                sessionIdGenerator: { "session_unscoped" }
            )
            let unscopedInitial = try await unscoped.snapshot()
            let active = try await unscoped.recordEligibleActivity(
                expectedGeneration: unscopedInitial.generation
            )
            XCTAssertNotNil(active.identity.session)
            await unscoped.close()
        }
    }

    func testQueueFullCaptureIsAtomic() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let queue = try await makeCaptureQueue(
                root: root,
                clock: clock,
                limits: try EluRuntimeQueueLimits(maximumCount: 1, maximumBytes: 1_000_000)
            )
            _ = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            clock.advance(seconds: 1)
            guard case .accepted = await queue.capture(
                command(kind: .capture, name: "fills_queue", occurredAt: clock.wall())
            ) else {
                return XCTFail("Expected first record")
            }
            let before = try await queue.snapshot()
            clock.advance(seconds: 1)
            guard case let .rejected(.queueLimit, rejectedSnapshot) = await queue.capture(
                command(kind: .capture, name: "queue_full", occurredAt: clock.wall())
            ) else {
                return XCTFail("Expected atomic queue limit rejection")
            }
            XCTAssertEqual(rejectedSnapshot, before)
            let after = try await queue.snapshot()
            let records = try await queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(after, before)
            XCTAssertEqual(records.count, 1)
            await queue.close()
        }
    }

    func testPreBeginFailureRetriesOnceAfterAuthorityRecheck() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let fault = CaptureRuntimeFailOnceFaultInjector(point: .beforeBegin)
            let queue = try await makeCaptureQueue(root: root, clock: clock, faultInjector: fault)
            _ = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            clock.advance(seconds: 1)

            guard case let .accepted(_, snapshot) = await queue.capture(
                command(kind: .capture, name: "retry_pre_begin", occurredAt: clock.wall())
            ) else {
                return XCTFail("Proven pre-BEGIN failure must receive one retry")
            }
            XCTAssertEqual(fault.hitCount, 2)
            XCTAssertEqual(snapshot.queuedCount, 1)
            XCTAssertEqual(snapshot.generation, 1)
            await queue.close()
        }
    }

    func testRollbackFailureAfterBeginFailsClosedAsProvenNotCommitted() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let fault = CaptureRuntimeFaultInjector { point in
                guard point == .afterStateRead || point == .beforeRollback else { return }
                throw EluRuntimeQueueError.faultInjected(point)
            }
            let queue = try await makeCaptureQueue(root: root, clock: clock, faultInjector: fault)
            _ = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            clock.advance(seconds: 1)

            guard case let .rejected(.storageProvenNotCommitted, snapshot) = await queue.capture(
                command(kind: .capture, name: "rollback_failure", occurredAt: clock.wall())
            ) else {
                return XCTFail("Rollback failure before COMMIT must not be ambiguous")
            }
            XCTAssertEqual(fault.hitCount(for: .afterStateRead), 1)
            XCTAssertEqual(fault.hitCount(for: .beforeRollback), 1)
            XCTAssertEqual(snapshot.queuedCount, 0)
            XCTAssertNil(snapshot.identity.session)
            XCTAssertEqual(snapshot.generation, 0)
            do {
                _ = try await queue.snapshot()
                XCTFail("Rollback failure must poison the owner")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .poisoned)
            }
            guard case let .rejected(.storageProvenNotCommitted, secondSnapshot) =
                await queue.capture(
                    command(
                        kind: .capture,
                        name: "after_rollback_poison",
                        occurredAt: clock.wall()
                    )
                )
            else {
                return XCTFail("Poisoned owner must prove the later call was not attempted")
            }
            XCTAssertEqual(secondSnapshot, snapshot)
            XCTAssertEqual(fault.hitCount(for: .afterStateRead), 1)
            XCTAssertEqual(fault.hitCount(for: .beforeRollback), 1)
            await queue.close()
        }
    }

    func testUnknownCommitOutcomeIsNeverRetried() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let fault = CaptureRuntimeFaultInjector { point in
                guard point == .afterCommit else { return }
                throw EluRuntimeQueueError.faultInjected(point)
            }
            let queue = try await makeCaptureQueue(root: root, clock: clock, faultInjector: fault)
            _ = await queue.submitCaptureAuthority(
                configData: fixture("config-enabled.json"),
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)
            )
            clock.advance(seconds: 1)
            guard case let .rejected(.storageOutcomeUnknown, unknownSnapshot) = await queue.capture(
                command(kind: .capture, name: "unknown", occurredAt: clock.wall())
            ) else {
                return XCTFail("Expected unknown commit outcome")
            }
            XCTAssertEqual(fault.hitCount(for: .afterCommit), 1)
            guard case let .rejected(.storageProvenNotCommitted, poisonedSnapshot) =
                await queue.capture(
                    command(
                        kind: .capture,
                        name: "after_ambiguous_poison",
                        occurredAt: clock.wall()
                    )
                )
            else {
                return XCTFail("Later call on poisoned owner was never attempted")
            }
            XCTAssertEqual(poisonedSnapshot, unknownSnapshot)
            XCTAssertEqual(fault.hitCount(for: .afterCommit), 1)
            await queue.close()
        }
    }

    func testLegacyOptedOutSessionMigrationClearsOnlySession() async throws {
        try await withTemporaryDirectory { root in
            let namespace = try EluV1SiteNamespace.directoryComponent(
                exactConstructorSiteKey: "elu_pk_test_capture"
            )
            let directory = root.appendingPathComponent(namespace, isDirectory: true)
            let session = try EluSessionState(
                id: "session_legacy_opted_out",
                startedAt: baseDate.addingTimeInterval(-30),
                lastActivityAt: baseDate.addingTimeInterval(-10),
                timeoutSeconds: 1_800
            )
            let identity = try EluIdentityState(
                revision: 3,
                contextRevision: 5,
                anonymousId: "anon_legacy_opted_out",
                userId: "user_legacy_opted_out",
                groups: ["org": "org_legacy"],
                superProperties: ["plan": .string("pro")],
                session: session,
                optedOut: true,
                updatedAt: session.lastActivityAt
            )
            let persisted = try EluPersistedState(
                identity: identity,
                streamMetadata: EluStreamMetadata(streamId: "stream_legacy_opted_out"),
                flagContext: EluPersistedFlagContext()
            )
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            try store.save(persisted, mode: .normal)

            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let queue = try await makeCaptureQueue(root: root, clock: clock)
            let migrated = try await queue.snapshot()
            XCTAssertTrue(migrated.identity.optedOut)
            XCTAssertNil(migrated.identity.session)
            XCTAssertEqual(migrated.identity.revision, 3)
            XCTAssertEqual(migrated.identity.contextRevision, 5)
            XCTAssertEqual(migrated.identity.userId, "user_legacy_opted_out")
            XCTAssertEqual(migrated.identity.groups, ["org": "org_legacy"])
            XCTAssertEqual(migrated.identity.superProperties["plan"], .string("pro"))
            XCTAssertEqual(migrated.streamId, "stream_legacy_opted_out")
            XCTAssertEqual(migrated.queuedCount, 0)
            await queue.close()
        }
    }

    func testExistingSQLiteOptedOutSessionMigrationIsAtomic() async throws {
        try await withTemporaryDirectory { root in
            let namespace = try EluV1SiteNamespace.directoryComponent(
                exactConstructorSiteKey: "elu_pk_test_capture"
            )
            let directory = root.appendingPathComponent(namespace, isDirectory: true)
            let clock = TestCaptureClock(wall: baseDate, continuous: 1_000_000_000)
            let legacyQueue = try await EluSQLiteRuntimeQueue.open(
                directoryURL: directory,
                clock: { clock.wall() },
                anonymousIdGenerator: { "anon_existing_migration" },
                streamIdGenerator: { "stream_existing_migration" },
                sessionIdGenerator: { "session_existing_migration" }
            )
            let initial = try await legacyQueue.snapshot()
            let active = try await legacyQueue.recordEligibleActivity(
                expectedGeneration: initial.generation
            )
            await legacyQueue.close()

            var invalidLegacyIdentity = active.identity
            invalidLegacyIdentity.optedOut = true
            try overwriteSQLiteIdentity(
                invalidLegacyIdentity,
                databaseURL: directory.appendingPathComponent("runtime-state-v1.sqlite3")
            )

            let queue = try await makeCaptureQueue(root: root, clock: clock)
            let migrated = try await queue.snapshot()
            XCTAssertTrue(migrated.identity.optedOut)
            XCTAssertNil(migrated.identity.session)
            XCTAssertEqual(migrated.identity.revision, active.identity.revision)
            XCTAssertEqual(migrated.identity.contextRevision, active.identity.contextRevision)
            XCTAssertEqual(migrated.streamId, active.streamId)
            XCTAssertEqual(migrated.nextSequence, active.nextSequence)
            XCTAssertEqual(migrated.queuedCount, active.queuedCount)
            XCTAssertEqual(migrated.generation, active.generation + 1)
            await queue.close()
        }
    }

    func testSourceWitnessWithdrawalIsNonterminalAndSameDocumentCanRecover() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1)
            let gate = sourceGate(clock)
            let data = fixture("config-enabled.json")
            let original = try publishSource(gate, data: data, clock: clock)
            let queue = try await makeCaptureQueue(root: root, clock: clock, configurationGate: gate)
            guard case .terminated = await queue.submitCaptureAuthority(configData: data,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true)) else {
                return XCTFail("Bound owner must require the source witness")
            }
            guard case .activated = await queue.submitCaptureAuthority(configData: data,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true), sourceWitness: original) else {
                return XCTFail("Live source should activate")
            }
            gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil)
            guard case .rejected(.authorityAbsent, _) = await queue.capture(command(kind: .capture, name: "withdrawn", occurredAt: clock.wall())) else {
                return XCTFail("Source withdrawal must stop fresh capture")
            }
            let recovered = try publishSource(gate, data: data, clock: clock)
            guard case .activated = await queue.submitCaptureAuthority(configData: data,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true), sourceWitness: recovered) else {
                return XCTFail("Withdrawal must not poison same-document recovery")
            }
            guard case .terminated = await queue.submitCaptureAuthority(configData: data,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true), sourceWitness: original) else {
                return XCTFail("Queued old token must stay rejected")
            }
            guard case .accepted = await queue.capture(command(kind: .capture, name: "recovered", occurredAt: clock.wall())) else {
                return XCTFail("Stale submission must not replace current authority")
            }
            await queue.close()
        }
    }

    func testSourceExpiryBeforeWriteOrCommitRollsBackFreshCapture() async throws {
        for point in [EluRuntimeQueueFaultPoint.afterStateRead, .beforeCommit] {
            try await withTemporaryDirectory { root in
                let clock = TestCaptureClock(wall: baseDate, continuous: 1)
                let gate = sourceGate(clock)
                let data = fixture("config-enabled.json")
                let witness = try publishSource(gate, data: data, clock: clock)
                let fault = CaptureRuntimeFaultInjector { candidate in
                    if candidate == point { clock.advance(seconds: 10) }
                }
                let queue = try await makeCaptureQueue(root: root, clock: clock, faultInjector: fault, configurationGate: gate)
                _ = await queue.submitCaptureAuthority(configData: data,
                    effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true), sourceWitness: witness)
                guard case .rejected(.authorityAbsent, _) = await queue.capture(command(kind: .capture, name: "racing", occurredAt: clock.wall())) else {
                    return XCTFail("Source expired while SQLite owned the operation")
                }
                let snapshot = try await queue.snapshot()
                XCTAssertEqual(snapshot.queuedCount, 0)
                XCTAssertEqual(snapshot.nextSequence, 0)
                await queue.close()
            }
        }
    }

    func testFinalCaptureAndFlagPublicationConsumesOriginalSourceLease() async throws {
        for flags in [false, true] {
            try await withTemporaryDirectory { root in
                let clock = TestCaptureClock(wall: baseDate, continuous: 1)
                let probe = SourceGateReadProbe(clock: clock)
                let gate = EluV2ConfigAuthorityGate(siteKey: "elu_pk_test_capture", clock: probe.source)
                let data = fixture("config-enabled.json")
                let witness = try publishSource(gate, data: data, clock: clock)
                let queue = try await makeCaptureQueue(root: root, clock: clock, configurationGate: gate)
                if flags { try await queue.ensureFlagSchema() }
                probe.expireOnSecondCheck()
                if flags {
                    let result = await queue.submitFlagConfig(data, sourceWitness: witness)
                    XCTAssertEqual(result, .restricted(.missing))
                } else {
                    guard case .terminated = await queue.submitCaptureAuthority(configData: data,
                        effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true), sourceWitness: witness) else {
                        return XCTFail("Final publication must consume the original lease")
                    }
                    let authority = await queue.captureAuthorityForTesting()
                    XCTAssertEqual(authority, .absent)
                }
                await queue.close()
            }
        }
    }

    func testSourceWithdrawalFencesFlagsWithoutDestroyingDurableAuthority() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1)
            let gate = sourceGate(clock)
            let data = fixture("config-enabled.json")
            let witness = try publishSource(gate, data: data, clock: clock)
            let queue = try await makeCaptureQueue(root: root, clock: clock, configurationGate: gate)
            try await queue.ensureFlagSchema()
            guard case .allowed = await queue.submitFlagConfig(data, sourceWitness: witness) else { return XCTFail("Expected flags authority") }
            let versions = command(kind: .capture, name: "unused", occurredAt: clock.wall()).versions
            guard case let .begun(request) = await queue.beginFlagReload(requestId: "flags_source_1", versions: versions) else { return XCTFail("Expected begun request") }
            let response = try sourceFlagResponse(request)
            let committed = await queue.commitFlagReload(token: request.token, response: response)
            XCTAssertEqual(committed, .updated)
            guard case .hit = await queue.readFlagCache(versions: versions) else { return XCTFail("Expected live source cache") }
            guard case let .begun(pending) = await queue.beginFlagReload(requestId: "flags_source_pending", versions: versions) else { return XCTFail("Expected pending request") }
            let pendingResponse = try sourceFlagResponse(pending)
            gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil)
            let send = await queue.authorizeFlagSend(token: pending.token)
            XCTAssertEqual(send, .stale)
            let cache = await queue.readFlagCache(versions: versions)
            XCTAssertEqual(cache, .restricted(.missing))
            let recovered = try publishSource(gate, data: data, clock: clock)
            guard case .allowed = await queue.submitFlagConfig(data, sourceWitness: recovered) else { return XCTFail("Same-document recovery must stay possible") }
            let recoveredSend = await queue.authorizeFlagSend(token: pending.token)
            XCTAssertEqual(recoveredSend, .stale, "An older physical request cannot borrow a recovered source token")
            let recoveredCommit = await queue.commitFlagReload(token: pending.token, response: pendingResponse)
            XCTAssertEqual(recoveredCommit, .stale)
            let recoveredCache = await queue.readFlagCache(versions: versions)
            XCTAssertEqual(recoveredCache, .restricted(.missing), "A cached result retains its original source token")
            guard case let .begun(fresh) = await queue.beginFlagReload(requestId: "flags_source_2", versions: versions) else { return XCTFail("Expected new request after recovery") }
            let freshSend = await queue.authorizeFlagSend(token: fresh.token)
            XCTAssertEqual(freshSend, .allowed)
            await queue.close()
        }
    }

    func testUnavailableSourcePreservesLocalMutationResetAndConsentWithoutWireDrafts() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1)
            let gate = sourceGate(clock)
            let queue = try await makeCaptureQueue(root: root, clock: clock, configurationGate: gate, anonymousIdGenerator: { "anon_\(UUID().uuidString)" })
            let versions = command(kind: .capture, name: "unused", occurredAt: clock.wall()).versions
            let initial = try await queue.snapshot()
            let identified = try await queue.applyOwnedMutation(.identify(userId: "local-person", set: ["plan": .string("pro")], setOnce: [:]), versions: versions, expectedGeneration: initial.generation)
            XCTAssertEqual(identified.identity.userId, "local-person")
            XCTAssertEqual(identified.queuedCount, 0)
            let grouped = try await queue.applyOwnedMutation(.associateGroup(groupType: "company", groupKey: "local-company"), versions: versions, expectedGeneration: identified.generation)
            XCTAssertEqual(grouped.identity.groups["company"], "local-company")
            XCTAssertEqual(grouped.queuedCount, 0)
            let optedOut = try await queue.setOptedOut(true, expectedGeneration: grouped.generation)
            XCTAssertTrue(optedOut.identity.optedOut)
            let reset = try await queue.reset(expectedGeneration: optedOut.generation)
            XCTAssertNil(reset.identity.userId)
            XCTAssertEqual(reset.queuedCount, 0)
            await queue.close()
        }
    }

    func testSourceWithdrawalDuringMutationPreservesLocalStateWithoutStaleWire() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1)
            let gate = sourceGate(clock)
            let data = fixture("config-enabled.json")
            let witness = try publishSource(gate, data: data, clock: clock)
            let fault = CaptureRuntimeFaultInjector { point in
                if point == .beforeCommit { gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil) }
            }
            let queue = try await makeCaptureQueue(root: root, clock: clock, faultInjector: fault, configurationGate: gate)
            _ = await queue.submitCaptureAuthority(configData: data,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true), sourceWitness: witness)
            let initial = try await queue.snapshot()
            let local = try await queue.applyOwnedMutation(.identify(userId: "racing-person", set: [:], setOnce: [:]),
                versions: command(kind: .capture, name: "unused", occurredAt: clock.wall()).versions, expectedGeneration: initial.generation)
            XCTAssertEqual(local.identity.userId, "racing-person")
            XCTAssertEqual(local.queuedCount, 0)
            XCTAssertEqual(local.nextSequence, 0)
            await queue.close()
        }
    }

    func testLawfulQueuedEventsRemainReadableAndAcknowledgableAfterSourceWithdrawal() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1)
            let gate = sourceGate(clock)
            let data = fixture("config-enabled.json")
            let witness = try publishSource(gate, data: data, clock: clock)
            let queue = try await makeCaptureQueue(root: root, clock: clock, configurationGate: gate)
            _ = await queue.submitCaptureAuthority(configData: data,
                effectivePrivacyStateData: try privacy(contextRevision: 0, allowed: true), sourceWitness: witness)
            guard case let .accepted(record, snapshot) = await queue.capture(command(kind: .capture, name: "lawful", occurredAt: clock.wall())) else { return XCTFail("Expected captured row") }
            gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil)
            let rows = try await queue.peek(maximumCount: 10, maximumBytes: 1_048_576)
            XCTAssertEqual(rows.count, 1)
            _ = try await queue.acknowledge([EluQueueAcknowledgementReference(streamId: snapshot.streamId,
                sequence: record.sequence, kind: record.kind, recordId: record.recordId)])
            let drained = try await queue.snapshot()
            XCTAssertEqual(drained.queuedCount, 0)
            await queue.close()
        }
    }

    func testPortableFlagProjectionRetainsOriginalCacheDeadlineAcrossReads() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1)
            let h = try await projectionFixture(root: root, clock: clock)
            XCTAssertTrue(h.projection.authority.isCurrent())
            clock.set(wall: baseDate, continuous: 100_000_000_001)
            let reread = await h.queue.readFlagProjection(versions: h.versions)
            XCTAssertNotNil(reread)
            clock.set(wall: baseDate, continuous: 179_000_000_001)
            XCTAssertFalse(h.projection.authority.isCurrent())
            XCTAssertFalse(reread?.authority.isCurrent() ?? true)
            XCTAssertEqual(h.projection.lookup("enabled"), .missing)
            await h.queue.close()
        }
    }

    func testFlagRequestGuardRotatesAtBeginWhileCacheSurvivesAndContextInvalidatesBoth() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1)
            let h = try await projectionFixture(root: root, clock: clock)
            // No capture authority has been installed; flags are independently live.
            let capture = await h.queue.captureAuthorityForTesting()
            XCTAssertEqual(capture, .absent)
            guard case let .begun(first) = await h.queue.beginFlagReload(requestId: "guard_first", versions: h.versions) else { return XCTFail("Expected flag begin") }
            let firstGuard = await h.queue.flagSendGuard(token: first.token)
            XCTAssertTrue(firstGuard?.isCurrent() ?? false)
            guard case let .begun(second) = await h.queue.beginFlagReload(requestId: "guard_second", versions: h.versions) else { return XCTFail("Expected second begin") }
            let secondGuard = await h.queue.flagSendGuard(token: second.token)
            XCTAssertFalse(firstGuard?.isCurrent() ?? true)
            XCTAssertTrue(secondGuard?.isCurrent() ?? false)
            XCTAssertTrue(h.projection.authority.isCurrent(), "Reload must retain the lawful prior cache")
            let state = try await h.queue.snapshot()
            _ = try await h.queue.setFlagPersonProperties(["plan": .string("updated")], versions: h.versions, expectedGeneration: state.generation)
            XCTAssertFalse(h.projection.authority.isCurrent())
            XCTAssertFalse(secondGuard?.isCurrent() ?? true)
            await h.queue.close()
        }
    }

    func testPortableFlagProjectionFailsOnWithdrawalQueuedMutationCloseAndClockRollback() async throws {
        for operation in 0 ..< 4 {
            try await withTemporaryDirectory { root in
                let clock = TestCaptureClock(wall: baseDate, continuous: 1)
                let h = try await projectionFixture(root: root, clock: clock)
                switch operation {
                case 0: h.gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil)
                case 1: h.queue.invalidateFlagProjection()
                case 2: await h.queue.close()
                default:
                    clock.set(wall: baseDate, continuous: 100_000_000_001)
                    XCTAssertTrue(h.projection.authority.isCurrent())
                    clock.set(wall: baseDate, continuous: 50_000_000_001)
                }
                XCTAssertFalse(h.projection.authority.isCurrent())
                if operation == 3 {
                    clock.set(wall: baseDate, continuous: 101_000_000_001)
                    let reread = await h.queue.readFlagProjection(versions: h.versions)
                    XCTAssertNil(reread, "Observed clock rollback must not rearm a new guard")
                }
                await h.queue.close()
            }
        }
    }

    func testCacheReplacementAndConfigApplicationInvalidateRetainedProjection() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1)
            let h = try await projectionFixture(root: root, clock: clock)
            guard case let .begun(next) = await h.queue.beginFlagReload(requestId: "projection_replacement", versions: h.versions) else { return XCTFail("Expected begin") }
            let committed = await h.queue.commitFlagReload(token: next.token, response: try sourceFlagResponse(next))
            XCTAssertEqual(committed, .updated)
            XCTAssertFalse(h.projection.authority.isCurrent())
            let fresh = await h.queue.readFlagProjection(versions: h.versions)
            XCTAssertTrue(fresh?.authority.isCurrent() ?? false)
            _ = await h.queue.submitFlagConfig(h.data, sourceWitness: h.source)
            XCTAssertFalse(fresh?.authority.isCurrent() ?? true)
            await h.queue.close()
        }
    }

    func testPendingProjectionIntentRejectsOldAndNewGuardsUntilEveryIntentSettles() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1)
            let h = try await projectionFixture(root: root, clock: clock)
            let first = h.queue.beginFlagProjectionIntent()
            let second = h.queue.beginFlagProjectionIntent()
            XCTAssertFalse(h.projection.authority.isCurrent())
            let pending = await h.queue.readFlagProjection(versions: h.versions)
            XCTAssertNil(pending, "A reread before the queued mutation must not mint old-state authority")
            h.queue.finishFlagProjectionIntent(first)
            let stillPending = await h.queue.readFlagProjection(versions: h.versions)
            XCTAssertNil(stillPending)
            h.queue.finishFlagProjectionIntent(second)
            let settled = await h.queue.readFlagProjection(versions: h.versions)
            XCTAssertNotNil(settled)
            XCTAssertFalse(h.projection.authority.isCurrent(), "Settling cannot revive a prior projection")
            await h.queue.close()
        }
    }

    func testConcurrentProjectionChecksSerializeClockSamplingWithRollbackFloor() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestCaptureClock(wall: baseDate, continuous: 1)
            let probe = ProjectionClockProbe(clock: clock)
            let h = try await projectionFixture(root: root, clock: clock, clockOverride: { probe.wall() })
            probe.arm()
            let completed = expectation(description: "concurrent checks")
            completed.expectedFulfillmentCount = 2
            let values = ProjectionCheckValues()
            DispatchQueue.global().async { values.add(h.projection.authority.isCurrent()); completed.fulfill() }
            XCTAssertEqual(probe.first.wait(timeout: .now() + 2), .success)
            DispatchQueue.global().async { values.add(h.projection.authority.isCurrent()); completed.fulfill() }
            XCTAssertEqual(probe.second.wait(timeout: .now() + 0.05), .timedOut,
                "The second check cannot sample time before the first releases the ordering lock")
            probe.release.signal()
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertEqual(values.read(), [true, true])
            await h.queue.close()
        }
    }

    func testBoundFlagClientUsesOriginalRequestGuardAndRemainsIndependentOfCapture() async throws {
        for change in 0 ..< 3 {
            try await withTemporaryDirectory { root in
                let clock = TestCaptureClock(wall: baseDate, continuous: 1)
                let h = try await projectionFixture(root: root, clock: clock)
                let transport = ProjectionBoundFlagTransport(beforeStart: {
                    if change == 1 {
                        let state = try? await h.queue.snapshot()
                        if let state { _ = try? await h.queue.setFlagPersonProperties(["plan": .string("changed")], versions: h.versions, expectedGeneration: state.generation) }
                    } else if change == 2 {
                        h.gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil)
                    }
                })
                let client = try await EluV1FlagClient.make(runtime: h.queue, transport: transport, versions: h.versions)
                let projection = await client.reloadProjection()
                if change == 0 {
                    XCTAssertNotNil(projection)
                    XCTAssertEqual(projection?.lookup("enabled"), .found(value: .bool(false), payload: nil))
                } else { XCTAssertNil(projection) }
                let calls = await transport.calls
                XCTAssertEqual(calls, 1)
                await client.close()
                XCTAssertFalse(projection?.authority.isCurrent() ?? false)
                await h.queue.close()
            }
        }
    }

    private func projectionFixture(root: URL, clock: TestCaptureClock, clockOverride: (@Sendable () -> Date)? = nil) async throws -> (
        queue: EluSQLiteRuntimeQueue, gate: EluV2ConfigAuthorityGate, data: Data,
        source: EluV2ConfigAuthorityWitness, versions: EluVersionContext, projection: EluV1FlagCacheProjection
    ) {
        let gate = sourceGate(clock)
        let data = fixture("config-enabled.json")
        let source = try publishSource(gate, data: data, clock: clock, leaseSeconds: 1000)
        let queue = try await makeCaptureQueue(root: root, clock: clock, configurationGate: gate, clockOverride: clockOverride)
        try await queue.ensureFlagSchema()
        let versions = command(kind: .capture, name: "unused", occurredAt: clock.wall()).versions
        guard case .allowed = await queue.submitFlagConfig(data, sourceWitness: source),
              case let .begun(request) = await queue.beginFlagReload(requestId: "projection_initial", versions: versions) else { throw EluRuntimeQueueError.invalidState }
        let committed = await queue.commitFlagReload(token: request.token, response: try sourceFlagResponse(request))
        XCTAssertEqual(committed, .updated)
        let value = await queue.readFlagProjection(versions: versions)
        let projection = try XCTUnwrap(value)
        return (queue, gate, data, source, versions, projection)
    }

    private func sourceFlagResponse(_ begun: EluV1FlagBegunRequest) throws -> EluV1FlagResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "requestId": begun.token.requestId,
            "contextRevision": begun.token.witness.contextRevision,
            "identityRevision": begun.token.witness.identityRevision,
            "flagsRevision": "flags-source-1", "evaluatedAt": "2026-08-04T00:01:01.000Z",
            "expiresAt": "2026-08-04T00:04:00.000Z", "flags": ["enabled": true], "payloads": [:],
        ] as [String: Any], options: [.sortedKeys])
        return try EluV1FlagCodec.decodeResponse(body, for: begun.request)
    }

    private func sourceGate(_ clock: TestCaptureClock) -> EluV2ConfigAuthorityGate {
        EluV2ConfigAuthorityGate(siteKey: "elu_pk_test_capture", clock: EluV2ConfigClock(
            wallNow: { clock.wall() }, continuousNow: { clock.continuous() }, floorTicks: { $0 }, floorNanoseconds: { $0 }))
    }

    private func publishSource(_ gate: EluV2ConfigAuthorityGate, data: Data, clock: TestCaptureClock, leaseSeconds: UInt64 = 10) throws -> EluV2ConfigAuthorityWitness {
        let token = EluV2ConfigLifecycleToken()
        gate.publish(token: token, lease: EluV2ConfigLease(data: data,
            expiresAt: try EluV1Timestamp("2026-08-04T00:05:00.000Z"), continuousDeadline: clock.continuous() + leaseSeconds * 1_000_000_000))
        return try XCTUnwrap(gate.witness(for: token))
    }

    private func makeCaptureQueue(
        root: URL,
        clock: TestCaptureClock,
        limits: EluRuntimeQueueLimits? = nil,
        faultInjector: (any EluRuntimeQueueFaultInjecting)? = nil,
        configurationGate: EluV2ConfigAuthorityGate? = nil,
        anonymousIdGenerator: @escaping @Sendable () -> String = { "anon_capture_vector" },
        clockOverride: (@Sendable () -> Date)? = nil
    ) async throws -> EluSQLiteRuntimeQueue {
        let resolvedLimits = try limits ?? EluRuntimeQueueLimits()
        return try await EluSQLiteRuntimeQueue.openCaptureRuntime(
            rootDirectoryURL: root,
            exactConstructorSiteKey: "elu_pk_test_capture",
            limits: resolvedLimits,
            clock: clockOverride ?? { clock.wall() },
            continuousClock: { clock.continuous() },
            continuousBudgetConverter: { $0 },
            anonymousIdGenerator: anonymousIdGenerator,
            streamIdGenerator: { "stream_capture_vector" },
            sessionIdGenerator: { "session_\(UUID().uuidString.lowercased())" },
            configurationGate: configurationGate,
            faultInjector: faultInjector
        )
    }

    private func command(
        kind: EluEventKind,
        name: String,
        occurredAt: Date,
        properties: [String: EluJSONValue] = [:]
    ) -> EluV1CaptureCommand {
        EluV1CaptureCommand(
            kind: kind,
            name: name,
            occurredAt: occurredAt,
            properties: properties,
            versions: try! EluVersionContext(
                runtime: EluVersionComponent(name: "elu-ios", version: "0.1.0"),
                facade: EluVersionComponent(name: "EluAnalytics", version: "0.1.0")
            )
        )
    }

    private func fixture(_ name: String) -> Data {
        try! Data(contentsOf: fixtureURL(name))
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance/V1/Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func privacy(contextRevision: Int64, allowed: Bool) throws -> Data {
        let name = allowed ? "privacy-allowed.json" : "privacy-blocked.json"
        var object = try jsonObject(fixture(name))
        object["policyRevision"] = "privacy-1"
        object["contextRevision"] = contextRevision
        object["effectivePolicyHash"] = "sha256:" + String(repeating: "0", count: 64)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        object["effectivePolicyHash"] = try EluV1ConfigManager.computedEffectivePolicyHash(for: data)
        data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data
    }

    private func config(_ mutation: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try jsonObject(fixture("config-enabled.json"))
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func malformedDuplicatePrivacy(contextRevision: Int64) throws -> Data {
        let valid = try privacy(contextRevision: contextRevision, allowed: true)
        var raw = String(decoding: valid, as: UTF8.self)
        raw.removeLast()
        raw += ",\"\\u0063ontextRevision\":\(contextRevision)}"
        return Data(raw.utf8)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func overwriteSQLiteIdentity(
        _ identity: EluIdentityState,
        databaseURL: URL
    ) throws {
        let data = try EluStateCoding.encoder().encode(identity)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
            let database
        else {
            throw EluRuntimeQueueError.databaseUnavailable
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(
            database,
            "UPDATE runtime_state SET identity_json = X'\(hex)' WHERE singleton = 1",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw EluRuntimeQueueError.databaseUnavailable
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "elu-capture-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private final class TestCaptureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wallValue: Date
    private var continuousValue: UInt64
    private var pendingWallReadContinuousAdvance: UInt64 = 0
    private var wallReadOverrides: [Date] = []

    init(wall: Date, continuous: UInt64) {
        wallValue = wall
        continuousValue = continuous
    }

    func wall() -> Date {
        lock.lock()
        let value = wallReadOverrides.isEmpty
            ? wallValue
            : wallReadOverrides.removeFirst()
        continuousValue &+= pendingWallReadContinuousAdvance
        pendingWallReadContinuousAdvance = 0
        lock.unlock()
        return value
    }

    func continuous() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return continuousValue
    }

    func advance(seconds: TimeInterval) {
        lock.lock()
        wallValue = wallValue.addingTimeInterval(seconds)
        continuousValue &+= UInt64(seconds * 1_000_000_000)
        lock.unlock()
    }

    func set(wall: Date, continuous: UInt64) {
        lock.lock()
        wallValue = wall
        continuousValue = continuous
        lock.unlock()
    }

    func armContinuousAdvanceOnNextWallRead(nanoseconds: UInt64) {
        lock.lock()
        pendingWallReadContinuousAdvance = nanoseconds
        lock.unlock()
    }

    func enqueueWallReadOverrides(_ values: [Date]) {
        lock.lock()
        wallReadOverrides.append(contentsOf: values)
        lock.unlock()
    }
}

private final class CaptureRuntimeFailOnceFaultInjector:
    EluRuntimeQueueFaultInjecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let point: EluRuntimeQueueFaultPoint
    private var fired = false
    private var count = 0

    var hitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    init(point: EluRuntimeQueueFaultPoint) {
        self.point = point
    }

    func hit(_ candidate: EluRuntimeQueueFaultPoint) throws {
        guard candidate == point else { return }
        lock.lock()
        count += 1
        let shouldThrow = !fired
        fired = true
        lock.unlock()
        if shouldThrow {
            throw EluRuntimeQueueError.faultInjected(candidate)
        }
    }
}

private final class CaptureRuntimeFaultInjector: EluRuntimeQueueFaultInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private let action: @Sendable (EluRuntimeQueueFaultPoint) throws -> Void
    private var counts: [String: Int] = [:]

    init(
        action: @escaping @Sendable (EluRuntimeQueueFaultPoint) throws -> Void
    ) {
        self.action = action
    }

    func hit(_ point: EluRuntimeQueueFaultPoint) throws {
        lock.lock()
        counts[String(describing: point), default: 0] += 1
        lock.unlock()
        try action(point)
    }

    func hitCount(for point: EluRuntimeQueueFaultPoint) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[String(describing: point), default: 0]
    }
}

private final class SourceGateReadProbe: @unchecked Sendable {
    private let clock: TestCaptureClock
    private let lock = NSLock()
    private var remaining: Int?
    init(clock: TestCaptureClock) { self.clock = clock }
    func expireOnSecondCheck() { lock.lock(); remaining = 2; lock.unlock() }
    var source: EluV2ConfigClock {
        EluV2ConfigClock(wallNow: {
            self.lock.lock()
            if let remaining = self.remaining { self.remaining = remaining - 1 }
            let expires = self.remaining == 0
            if expires { self.remaining = nil }
            self.lock.unlock()
            if expires { self.clock.advance(seconds: 10) }
            return self.clock.wall()
        }, continuousNow: { self.clock.continuous() }, floorTicks: { $0 }, floorNanoseconds: { $0 })
    }
}

private final class ProjectionClockProbe: @unchecked Sendable {
    let first = DispatchSemaphore(value: 0)
    let second = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let clock: TestCaptureClock
    private var count: Int?
    init(clock: TestCaptureClock) { self.clock = clock }
    func arm() { lock.lock(); count = 0; lock.unlock() }
    func wall() -> Date {
        lock.lock()
        if let value = count { count = value + 1 }
        let sample = count
        lock.unlock()
        let captured = clock.wall().addingTimeInterval(Double(sample ?? 0) / 1000)
        if sample == 1 { first.signal(); _ = release.wait(timeout: .now() + 3) }
        if sample == 2 { second.signal() }
        return captured
    }
}

private final class ProjectionCheckValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func add(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    func read() -> [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}

private actor ProjectionBoundFlagTransport: EluV1AuthorizedFlagTransport {
    private let beforeStart: @Sendable () async -> Void
    private(set) var calls = 0
    init(beforeStart: @escaping @Sendable () async -> Void) { self.beforeStart = beforeStart }
    func send(endpoint: URL, requestBody: Data) async throws -> Data {
        XCTFail("Bound client used the unguarded transport method")
        throw EluV1BoundTransportError.staleAuthority
    }
    func send(endpoint: URL, requestBody: Data, authority: EluV1TransportAuthority) async throws -> Data {
        calls += 1
        guard await authority.revalidate() else { throw EluV1BoundTransportError.staleAuthority }
        await beforeStart()
        guard authority.isCurrent() else { throw EluV1BoundTransportError.staleAuthority }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let identity = try XCTUnwrap(object["identity"] as? [String: Any])
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "requestId": object["requestId"]!, "contextRevision": object["contextRevision"]!,
            "identityRevision": identity["revision"]!, "flagsRevision": "bound-flags",
            "evaluatedAt": "2026-08-04T00:01:01.000Z", "expiresAt": "2026-08-04T00:04:00.000Z",
            "flags": ["enabled": false], "payloads": [:],
        ] as [String: Any], options: [.sortedKeys])
    }
}
