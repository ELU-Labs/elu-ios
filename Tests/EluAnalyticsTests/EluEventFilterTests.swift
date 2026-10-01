import Foundation
import XCTest
@testable import EluAnalytics

final class EluEventFilterTests: XCTestCase {
    private func command() throws -> EluV1CaptureCommand {
        .init(kind: .capture, name: "original", occurredAt: Date(timeIntervalSince1970: 1_785_888_090),
            properties: [:], versions: try .init(runtime: .init(name: "elu-ios", version: "0.2.0"),
                facade: .init(name: "Elu", version: "1")))
    }
    private let empty = EluEventPersonChanges(set: nil, setOnce: nil)

    func testDenylistPrecedesHookAndProtectedMetadataIsNeverCustomerWritable() throws {
        let box = EventFilterCounter()
        let filter = EluEventFilter(propertyDenylist: ["secret"], beforeSend: { event in
            box.hit()
            XCTAssertNil(event.properties["secret"])
            XCTAssertNil(event.properties["$device_id"])
            XCTAssertEqual(event.properties["super"] as? String, "kept")
            var changed = event
            changed.event = "changed"
            changed.properties["secret"] = "deliberately restored"
            changed.properties["$device_id"] = "forged"
            changed.properties["$elu_sdk_version"] = "forged"
            changed.set = ["tier": "paid"]
            changed.setOnce = [:]
            changed.timestamp.addTimeInterval(1)
            return changed
        })
        let original = try command()
        let result = try filter.apply(original, mergedProperties: ["secret": .string("hidden"),
            "super": .string("kept"), "$device_id": .string("owned")], person: empty, allowsPersonChanges: true)
        XCTAssertEqual(box.count, 1)
        XCTAssertEqual(result.command.name, "changed")
        XCTAssertEqual(result.command.occurredAt, original.occurredAt.addingTimeInterval(1))
        XCTAssertEqual(result.command.properties["secret"], .string("deliberately restored"))
        XCTAssertNil(result.command.properties["$device_id"])
        XCTAssertNil(result.command.properties["$elu_sdk_version"])
        XCTAssertEqual(result.person.set, ["tier": .string("paid")])
        XCTAssertEqual(result.person.setOnce, [:])
    }

    func testDenylistMatchesExactUnicodePropertySpelling() throws {
        let result = try EluEventFilter(propertyDenylist: ["é"]).apply(command(),
            mergedProperties: ["e\u{301}": .string("distinct spelling")], person: empty, allowsPersonChanges: false)
        XCTAssertEqual(result.command.properties["e\u{301}"], .string("distinct spelling"))
    }

    func testDropThrowAndInvalidReplacementNeverFallBackToOriginal() throws {
        struct Failure: Error {}
        let filters: [EluEventFilter] = [
            .init(beforeSend: { _ in nil }), .init(beforeSend: { _ in throw Failure() }),
            .init(beforeSend: { event in var event = event; event.event = ""; return event }),
            .init(beforeSend: { event in var event = event; event.properties["bad"] = NSObject(); return event }),
            .init(beforeSend: { event in var event = event; event.timestamp = Date(timeIntervalSince1970: .nan); return event })
        ]
        for filter in filters {
            XCTAssertThrowsError(try filter.apply(command(), mergedProperties: ["secret": .string("must not leak")],
                person: empty, allowsPersonChanges: true))
        }
    }

