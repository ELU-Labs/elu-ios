import Foundation
import XCTest
@testable import EluAnalytics

final class EluV2ConfigLifecycleTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    func testStartPublishesOnlyResolvableTokenAndArmsIndependentTimers() async throws {
        let h = try Harness()
        await h.driver.start()
        try await h.waitForRequests(1)
        assertEqual(await h.state(), .unavailable(.loading))
        let data = try fixture()
        await h.transport.resolve(0, data: data)
        try await h.waitForState(.document(data))
        XCTAssertEqual(h.scheduler.delays.sorted(), [168 * second, 210 * second])
        await h.stop()
    }

    func testExpiryWithdrawsWhileRenewalIsPendingAndAllowsOnlyFreshLease() async throws {
        let h = try Harness()
        let data = try fixture()
        try await h.install(data)
        h.clock.advance(seconds: 168)
        assertTrue(await h.scheduler.fire(delay: 168 * second))
        try await h.waitForRequests(2)
        let oldToken = try XCTUnwrap(h.notifications.last)
        h.clock.advance(seconds: 42)
        assertTrue(await h.scheduler.fire(delay: 210 * second))
        try await h.waitForState(.unavailable(.expired))
        let consumed = await h.driver.consumeCurrent(oldToken) { _ in XCTFail("Expired notification consumed") }
        XCTAssertFalse(consumed)
        assertEqual(await h.transport.count, 2)
        let next = try fixture {
            $0["issuedAt"] = "2026-08-05T00:04:00.000Z"
            $0["expiresAt"] = "2026-08-05T00:09:00.000Z"
        }
        await h.transport.resolve(1, data: next)
        try await h.waitForState(.document(next))
        assertEqual(await h.transport.count, 2)
        await h.stop()
    }

    func testDelayedExpiryTimerCannotMakeOldTokenConsumable() async throws {
        let h = try Harness()
        let data = try fixture()
        try await h.install(data)
        let token = try XCTUnwrap(h.notifications.last)
        h.clock.advance(seconds: 210)
        let consumed = await h.driver.consumeCurrent(token) { _ in XCTFail("Expired bytes consumed") }
        XCTAssertFalse(consumed)
        assertEqual(await h.state(), .unavailable(.expired))
        await h.stop()
    }

    func testRetryBackoffCapsAtSixtySecondsAndSuccessResetsIt() async throws {
        let h = try Harness()
        await h.driver.start()
        for (index, delay) in [1, 2, 4, 8, 16, 32, 60, 60].enumerated() {
            try await h.waitForRequests(index + 1)
            await h.transport.fail(index)
            try await h.waitForTimer(UInt64(delay) * second)
            assertEqual(await h.state(), .unavailable(.refreshFailed))
            h.clock.advance(seconds: Double(delay))
            assertTrue(await h.scheduler.fire(delay: UInt64(delay) * second))
        }
        try await h.waitForRequests(9)
        // A fresh issuance after the elapsed retry period.
        let data = try fixture {
            $0["issuedAt"] = "2026-08-05T00:04:00.000Z"
            $0["expiresAt"] = "2026-08-05T00:09:00.000Z"
        }
        await h.transport.resolve(8, data: data)
        try await h.waitForState(.document(data))
        await h.driver.refresh()
        try await h.waitForRequests(10)
        await h.transport.fail(9)
        try await h.waitForTimer(second)
        await h.stop()
    }

    func testBackgroundWithdrawsCancelsTimersAndRejectsQueuedDocumentToken() async throws {
        let h = try Harness()
        try await h.install(fixture())
        let old = try XCTUnwrap(h.notifications.last)
        await h.driver.setForeground(false)
        assertEqual(await h.state(), .unavailable(.background))
        XCTAssertEqual(h.scheduler.delays, [])
        assertFalse(await h.driver.consumeCurrent(old) { _ in XCTFail("Background accepted old data") })
        assertTrue(await h.scheduler.fire(delay: 168 * second, includingCancelled: true))
        assertEqual(await h.transport.count, 1)
        await h.stop()
    }

    func testForegroundWaitsForCanceledFetchCleanupAndRefreshesWithoutCachedReplay() async throws {
        let h = try Harness()
        await h.driver.start()
        try await h.waitForRequests(1)
        await h.driver.setForeground(false)
        await h.driver.setForeground(true)
        assertEqual(await h.state(), .unavailable(.loading))
        assertEqual(await h.transport.count, 1)
        await h.transport.resolve(0, data: try fixture())
        try await h.waitForRequests(2)
        assertEqual(await h.state(), .unavailable(.loading))
        let revoked = try inactiveFixture()
        await h.transport.resolve(1, data: revoked)
        try await h.waitForState(.document(revoked))
        await h.stop()
    }

    func testImmediateBackgroundBeforeWorkerStartsNeverPublishesLateBytes() async throws {
        let h = try Harness()
        await h.driver.start()
        await h.driver.setForeground(false)
        await h.transport.finishAll()
        assertEqual(await h.state(), .unavailable(.background))
        await h.driver.setForeground(true)
        try await h.waitForRequests(1)
        await h.transport.finishAll()
        await h.stop()
    }

    func testCloseIsTerminalAndCanceledTimerCannotRestartWork() async throws {
        let h = try Harness()
        try await h.install(fixture())
        let old = try XCTUnwrap(h.notifications.last)
        await h.driver.close()
        assertEqual(await h.state(), .unavailable(.closed))
        assertFalse(await h.driver.consumeCurrent(old) { _ in XCTFail("Closed token accepted") })
        await h.driver.start()
        await h.driver.setForeground(true)
        await h.driver.refresh()
        assertTrue(await h.scheduler.fire(delay: 168 * second, includingCancelled: true))
        assertEqual(await h.transport.count, 1)
        await h.stop()
    }

    func testCloseFencesPendingFetchThatIgnoresCancellation() async throws {
        let h = try Harness()
        await h.driver.start()
        try await h.waitForRequests(1)
        await h.driver.close()
        await h.transport.resolve(0, data: try fixture())
        assertEqual(await h.state(), .unavailable(.closed))
        await h.stop()
    }

    func testSameDocumentRenewalCannotDelayOriginalExpiryWhenWallStalls() async throws {
        let h = try Harness()
        let data = try fixture()
        try await h.install(data)
        h.clock.advance(seconds: 168, wall: false)
        assertTrue(await h.scheduler.fire(delay: 168 * second))
        try await h.waitForRequests(2)
        await h.transport.resolve(1, data: data)
        try await h.waitForTimer(42 * second)
        h.clock.advance(seconds: 42, wall: false)
        assertTrue(await h.scheduler.fire(delay: 42 * second))
        assertEqual(await h.state(), .unavailable(.expired))
        await h.stop()
    }

    func testNewerDocumentCancelsOldExpiryTimerAndInvalidatesOldToken() async throws {
        let h = try Harness()
        try await h.install(fixture())
        let oldToken = try XCTUnwrap(h.notifications.last)
        await h.driver.refresh()
        try await h.waitForRequests(2)
        let next = try fixture {
            $0["issuedAt"] = "2026-08-05T00:01:00.000Z"
            $0["expiresAt"] = "2026-08-05T00:06:00.000Z"
        }
        await h.transport.resolve(1, data: next)
        try await h.waitForState(.document(next))
        h.clock.advance(seconds: 210)
        assertTrue(await h.scheduler.fire(delay: 210 * second, includingCancelled: true))
        assertEqual(await h.state(), .document(next))
        assertFalse(await h.driver.consumeCurrent(oldToken) { _ in XCTFail("Replaced token accepted") })
        await h.stop()
    }

    func testClockRollbackWithdrawsAndPermanentlyStopsRefreshes() async throws {
        let h = try Harness()
        try await h.install(fixture())
        h.clock.advance(seconds: -1)
        assertEqual(await h.state(), .unavailable(.invalidClock))
        await h.driver.refresh()
        assertEqual(await h.transport.count, 1)
        XCTAssertEqual(h.scheduler.delays, [])
        await h.stop()
    }

    func testStartInBackgroundDoesNotFetchUntilForeground() async throws {
        let h = try Harness()
        await h.driver.setForeground(false)
        await h.driver.start()
        assertEqual(await h.state(), .unavailable(.background))
        assertEqual(await h.transport.count, 0)
        await h.driver.setForeground(true)
        try await h.waitForRequests(1)
        await h.stop()
    }

    func testLateRenewalTimerStartsOnlyOneFetchAfterExpiry() async throws {
        let h = try Harness()
        try await h.install(fixture())
        h.clock.advance(seconds: 210)
        assertTrue(await h.scheduler.fire(delay: 168 * second))
        try await h.waitForRequests(2)
        let next = try fixture {
            $0["issuedAt"] = "2026-08-05T00:04:00.000Z"
            $0["expiresAt"] = "2026-08-05T00:09:00.000Z"
        }
        await h.transport.resolve(1, data: next)
        try await h.waitForState(.document(next))
        for _ in 0 ..< 100 { await Task.yield() }
        assertEqual(await h.transport.count, 2)
        await h.stop()
    }

    func testRepeatedRefreshCoalescesToOnePendingFetch() async throws {
        let h = try Harness()
        await h.driver.start()
        try await h.waitForRequests(1)
        for _ in 0 ..< 10 { await h.driver.refresh() }
        assertEqual(await h.transport.count, 1)
        await h.transport.resolve(0, data: try fixture())
        try await h.waitForRequests(2)
        assertEqual(await h.transport.count, 2)
        await h.stop()
    }

    func testSynchronousGateRejectsDelayedExpiryAndBackgroundTokens() async throws {
        let h = try Harness()
        let data = try fixture()
        try await h.install(data)
        let token = try XCTUnwrap(h.notifications.last)
        let witness = try XCTUnwrap(h.driver.authorityGate.witness(for: token))
        XCTAssertEqual(witness.data, data)
        h.clock.advance(seconds: 210, wall: false)
        // No expiry timer or queued consumer is run before this synchronous check.
        XCTAssertFalse(h.driver.authorityGate.isCurrent(witness))
        await h.stop()

        let background = try Harness()
        try await background.install(data)
        let old = try XCTUnwrap(background.driver.authorityGate.witness(for: XCTUnwrap(background.notifications.last)))
        await background.driver.setForeground(false)
        XCTAssertFalse(background.driver.authorityGate.isCurrent(old))
        await background.stop()
    }

    func testGatePublicationPrecedesNotificationAndCloseInvalidatesWitness() async throws {
        let gateBox = LifecycleBox<EluV2ConfigAuthorityGate?>(nil)
        let observations = LifecycleBox<[Bool]>([])
        let transport = LifecycleTransport()
        let clock = LifecycleClock()
        let driver = try EluV2ConfigLifecycle(siteKey: "elu_pk_live_" + String(repeating: "a", count: 22),
            transport: transport, clock: clock.value, scheduler: LifecycleScheduler(), onChange: { token in
                observations.mutate { $0.append(gateBox.value?.witness(for: token) != nil) }
            })
        gateBox.mutate { $0 = driver.authorityGate }
        await driver.start()
        for _ in 0 ..< 1_000 {
            if await transport.count == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await transport.resolve(0, data: try fixture())
        for _ in 0 ..< 1_000 {
            if observations.value.last == true { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(observations.value.last, true)
        await driver.close()
        XCTAssertEqual(observations.value.last, false)
        await transport.finishAll()
    }

    private func fixture(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Conformance/V2/fixtures/config-enabled.json"))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func inactiveFixture() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "revision": "revoked", "status": "revoked",
            "issuedAt": "2026-08-05T00:01:00.000Z", "expiresAt": "2026-08-05T00:05:00.000Z",
            "reason": "remote-kill-switch",
        ], options: [.sortedKeys])
    }
}

