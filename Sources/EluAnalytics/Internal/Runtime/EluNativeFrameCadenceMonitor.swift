import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Callback timestamps only: no view, layer, screenshot or rendering inspection.
/// Invalid ordering or excessive observations omit the complete window.
struct EluNativeFrameCadenceWindow {
    static let longIntervalMilliseconds: Double = 50
    private let maximumCallbacks: Int
    private var last: Double?
    private var callbacks: Int64 = 0
    private var intervals: Int64 = 0
    private var longIntervals: Int64 = 0
    private var total: Double = 0
    private var maximum: Double = 0
    private var invalid = false

    init(maximumCallbacks: Int = 1_000_000) { self.maximumCallbacks = maximumCallbacks }
    mutating func observe(timestamp: Double) {
        guard !invalid else { return }
        guard timestamp.isFinite, timestamp >= 0, callbacks < Int64(maximumCallbacks) else { invalid = true; return }
        callbacks += 1
        defer { last = timestamp }
        guard let last else { return }
        let interval = (timestamp - last) * 1_000
        guard interval.isFinite, interval > 0, interval <= 86_400_000,
              total + interval <= 9_007_199_254_740_991 else { invalid = true; return }
        intervals += 1; total += interval; maximum = max(maximum, interval)
        if interval >= Self.longIntervalMilliseconds { longIntervals += 1 }
    }
    mutating func take() -> [String: EluJSONValue]? {
        defer { self = Self(maximumCallbacks: maximumCallbacks) }
        guard !invalid, intervals > 0 else { return nil }
        return [
            "$display_link_callback_count": .integer(callbacks),
            "$display_link_interval_count": .integer(intervals),
            "$display_link_interval_mean_ms": .number(total / Double(intervals)),
            "$display_link_interval_max_ms": .number(maximum),
            "$display_link_long_interval_count": .integer(longIntervals),
            "$display_link_long_interval_threshold_ms": .number(Self.longIntervalMilliseconds),
        ]
    }
}

/// One observer without changing the application's preferred cadence. Logical
/// withdrawal is synchronous; UIKit creation/destruction stays on main.
final class EluNativeFrameCadenceMonitor: @unchecked Sendable {
    private struct Run {
        let id: UUID
        var window = EluNativeFrameCadenceWindow()
        let current: @Sendable () -> Bool
    }
    private let lock = NSLock()
    private var run: Run?
    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    #endif
    deinit { stop() }

    func start(id: UUID, current: @escaping @Sendable () -> Bool) {
        lock.lock()
        // The owner never calls into this monitor while holding its own lock.
        // Check under this lock so a delayed old start cannot replace a newer run.
        guard current() else { lock.unlock(); return }
        run = Run(id: id, current: current)
        #if canImport(UIKit)
        let previous = displayLink; displayLink = nil
        #endif
        lock.unlock()
        #if canImport(UIKit)
        if let previous { DispatchQueue.main.async { previous.invalidate() } }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            let target = EluDisplayLinkTarget(owner: self, id: id)
            let link = CADisplayLink(target: target, selector: #selector(EluDisplayLinkTarget.tick(_:)))
            self.lock.lock()
            guard self.run?.id == id else { self.lock.unlock(); link.invalidate(); return }
            self.displayLink = link
            self.lock.unlock()
            link.add(to: .main, forMode: .common)
        }
        #endif
    }

    func stop(id: UUID? = nil) {
        lock.lock()
        guard id == nil || run?.id == id else { lock.unlock(); return }
        run = nil
        #if canImport(UIKit)
        let previous = displayLink; displayLink = nil
        #endif
        lock.unlock()
        #if canImport(UIKit)
        if let previous { DispatchQueue.main.async { previous.invalidate() } }
        #endif
    }
    func take(id: UUID) -> [String: EluJSONValue]? {
        guard isCurrent(id) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard run?.id == id else { return nil }
        return run?.window.take()
    }
    func observe(id: UUID, timestamp: Double) {
        guard isCurrent(id) else { return }
        lock.lock(); defer { lock.unlock() }
        guard run?.id == id else { return }
        run?.window.observe(timestamp: timestamp)
    }
    private func isCurrent(_ id: UUID) -> Bool {
        lock.lock(); let active = run; lock.unlock()
        return active?.id == id && active?.current() == true
    }
}

#if canImport(UIKit)
private final class EluDisplayLinkTarget: NSObject {
    private weak var owner: EluNativeFrameCadenceMonitor?
    private let id: UUID
    init(owner: EluNativeFrameCadenceMonitor, id: UUID) { self.owner = owner; self.id = id }
    @objc func tick(_ link: CADisplayLink) { owner?.observe(id: id, timestamp: link.timestamp) }
}
#endif
