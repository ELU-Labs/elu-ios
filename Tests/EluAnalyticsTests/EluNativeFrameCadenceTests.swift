import Foundation
import XCTest
@testable import EluAnalytics
#if canImport(UIKit)
import UIKit
#endif

final class EluNativeFrameCadenceTests: XCTestCase {
    func testCadenceReportsCallbackIntervalsWithoutInventingRenderedFrames() throws {
        var window = EluNativeFrameCadenceWindow()
        window.observe(timestamp: 10)
        window.observe(timestamp: 10.01)
        window.observe(timestamp: 10.07)
        let fields = try XCTUnwrap(window.take())
        XCTAssertEqual(fields["$display_link_callback_count"], .integer(3))
        XCTAssertEqual(fields["$display_link_interval_count"], .integer(2))
        XCTAssertEqual(fields["$display_link_long_interval_count"], .integer(1))
        XCTAssertEqual(fields["$display_link_long_interval_threshold_ms"], .number(50))
        guard case let .number(mean)? = fields["$display_link_interval_mean_ms"],
              case let .number(maximum)? = fields["$display_link_interval_max_ms"] else { return XCTFail("Missing duration") }
        XCTAssertEqual(mean, 35, accuracy: 0.00001)
        XCTAssertEqual(maximum, 60, accuracy: 0.00001)
        XCTAssertEqual(fields.count, 6)
        XCTAssertNil(window.take(), "Empty or unsupported callback windows must not invent zero")
    }

    func testFirstCallbackAndWindowsNeverCreateCrossBoundaryIntervals() throws {
        var window = EluNativeFrameCadenceWindow()
        XCTAssertNil(window.take())
        window.observe(timestamp: 1); XCTAssertNil(window.take())
        window.observe(timestamp: 99); window.observe(timestamp: 99.02)
        let fields = try XCTUnwrap(window.take())
        XCTAssertEqual(fields["$display_link_callback_count"], .integer(2))
        XCTAssertEqual(fields["$display_link_interval_count"], .integer(1))
        XCTAssertEqual(fields["$display_link_long_interval_count"], .integer(0))
    }

    func testInvalidDuplicateRegressingAndExcessiveWindowsAreOmitted() {
        for bad in [Double.nan, Double.infinity, -1, 1, 0.5, 100_000] {
            var window = EluNativeFrameCadenceWindow()
            window.observe(timestamp: 1); window.observe(timestamp: bad)
            window.observe(timestamp: 100_001)
            XCTAssertNil(window.take())
            window.observe(timestamp: 2); window.observe(timestamp: 2.01)
            XCTAssertNotNil(window.take(), "A later independent valid window can recover")
        }
        var bounded = EluNativeFrameCadenceWindow(maximumCallbacks: 2)
        bounded.observe(timestamp: 0); bounded.observe(timestamp: 0.01); bounded.observe(timestamp: 0.02)
        XCTAssertNil(bounded.take(), "Never silently clip callback counts")
    }

    func testMonitorRejectsOldGenerationAndSynchronousWithdrawal() throws {
        let monitor = EluNativeFrameCadenceMonitor(), first = UUID(), second = UUID()
        defer { monitor.stop() }
        monitor.start(id: first, current: { true })
        monitor.observe(id: first, timestamp: 1); monitor.observe(id: first, timestamp: 1.01)
        XCTAssertNotNil(monitor.take(id: first))
        monitor.start(id: second, current: { true })
        monitor.stop(id: first)
        monitor.start(id: first, current: { false })
        monitor.observe(id: first, timestamp: 100); monitor.observe(id: first, timestamp: 101)
        XCTAssertNil(monitor.take(id: first)); XCTAssertNil(monitor.take(id: second))
        monitor.observe(id: second, timestamp: 1); monitor.observe(id: second, timestamp: 1.01)
        XCTAssertNotNil(monitor.take(id: second), "Delayed old start/stop cannot destroy the new run")
        monitor.stop()
        XCTAssertNil(monitor.take(id: second))
        monitor.start(id: UUID(), current: { false })
        XCTAssertNil(monitor.take(id: second))
    }

    func testAuthorityWithdrawalDiscardsAlreadyObservedIntervals() {
        let authority = CadenceTestAuthority(), monitor = EluNativeFrameCadenceMonitor(), id = UUID()
        defer { monitor.stop() }
        monitor.start(id: id, current: { authority.allowed })
        monitor.observe(id: id, timestamp: 1); monitor.observe(id: id, timestamp: 1.02)
        authority.withdraw()
        XCTAssertNil(monitor.take(id: id))
        monitor.observe(id: id, timestamp: 1.04)
        XCTAssertNil(monitor.take(id: id))
    }

    #if canImport(UIKit)
    @MainActor
    func testActualDisplayLinkProducesCadenceAndStopsWithoutRetainingOwner() async throws {
        var monitor: EluNativeFrameCadenceMonitor? = EluNativeFrameCadenceMonitor()
        weak var weakMonitor = monitor
        let id = UUID()
        monitor?.start(id: id, current: { true })
        var fields: [String: EluJSONValue]?
        for _ in 0 ..< 30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            fields = monitor?.take(id: id)
            if fields != nil { break }
        }
        let sample = try XCTUnwrap(fields, "A foreground UIKit test host must deliver real display-link callbacks")
        guard case let .integer(count)? = sample["$display_link_callback_count"] else { return XCTFail("Missing callback count") }
        XCTAssertGreaterThan(count, 1)
        monitor?.stop(id: id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(monitor?.take(id: id))
        monitor = nil
        XCTAssertNil(weakMonitor, "The run loop target must not retain the SDK owner")
    }
    #endif
}

private final class CadenceTestAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var allowed: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func withdraw() { lock.lock(); value = false; lock.unlock() }
}