private struct Harness {
    let driver: EluV2ConfigLifecycle
    let transport = LifecycleTransport()
    let clock = LifecycleClock()
    let scheduler = LifecycleScheduler()
    let notifications = LifecycleBox<[EluV2ConfigLifecycleToken]>([])

    init() throws {
        let notifications = notifications
        driver = try EluV2ConfigLifecycle(
            siteKey: "elu_pk_live_" + String(repeating: "a", count: 22),
            transport: transport, clock: clock.value, scheduler: scheduler,
            onChange: { token in notifications.mutate { $0.append(token) } }
        )
    }
    func install(_ data: Data) async throws {
        await driver.start()
        try await waitForRequests(1)
        await transport.resolve(0, data: data)
        try await waitForState(.document(data))
    }
    func state() async -> EluV2ConfigLifecycleState? {
        for _ in 0 ..< 3 {
            guard let token = notifications.value.last else { return nil }
            let box = LifecycleBox<EluV2ConfigLifecycleState?>(nil)
            if await driver.consumeCurrent(token, apply: { state in box.mutate { $0 = state } }) {
                return box.value
            }
        }
        return nil
    }
    func waitForRequests(_ count: Int) async throws {
        try await eventually { await transport.count >= count }
    }
    func waitForState(_ expected: EluV2ConfigLifecycleState) async throws {
        try await eventually { await state() == expected }
    }
    func waitForTimer(_ delay: UInt64) async throws {
        try await eventually { scheduler.delays.contains(delay) }
    }
    func stop() async {
        await driver.close()
        await transport.finishAll()
    }
    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 1_000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Lifecycle condition did not settle")
        throw URLError(.timedOut)
    }
}

