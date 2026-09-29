#if canImport(UIKit)
import Foundation
import UIKit

/// Charges are conservatively retained until one second after each piece of
/// SDK work ends. Merging old entries uses the later end, never early refill.
/// Customer delivery is never included in a charged interval.
struct EluUIKitReplayTouchWorkBudget {
    static let maximumWorkNanoseconds: UInt64 = 2_000_000
    static let maximumWorkPerSecond: UInt64 = 20_000_000
    static let maximumCharges = 128
    private struct Charge { let ended: UInt64; let cost: UInt64 }
    private var charges: [Charge] = []
    private var lastClock: UInt64?
    private var invalid = false

    mutating func allowance(at now: UInt64) -> UInt64? {
        guard observe(now) else { return nil }
        charges.removeAll { now - $0.ended >= 1_000_000_000 }
        let spent = charges.reduce(UInt64(0)) { sum, charge in
            sum + min(charge.cost, Self.maximumWorkPerSecond - min(sum, Self.maximumWorkPerSecond))
        }
        return min(Self.maximumWorkNanoseconds, Self.maximumWorkPerSecond - spent)
    }

    mutating func charge(from began: UInt64, through ended: UInt64) -> Bool {
        guard !invalid, ended >= began, lastClock.map({ began >= $0 }) ?? true,
              observe(ended) else { invalid = true; return false }
        let cost = min(ended - began, Self.maximumWorkPerSecond)
        guard cost > 0 else { return true }
        charges.append(Charge(ended: ended, cost: cost))
        if charges.count > Self.maximumCharges {
            let first = charges.removeFirst(), second = charges.removeFirst()
            let merged = first.cost + min(second.cost, Self.maximumWorkPerSecond - first.cost)
            charges.insert(Charge(ended: second.ended, cost: merged), at: 0)
        }
        return true
    }

    private mutating func observe(_ now: UInt64) -> Bool {
        guard !invalid, lastClock.map({ now >= $0 }) ?? true else { invalid = true; return false }
        lastClock = now; return true
    }
}

/// Detached input facts for the shared decisions below. The production path
/// obtains these from the original UIKit touch; tests do not fabricate UITouch.
struct EluUIKitReplayTouchFact {
    enum Phase: Equatable { case began, moved, stationary, ended, cancelled }
    let phase: Phase
    let identity: ObjectIdentifier
    let location: CGPoint
    let liveDirectTouches: Int
    let allTouchesLifted: Bool
}

/// Dormant internal component for a future explicit UIWindow.sendEvent bridge.
/// It is not installed by the SDK, adds no recognizer, and does not establish a
/// durable initial-frame commit. Only the future original capture owner may
/// construct it after that commit and publish the exact serialized projection.
@MainActor
final class EluUIKitReplayTouchObserver {
    static let maximumTouches = 10
    private let mailbox: EluNativeReplayInteractionMailbox
    private let isCurrent: @MainActor () -> Bool
    private let sample: @MainActor () -> EluNativeInteractionTime?
    private let continuous: @MainActor () -> UInt64
    private var projection: EluUIKitReplayInteractionProjection?
    private var budget = EluUIKitReplayTouchWorkBudget()
    private var primary: ObjectIdentifier?
    private var active = false
    private var activeIdentity: UUID?
    private var ignoredUntilLift = false
    private var delivering = false
    private var reentered = false
    private var closed = false
    private var lastMove: EluNativeInteractionTime?

    init(projection: EluUIKitReplayInteractionProjection,
         mailbox: EluNativeReplayInteractionMailbox,
         isCurrent: @escaping @MainActor () -> Bool,
         sample: @escaping @MainActor () -> EluNativeInteractionTime?,
         continuous: @escaping @MainActor () -> UInt64) {
        self.projection = projection; self.mailbox = mailbox; self.isCurrent = isCurrent
        self.sample = sample; self.continuous = continuous
    }

    /// The future serial owner orders pending points before this exact serialized
    /// geometry. If a target will disappear, cancel and drain BEFORE serializing
    /// that geometry. This descriptive update cannot arm or allocate an ID.
    func replaceProjection(_ value: EluUIKitReplayInteractionProjection) {
        guard !closed, !delivering, let original = projection, original.window === value.window,
              original.root === value.root, value.ordinal > original.ordinal, isCurrent(), value.privacyIsCurrent,
              activeIdentity.map({ value.containsEligibleIdentity($0) }) ?? true else {
            withdraw(); return
        }
        projection = value
    }

