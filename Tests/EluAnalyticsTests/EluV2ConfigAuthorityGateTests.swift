import Foundation
import XCTest
@testable import EluAnalytics

final class EluV2ConfigAuthorityGateTests: XCTestCase {
    func testWitnessBindsOriginatingGateTokenAndExactDocument() throws {
        let clock = GateClock()
        let first = EluV2ConfigAuthorityGate(siteKey: "site-a", clock: clock.source)
        let second = EluV2ConfigAuthorityGate(siteKey: "site-a", clock: clock.source)
        let token = EluV2ConfigLifecycleToken()
        let lease = try clock.lease()
        first.publish(token: token, lease: lease)
        second.publish(token: token, lease: lease)
        let witness = try XCTUnwrap(first.witness(for: token))
        XCTAssertTrue(first.isCurrent(witness, data: lease.data))
        XCTAssertFalse(first.isCurrent(witness, data: Data("foreign".utf8)))
        XCTAssertFalse(second.isCurrent(witness))
        XCTAssertNil(first.witness(for: EluV2ConfigLifecycleToken()))
    }

    func testWithdrawalIsNonterminalAndRecoveryCannotRenewOriginalLease() throws {
        let clock = GateClock()
        let gate = EluV2ConfigAuthorityGate(siteKey: "site", clock: clock.source)
        let original = EluV2ConfigLifecycleToken()
        gate.publish(token: original, lease: try clock.lease(deadline: 10))
        let old = try XCTUnwrap(gate.witness(for: original))
        gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil)
        XCTAssertFalse(gate.isCurrent(old))
        let recovered = EluV2ConfigLifecycleToken()
        gate.publish(token: recovered, lease: try clock.lease(deadline: 100))
        let current = try XCTUnwrap(gate.witness(for: recovered))
        XCTAssertEqual(current.continuousDeadline, 10)
        XCTAssertFalse(gate.isCurrent(old))
        clock.set(continuous: 10)
        XCTAssertFalse(gate.isCurrent(current))
        let late = EluV2ConfigLifecycleToken()
        gate.publish(token: late, lease: try clock.lease(deadline: 200))
        XCTAssertNil(gate.witness(for: late))
    }

    func testWallEqualityAndContinuousEqualityEachDenyWithoutWaitingForTimer() throws {
        for wallExpiry in [true, false] {
            let clock = GateClock()
            let gate = EluV2ConfigAuthorityGate(siteKey: "site", clock: clock.source)
            let token = EluV2ConfigLifecycleToken()
            gate.publish(token: token, lease: try clock.lease(deadline: 20))
            let witness = try XCTUnwrap(gate.witness(for: token))
            if wallExpiry { clock.set(wall: Date(timeIntervalSince1970: 1_785_888_300)) }
            else { clock.set(continuous: 20) }
            XCTAssertFalse(gate.consume(witness) { XCTFail("Expired authority consumed") })
        }
    }

    func testClockRollbackAndCloseCannotBeRearmed() throws {
        for close in [true, false] {
            let clock = GateClock()
            let gate = EluV2ConfigAuthorityGate(siteKey: "site", clock: clock.source)
            let token = EluV2ConfigLifecycleToken()
            gate.publish(token: token, lease: try clock.lease())
            let witness = try XCTUnwrap(gate.witness(for: token))
            if close { gate.close() } else { clock.set(continuous: 0) }
            XCTAssertFalse(gate.isCurrent(witness))
            clock.set(continuous: 2)
            let next = EluV2ConfigLifecycleToken()
            gate.publish(token: next, lease: try clock.lease())
            XCTAssertNil(gate.witness(for: next))
        }
    }
}

private final class GateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wall = Date(timeIntervalSince1970: 1_785_888_090)
    private var continuous: UInt64 = 1
    var source: EluV2ConfigClock {
        EluV2ConfigClock(wallNow: { self.readWall() }, continuousNow: { self.readContinuous() },
            floorTicks: { $0 }, floorNanoseconds: { $0 })
    }
    func lease(deadline: UInt64 = 100) throws -> EluV2ConfigLease {
        EluV2ConfigLease(data: Data("synthetic validated document".utf8),
            expiresAt: try EluV1Timestamp("2026-08-05T00:05:00.000Z"), continuousDeadline: deadline)
    }
    func set(wall: Date? = nil, continuous: UInt64? = nil) {
        lock.lock()
        if let wall { self.wall = wall }
        if let continuous { self.continuous = continuous }
        lock.unlock()
    }
    private func readWall() -> Date { lock.lock(); defer { lock.unlock() }; return wall }
    private func readContinuous() -> UInt64 { lock.lock(); defer { lock.unlock() }; return continuous }
}