private final class LifecycleBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ mutation: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; mutation(&stored) }
}

private extension LifecycleBox where Value == [EluV2ConfigLifecycleToken] {
    var last: EluV2ConfigLifecycleToken? { value.last }
}

private final class LifecycleClock: @unchecked Sendable {
    private struct Sample { var wall = 1_785_888_090.0; var continuous: UInt64 = 1_000_000_001 }
    private let sample = LifecycleBox(Sample())
    var value: EluV2ConfigClock {
        EluV2ConfigClock(
            wallNow: { Date(timeIntervalSince1970: self.sample.value.wall) },
            continuousNow: { self.sample.value.continuous },
            floorTicks: { $0 }, floorNanoseconds: { $0 }
        )
    }
    func advance(seconds: Double, wall: Bool = true) {
        sample.mutate {
            if wall { $0.wall += seconds }
            if seconds >= 0 { $0.continuous += UInt64(seconds * 1_000_000_000) }
            else { $0.continuous -= UInt64(-seconds * 1_000_000_000) }
        }
    }
}

private actor LifecycleTransport: EluV2ConfigTransport {
    private var requests: [CheckedContinuation<Data, Error>?] = []
    var count: Int { requests.count }
    func fetch(_: EluV2ConfigRequest) async throws -> Data {
        // Deliberately ignores cancellation: the lifecycle must keep the slot.
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    func resolve(_ index: Int, data: Data) {
        let continuation = requests[index]; requests[index] = nil
        continuation?.resume(returning: data)
    }
    func fail(_ index: Int) {
        let continuation = requests[index]; requests[index] = nil
        continuation?.resume(throwing: URLError(.notConnectedToInternet))
    }
    func finishAll() {
        for index in requests.indices { fail(index) }
    }
}

private final class LifecycleScheduler: EluV2ConfigLifecycleScheduler, @unchecked Sendable {
    private final class Job: EluV2ConfigScheduledTask, @unchecked Sendable {
        let delay: UInt64
        let action: @Sendable () async -> Void
        let canceled = LifecycleBox(false)
        var fired = false // Accessed only under scheduler lock.
        init(delay: UInt64, action: @escaping @Sendable () async -> Void) {
            self.delay = delay; self.action = action
        }
        func cancel() { canceled.mutate { $0 = true } }
    }
    private let jobs = LifecycleBox<[Job]>([])
    var delays: [UInt64] {
        var result: [UInt64] = []
        jobs.mutate { result = $0.filter { !$0.canceled.value && !$0.fired }.map(\.delay) }
        return result
    }
    func schedule(afterNanoseconds delay: UInt64, action: @escaping @Sendable () async -> Void) -> any EluV2ConfigScheduledTask {
        let job = Job(delay: delay, action: action)
        jobs.mutate { $0.append(job) }
        return job
    }
    func fire(delay: UInt64, includingCancelled: Bool = false) async -> Bool {
        let job: Job? = take(delay: delay, includingCancelled: includingCancelled)
        guard let job else { return false }
        await job.action()
        return true
    }
    private func take(delay: UInt64, includingCancelled: Bool) -> Job? {
        var taken: Job?
        jobs.mutate { list in
            taken = list.first { $0.delay == delay && !$0.fired && (includingCancelled || !$0.canceled.value) }
            taken?.fired = true
        }
        return taken
    }
}

// Arguments are values rather than XCTest autoclosures, so actor reads can be awaited.
private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}
private func assertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value, file: file, line: line)
}
private func assertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(value, file: file, line: line)
}