    /// The caller supplies original super.sendEvent(event). Every path invokes
    /// it once, synchronously. No event/UIKit reference leaves MainActor.
    func observe(_ event: UIEvent, deliver: () -> Void) {
        observeDelivery(prepare: { self.prepare(event, deadline: $0) }, deliver: deliver)
    }

    /// Deterministic shared-decision seam only. Facts are detached and the view,
    /// window, collector and projection are real. This does not qualify genuine
    /// UIKit dispatch, recognition, multitouch selection or scrolling.
    func observeForTesting(_ fact: EluUIKitReplayTouchFact, originalView: UIView,
                           deliver: () -> Void) {
        observeDelivery(prepare: { deadline in
            guard let projection = self.projection, let root = projection.root, let window = projection.window,
                  originalView.window === window, self.descendant(originalView, of: root) else {
                self.cancelAndIgnore(); return nil
            }
            return self.prepareFact(fact, projection: projection, deadline: deadline, afterDelivery: {
                originalView.window === window && self.descendant(originalView, of: root)
            })
        }, deliver: deliver)
    }

    private func observeDelivery(prepare: (UInt64) -> Prepared?, deliver: () -> Void) {
        if delivering { reentered = true; deliver(); return }
        guard !closed else { deliver(); return }
        delivering = true; reentered = false
        defer { delivering = false }
        let begun = continuous()
        guard let allowance = budget.allowance(at: begun) else { withdraw(); deliver(); return }
        let (preDeadline, overflow) = begun.addingReportingOverflow(allowance)
        let prepared = allowance == 0 || overflow ? nil : prepare(preDeadline)
        let preEnd = continuous()
        guard budget.charge(from: begun, through: preEnd) else { withdraw(); deliver(); return }
        let preElapsed = preEnd - begun
        // Exclude exactly the original synchronous application dispatch interval.
        deliver()
        guard !closed else { return }
        let postBegin = continuous()
        guard let rollingAllowance = budget.allowance(at: postBegin) else { withdraw(); return }
        defer { if !budget.charge(from: postBegin, through: continuous()) { withdraw() } }
        guard isCurrent(), projection?.privacyIsCurrent == true else { withdraw(); return }
        guard !reentered, !overflow, allowance > preElapsed, rollingAllowance > 0 else { cancelAndIgnore(); return }
        guard let prepared else { return }
        let remaining = min(allowance - preElapsed, rollingAllowance)
        let (postDeadline, postOverflow) = postBegin.addingReportingOverflow(remaining)
        guard !postOverflow else { cancelAndIgnore(); return }
        finish(prepared, deadline: postDeadline)
    }

    /// Order cancellation with old geometry before removing its active target.
    func cancelForGeometryChange() { if !closed { cancelAndIgnore() } }

    func stop() {
        guard !closed else { return }
        if isCurrent() { cancelAndIgnore() } else { mailbox.withdraw() }
        closed = true; primary = nil; projection = nil
    }
    func withdraw() {
        closed = true; active = false; activeIdentity = nil; primary = nil; ignoredUntilLift = true; projection = nil
        mailbox.withdraw()
    }

    private struct Prepared {
        let fact: EluUIKitReplayTouchFact
        let point: EluNativeInteractionPoint?
        let time: EluNativeInteractionTime
        let retain: Bool
        let projection: EluUIKitReplayInteractionProjection
        let afterDelivery: @MainActor () -> Bool
    }

    private func prepare(_ event: UIEvent, deadline: UInt64) -> Prepared? {
        guard event.type == .touches else { return nil }
        guard isCurrent(), let projection, projection.privacyIsCurrent, let window = projection.window, let root = projection.root else {
            withdraw(); return nil
        }
        guard let touches = event.touches(for: window), touches.count <= Self.maximumTouches else {
            cancelAndIgnore(); return nil
        }
        let live = touches.filter { $0.phase != .ended && $0.phase != .cancelled }
        if ignoredUntilLift {
            if live.isEmpty { ignoredUntilLift = false; primary = nil }
            return nil
        }
        let direct = touches.filter { $0.type == .direct }
        guard !direct.isEmpty else { return nil }
        let liveDirectCount = live.filter { $0.type == .direct }.count
        guard liveDirectCount <= 1 else { cancelAndIgnore(); return nil }
        let touch: UITouch
        if let primary {
            guard let original = direct.first(where: { ObjectIdentifier($0) == primary }) else {
                cancelAndIgnore(); return nil
            }
            touch = original
        } else {
            let beginnings = direct.filter { $0.phase == .began }
            guard beginnings.count == 1, let beginning = beginnings.first else { return nil }
            touch = beginning
        }
        let phase: EluUIKitReplayTouchFact.Phase
        switch touch.phase {
        case .began: phase = .began
        case .moved: phase = .moved
        case .stationary: phase = .stationary
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        @unknown default: cancelAndIgnore(); return nil
        }
        guard continuous() <= deadline, touch.window === window,
              descendant(touch.view, of: root) else { cancelAndIgnore(); return nil }
        let location = phase == .cancelled ? CGPoint.zero : touch.location(in: root)
        let fact = EluUIKitReplayTouchFact(phase: phase, identity: ObjectIdentifier(touch), location: location,
            liveDirectTouches: liveDirectCount, allTouchesLifted: live.isEmpty)
        return prepareFact(fact, projection: projection, deadline: deadline, afterDelivery: {
            touch.window === window && self.descendant(touch.view, of: root)
                && (phase == .cancelled || touch.location(in: root) == location)
        })
    }

