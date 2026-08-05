import XCTest
@testable import EluAnalytics

final class EluEventBufferTests: XCTestCase {
    func testDrainsStrictlyFIFOIncludingReset() {
        var buffer = EluEventBuffer()
        buffer.push(.capture(event: "before", properties: nil))
        buffer.push(.reset)
        buffer.push(.capture(event: "after", properties: nil))

        XCTAssertEqual(labels(buffer.drain()), ["capture:before", "reset", "capture:after"])
        XCTAssertTrue(buffer.ops.isEmpty)
    }

    func testCapacityDropsOldestOperation() {
        var buffer = EluEventBuffer()
        for index in 0 ... EluEventBuffer.capacity {
            buffer.push(.capture(event: "event-\(index)", properties: nil))
        }

        let drained = labels(buffer.drain())
        XCTAssertEqual(drained.count, EluEventBuffer.capacity)
        XCTAssertEqual(drained.first, "capture:event-1")
        XCTAssertEqual(drained.last, "capture:event-100")
    }

    func testDropAllDoesNotReturnOperations() {
        var buffer = EluEventBuffer()
        buffer.push(.alias("alias"))
        buffer.dropAll()

        XCTAssertTrue(buffer.drain().isEmpty)
    }

    private func labels(_ operations: [EluBufferedOp]) -> [String] {
        operations.map { operation in
            switch operation {
            case let .capture(event, _): "capture:\(event)"
            case .reset: "reset"
            case .identify: "identify"
            case .screen: "screen"
            case .alias: "alias"
            case .register: "register"
            case .unregister: "unregister"
            case .group: "group"
            case .setPersonProperties: "setPersonProperties"
            case .setPersonPropertiesForFlags: "setPersonPropertiesForFlags"
            case .setGroupPropertiesForFlags: "setGroupPropertiesForFlags"
            case .captureException: "captureException"
            }
        }
    }
}
