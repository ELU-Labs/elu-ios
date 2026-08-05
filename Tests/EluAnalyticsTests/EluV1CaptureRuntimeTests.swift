import Foundation
import SQLite3
import XCTest
@testable import EluAnalytics

final class EluV1CaptureRuntimeTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_785_801_660)

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

    private func makeCaptureQueue(
        root: URL,
        clock: TestCaptureClock,
        limits: EluRuntimeQueueLimits? = nil,
        faultInjector: (any EluRuntimeQueueFaultInjecting)? = nil
    ) async throws -> EluSQLiteRuntimeQueue {
        let resolvedLimits = try limits ?? EluRuntimeQueueLimits()
        try await EluSQLiteRuntimeQueue.openCaptureRuntime(
            rootDirectoryURL: root,
            exactConstructorSiteKey: "elu_pk_test_capture",
            limits: resolvedLimits,
            clock: { clock.wall() },
            continuousClock: { clock.continuous() },
            continuousBudgetConverter: { $0 },
            anonymousIdGenerator: { "anon_capture_vector" },
            streamIdGenerator: { "stream_capture_vector" },
            sessionIdGenerator: { "session_\(UUID().uuidString.lowercased())" },
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
