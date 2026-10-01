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

    func testExplicitCaptureTimestampSurvivesPendingBuffer() {
        let timestamp = Date(timeIntervalSince1970: 1_785_801_661.125)
        var buffer = EluEventBuffer()
        buffer.push(.capture(event: "delayed", properties: ["amount": 42], timestamp: timestamp))
        guard let operation = buffer.drain().first,
              case let .capture(event, properties, observed, _, _) = operation else {
            return XCTFail("Expected the pending capture")
        }
        XCTAssertEqual(event, "delayed")
        XCTAssertEqual(properties?["amount"] as? Int, 42)
        XCTAssertEqual(observed, timestamp)
        let publicCapture: (String, [String: Any]?, Date) -> Void = Elu.capture(_:properties:timestamp:)
        _ = publicCapture
    }

    func testCaptureOptionsStaySeparateAndPreservePendingFlagIntent() {
        let time = Date(timeIntervalSince1970: 123)
        let options = EluCaptureOptions(set: ["tier": "paid"], setOnce: ["source": "ios"], timestamp: time)
        let publicCapture: (String, [String: Any]?, EluCaptureOptions) -> Void = Elu.capture(_:properties:options:)
        _ = publicCapture
        var buffer = EluEventBuffer()
        buffer.push(.capture(event: "checkout", properties: ["amount": 42], timestamp: options.timestamp,
            set: options.set, setOnce: options.setOnce))
        let op = buffer.drain()[0]
        guard case let .capture(event, properties, timestamp, set, setOnce) = op else { return XCTFail() }
        XCTAssertEqual(event, "checkout"); XCTAssertEqual(timestamp, time)
        XCTAssertEqual(properties?["amount"] as? Int, 42)
        XCTAssertNil(properties?["tier"])
        XCTAssertEqual(set?["tier"] as? String, "paid")
        XCTAssertEqual(setOnce?["source"] as? String, "ios")
        XCTAssertTrue(op.changesFlagContext)
        XCTAssertFalse(EluBufferedOp.capture(event: "ordinary", properties: nil).changesFlagContext)
    }

    private func labels(_ operations: [EluBufferedOp]) -> [String] {
        operations.map { operation in
            switch operation {
            case let .capture(event, _, _, _, _): "capture:\(event)"
            case .reset: "reset"
            case .resetDeviceIdentity: "resetDeviceIdentity"
            case .resetGroups: "resetGroups"
            case .resetPersonPropertiesForFlags: "resetPersonPropertiesForFlags"
            case .resetGroupPropertiesForFlags: "resetGroupPropertiesForFlags"
            case .identify: "identify"
            case .screen: "screen"
            case .alias: "alias"
            case .register: "register"
            case .registerOnce: "registerOnce"
            case .consent: "consent"
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
