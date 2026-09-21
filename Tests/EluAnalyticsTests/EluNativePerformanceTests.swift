import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativePerformanceTests: XCTestCase {
    private func remote(memory: Bool = true, stalls: Bool = true, interval: Int = 5_000) throws -> EluCapturePerformancePolicy {
        try JSONDecoder().decode(EluCapturePerformancePolicy.self, from: JSONSerialization.data(withJSONObject:
            ["memory": memory, "long_tasks": stalls, "sample_interval_ms": interval]))
    }
    func testDisabledMissingInvalidAndNarrowedRemotePolicy() throws {
        let policy = try remote(memory: true, stalls: false, interval: 60_000)
        XCTAssertNil(EluNativePerformanceSettings.resolve(.init(), remote: policy))
        XCTAssertNil(EluNativePerformanceSettings.resolve(.init(enabled: true), remote: nil))
        XCTAssertNil(EluNativePerformanceSettings.resolve(.init(enabled: true, sampleIntervalMilliseconds: 4_999), remote: policy))
        XCTAssertNil(EluNativePerformanceSettings.resolve(.init(enabled: true, mainThreadStallThresholdMilliseconds: 0), remote: policy))
        let selected = try XCTUnwrap(EluNativePerformanceSettings.resolve(.init(enabled: true), remote: policy))
        XCTAssertTrue(selected.memory); XCTAssertFalse(selected.mainThreadStalls)
        XCTAssertEqual(selected.intervalMilliseconds, 60_000)
        XCTAssertNil(EluNativePerformanceSettings.resolve(.init(enabled: true, memory: false), remote: policy))
    }
    func testOneOutstandingProbeCompletedThresholdAndWindowReset() throws {
        let settings = try XCTUnwrap(EluNativePerformanceSettings.resolve(
            .init(enabled: true, sampleIntervalMilliseconds: 5_000), remote: remote()))
        var window = EluNativePerformanceWindow(settings: settings, now: 0)
        XCTAssertTrue(try XCTUnwrap(window.tick(at: 0)).probe)
        XCTAssertFalse(try XCTUnwrap(window.tick(at: 200_000_000)).probe)
        XCTAssertTrue(window.acknowledge(at: 249_999_999))
        XCTAssertTrue(try XCTUnwrap(window.tick(at: 250_000_000)).probe)
        XCTAssertTrue(window.acknowledge(at: 500_000_000))
        let fields = try XCTUnwrap(window.tick(at: 5_000_000_000)?.fields)
        XCTAssertEqual(fields["$main_thread_stall_count"], .integer(1))
        XCTAssertEqual(fields["$main_thread_stall_total_ms"], .number(250))
        XCTAssertEqual(fields["$main_thread_stall_max_ms"], .number(250))
        XCTAssertFalse(try XCTUnwrap(window.tick(at: 6_000_000_000)).probe)
        XCTAssertTrue(window.acknowledge(at: 6_000_000_000))
        let second = try XCTUnwrap(window.tick(at: 10_000_000_000)?.fields)
        XCTAssertEqual(second["$main_thread_stall_count"], .integer(1))
        XCTAssertEqual(second["$main_thread_stall_total_ms"], .number(1_000))
        XCTAssertNil(window.tick(at: 9_999_999_999), "monotonic regression closes the run")
    }
    func testMemoryOnlyNeverSchedulesMainProbeAndCannotInventStallZero() throws {
        let settings = try XCTUnwrap(EluNativePerformanceSettings.resolve(
            .init(enabled: true, mainThreadStalls: false, sampleIntervalMilliseconds: 5_000), remote: remote()))
        var window = EluNativePerformanceWindow(settings: settings, now: 0)
        XCTAssertFalse(try XCTUnwrap(window.tick(at: 0)).probe)
        XCTAssertEqual(try XCTUnwrap(window.tick(at: 5_000_000_000)?.fields), [:])
    }
    func testPendingProbeFromPreviousRunCannotScheduleAnother() throws {
        let settings = try XCTUnwrap(EluNativePerformanceSettings.resolve(.init(enabled: true), remote: remote()))
        var window = EluNativePerformanceWindow(settings: settings, now: 0)
        XCTAssertFalse(try XCTUnwrap(window.tick(at: 100, canProbe: false)).probe)
        XCTAssertTrue(try XCTUnwrap(window.tick(at: 200, canProbe: true)).probe)
    }
    func testMonitorDropsPendingMutationBackgroundAndWithdrawnAuthority() async throws {
        let clock = PerformanceTestClock(), received = PerformanceTestSamples()
        let monitor = EluNativePerformanceMonitor(now: { clock.read() }, footprint: { 123_456 })
        defer { monitor.invalidate() }
        let settings = try XCTUnwrap(EluNativePerformanceSettings.resolve(
            .init(enabled: true, mainThreadStalls: false, sampleIntervalMilliseconds: 5_000), remote: remote()))
        let start = { monitor.start(settings: settings, authority: { true }) { received.append($0, $1) } }
        // Foreground must be explicitly observed, including after pending work.
        start(); clock.advance(5_000_000_000)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(received.values().isEmpty)
        monitor.setForeground(true)
        let mutation = monitor.beginMutation()
        start(); clock.advance(5_000_000_000)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(received.values().isEmpty)
        monitor.finishMutation(mutation); start(); clock.advance(5_000_000_000)
        for _ in 0 ..< 20 {
            if !received.values().isEmpty { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let sample = try XCTUnwrap(received.values().first)
        XCTAssertTrue(monitor.isCurrent(sample.0))
        XCTAssertEqual(sample.1["$memory_process_footprint_bytes"], .integer(123_456))
        XCTAssertEqual(sample.1["$performance_platform"], .string("ios"))
        XCTAssertEqual(sample.1["$performance_sample_index"], .integer(1))
        XCTAssertNil(sample.1["$main_thread_stall_count"])
        monitor.setForeground(false)
        XCTAssertFalse(monitor.isCurrent(sample.0))
        clock.advance(5_000_000_000)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(received.values().count, 1)
        monitor.setForeground(true)
        monitor.start(settings: settings, authority: { false }) { received.append($0, $1) }
        clock.advance(5_000_000_000)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(received.values().count, 1)
    }
    func testUnavailableMemoryDoesNotReportZero() async throws {
        let clock = PerformanceTestClock(), received = PerformanceTestSamples()
        let monitor = EluNativePerformanceMonitor(now: { clock.read() }, footprint: { nil })
        defer { monitor.invalidate() }
        monitor.setForeground(true)
        let settings = try XCTUnwrap(EluNativePerformanceSettings.resolve(
            .init(enabled: true, mainThreadStalls: false, sampleIntervalMilliseconds: 5_000), remote: remote()))
        monitor.start(settings: settings, authority: { true }) { received.append($0, $1) }
        clock.advance(5_000_000_000)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(received.values().isEmpty)
    }
}

private final class PerformanceTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var now: UInt64 = 0
    func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return now }
    func advance(_ value: UInt64) { lock.lock(); now += value; lock.unlock() }
}
private final class PerformanceTestSamples: @unchecked Sendable {
    private let lock = NSLock(); private var samples: [(UUID, [String: EluJSONValue])] = []
    func append(_ id: UUID, _ fields: [String: EluJSONValue]) { lock.lock(); samples.append((id, fields)); lock.unlock() }
    func values() -> [(UUID, [String: EluJSONValue])] { lock.lock(); defer { lock.unlock() }; return samples }
}