    func testReplacementContainersAreDetachedAndCyclesOrExcessiveWorkAreRefused() throws {
        let box = EventFilterContainers()
        let result = try EluEventFilter(beforeSend: { event in
            var event = event; event.properties = ["nested": box.object]; return event
        }).apply(command(), mergedProperties: [:], person: empty, allowsPersonChanges: true)
        box.object["value"] = "after"
        XCTAssertEqual(result.command.properties["nested"], .object(["value": .string("before")]))
        let cycle = NSMutableArray(); cycle.add(cycle)
        box.object["cycle"] = cycle
        defer { box.object.removeObject(forKey: "cycle"); cycle.removeAllObjects() }
        XCTAssertThrowsError(try EluEventFilter(beforeSend: { event in
            var event = event; event.properties = ["nested": box.object]; return event
        }).apply(command(), mergedProperties: [:], person: empty, allowsPersonChanges: true))
        XCTAssertThrowsError(try EluEventFilter(beforeSend: { event in
            var event = event; event.properties = ["wide": Array(repeating: 1, count: 1_025)]; return event
        }).apply(command(), mergedProperties: [:], person: empty, allowsPersonChanges: true))
        XCTAssertThrowsError(try EluEventFilter(beforeSend: { event in
            var event = event; event.properties = ["large": String(repeating: "x", count: 2_000_000)]; return event
        }).apply(command(), mergedProperties: [:], person: empty, allowsPersonChanges: true))
    }

    func testAutomaticPersonOutputIsRefusedAndManualHookCanRemoveAllIntent() throws {
        let adding = EluEventFilter(beforeSend: { event in var event = event; event.set = [:]; return event })
        XCTAssertThrowsError(try adding.apply(command(), mergedProperties: [:], person: empty, allowsPersonChanges: false)) {
            XCTAssertEqual($0 as? EluEventFilterFailure, .unsupportedPersonChanges)
        }
        let removing = EluEventFilter(beforeSend: { event in var event = event; event.set = nil; event.setOnce = nil; return event })
        let result = try removing.apply(command(), mergedProperties: [:], person: .init(set: ["secret": .string("x")], setOnce: [:]),
            allowsPersonChanges: true)
        XCTAssertFalse(result.person.hasIntent)
    }

    func testOneOriginalAttemptCachesTransformAndRefusesDifferentOwnerCommandOrSource() throws {
        let attempt = EluEventFilterAttempt(), box = EventFilterCounter(), owner = UUID(), original = try command()
        let filter = EluEventFilter(beforeSend: { event in box.hit(); return event })
        func apply(_ id: UUID, _ properties: [String: EluJSONValue] = [:]) throws -> EluFilteredEvent {
            try attempt.apply(owner: id, command: original, mergedProperties: properties, isCurrent: { box.current }) {
                try filter.apply(original, mergedProperties: properties, person: empty, allowsPersonChanges: false)
            }
        }
        XCTAssertEqual(try apply(owner), try apply(owner))
        XCTAssertEqual(box.count, 1)
        XCTAssertThrowsError(try apply(UUID()))
        XCTAssertThrowsError(try apply(owner, ["changed": .bool(true)]))
        box.withdraw()
        XCTAssertThrowsError(try apply(owner))
        XCTAssertEqual(box.count, 1)
    }

    func testCallbackWithdrawalAndRecursiveAttemptCannotPublishOrInvokeTwice() throws {
        let attempt = EluEventFilterAttempt(), box = EventFilterCounter(), owner = UUID(), original = try command()
        XCTAssertThrowsError(try attempt.apply(owner: owner, command: original, mergedProperties: [:], isCurrent: { box.current }) {
            box.hit()
            XCTAssertThrowsError(try attempt.apply(owner: owner, command: original, mergedProperties: [:], isCurrent: { true }) {
                XCTFail("Recursive attempt must not call customer code")
                return .init(command: original, person: self.empty)
            })
            box.withdraw()
            return .init(command: original, person: self.empty)
        })
        XCTAssertEqual(box.count, 1)
    }
}

final class EventFilterCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var live = true
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var current: Bool { lock.lock(); defer { lock.unlock() }; return live }
    func hit() { lock.lock(); calls += 1; lock.unlock() }
    func withdraw() { lock.lock(); live = false; lock.unlock() }
}

private final class EventFilterContainers: @unchecked Sendable {
    // Tests mutate only before/after the synchronous callback, never concurrently.
    let object = NSMutableDictionary(dictionary: ["value": "before"])
}