    private func prepareFact(_ fact: EluUIKitReplayTouchFact, projection: EluUIKitReplayInteractionProjection,
                             deadline: UInt64, afterDelivery: @escaping @MainActor () -> Bool) -> Prepared? {
        guard isCurrent(), self.projection === projection, projection.privacyIsCurrent else { withdraw(); return nil }
        if ignoredUntilLift {
            if fact.allTouchesLifted { ignoredUntilLift = false; primary = nil }
            return nil
        }
        guard (0 ... 1).contains(fact.liveDirectTouches),
              primary.map({ $0 == fact.identity }) ?? (fact.phase == .began) else { cancelAndIgnore(); return nil }
        guard let time = sample() else { withdraw(); return nil }
        var retain = fact.phase != .stationary
        if fact.phase == .moved, let old = lastMove {
            guard time.timestamp >= old.timestamp, time.continuous >= old.continuous else { withdraw(); return nil }
            // Throttling skips retention only. Privacy/location checks below and
            // after original delivery run even for a discarded movement sample.
            if time.timestamp - old.timestamp < 100 || time.continuous - old.continuous < 100_000_000 { retain = false }
        }
        guard continuous() <= deadline else { cancelAndIgnore(); return nil }
        if fact.phase == .cancelled {
            return Prepared(fact: fact, point: nil, time: time, retain: true, projection: projection, afterDelivery: afterDelivery)
        }
        guard let point = projection.point(location: fact.location, time: time, deadline: deadline, now: continuous) else {
            cancelAndIgnore(); return nil
        }
        return Prepared(fact: fact, point: point, time: time, retain: retain, projection: projection, afterDelivery: afterDelivery)
    }

    private func finish(_ original: Prepared, deadline: UInt64) {
        guard let projection, original.projection === projection, isCurrent(), projection.privacyIsCurrent,
              original.afterDelivery() else { cancelAndIgnore(); return }
        let fact = original.fact
        let value: EluNativeInteraction
        switch fact.phase {
        case .cancelled:
            guard active else { primary = nil; return }
            value = .cancel(original.time)
        case .began, .moved, .stationary, .ended:
            guard let before = original.point,
                  let after = projection.point(location: fact.location, time: original.time,
                    deadline: deadline, now: continuous), after == before else { cancelAndIgnore(); return }
            guard original.retain else { return }
            switch fact.phase {
            case .began: value = .start(after)
            case .moved: value = .moves([after])
            case .ended: value = .end(after)
            case .stationary, .cancelled: return
            }
        }
        let result = mailbox.offer(value)
        guard result == .retained else {
            if result == .refused { withdraw() }
            active = false; activeIdentity = nil; primary = nil; ignoredUntilLift = true
            return
        }
        if fact.phase == .began { active = true; primary = fact.identity }
        if fact.phase == .moved { lastMove = original.time }
        if case let .start(point) = value { activeIdentity = point.identity }
        if case let .moves(points) = value { activeIdentity = points.last?.identity }
        if value.isTerminal { active = false; activeIdentity = nil; primary = nil }
    }

    private func cancelAndIgnore() {
        if active {
            if isCurrent(), projection?.privacyIsCurrent == true, let time = sample(), mailbox.offer(.cancel(time)) == .retained {
                active = false
            } else { mailbox.withdraw(); active = false }
        }
        ignoredUntilLift = true; primary = nil; activeIdentity = nil
    }

    private func descendant(_ view: UIView?, of root: UIView) -> Bool {
        var current = view
        for _ in 0 ..< 64 {
            guard let value = current else { return false }
            if value === root { return true }
            current = value.superview
        }
        return false
    }
}
#endif
