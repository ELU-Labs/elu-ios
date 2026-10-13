import Foundation
import XCTest
@testable import EluAnalytics

final class EluExceptionSerializerTests: XCTestCase {
    private struct CheckoutFailure: LocalizedError {
        var errorDescription: String? { "checkout failed" }
    }

    private enum PlainFailure: Error {
        case boom
    }

    /// An error object whose underlying error can be assigned after creation,
    /// so a chain can be made to point back at its own head.
    private final class LinkedFailure: NSError {
        var next: LinkedFailure?

        init(name: String, code: Int = 1) {
            super.init(domain: name, code: code, userInfo: nil)
        }

        required init?(coder _: NSCoder) {
            return nil
        }

        override var userInfo: [String: Any] {
            guard let next else { return [:] }
            return [NSUnderlyingErrorKey: next]
        }
    }

    func testPropertiesCarryTypeMessageModuleAndOneEntryPerLink() throws {
        let inner = NSError(
            domain: "inner",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "inner failure"]
        )
        let outer = NSError(
            domain: "outer",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "outer failure", NSUnderlyingErrorKey: inner]
        )

        let properties = EluExceptionSerializer.properties(for: outer)

        XCTAssertEqual(properties[EluExceptionSerializer.typeProperty], .string("NSError"))
        XCTAssertEqual(properties[EluExceptionSerializer.messageProperty], .string("outer failure"))
        guard case let .array(list)? = properties[EluExceptionSerializer.listProperty],
              list.count == 2,
              case let .object(first) = list[0],
              case let .object(second) = list[1]
        else {
            return XCTFail("Expected two chained entries")
        }
        XCTAssertEqual(first["type"], .string("NSError"))
        XCTAssertEqual(first["value"], .string("outer failure"))
        XCTAssertEqual(first["domain"], .string("outer"))
        XCTAssertEqual(first["code"], .integer(7))
        XCTAssertEqual(second["value"], .string("inner failure"))
        XCTAssertEqual(second["domain"], .string("inner"))
        XCTAssertEqual(second["code"], .integer(3))
        for value in properties.values {
            XCTAssertNoThrow(try value.validate())
        }
    }

    func testSwiftErrorsUseTheirDescriptionAndModule() throws {
        let localized = EluExceptionSerializer.properties(for: CheckoutFailure())
        XCTAssertEqual(localized[EluExceptionSerializer.typeProperty], .string("CheckoutFailure"))
        XCTAssertEqual(localized[EluExceptionSerializer.messageProperty], .string("checkout failed"))
        guard case let .array(list)? = localized[EluExceptionSerializer.listProperty],
              case let .object(entry)? = list.first
        else {
            return XCTFail("Expected one entry")
        }
        XCTAssertEqual(entry["module"], .string("EluAnalyticsTests"))
        XCTAssertNil(entry["domain"])
        XCTAssertNil(entry["code"])

        let plain = EluExceptionSerializer.properties(for: PlainFailure.boom)
        XCTAssertEqual(plain[EluExceptionSerializer.typeProperty], .string("PlainFailure"))
        XCTAssertEqual(plain[EluExceptionSerializer.messageProperty], .string("boom"))
    }

    func testChainsMessagesAndCyclesAreBounded() throws {
        var chain = LinkedFailure(name: "link-0")
        for index in 1 ... 20 {
            let link = LinkedFailure(name: "link-\(index)")
            link.next = chain
            chain = link
        }
        guard case let .array(chainList)? = EluExceptionSerializer.properties(for: chain)[
            EluExceptionSerializer.listProperty
        ] else {
            return XCTFail("Expected a chain list")
        }
        XCTAssertEqual(chainList.count, EluExceptionSerializer.maximumChainLength)

        let cycleA = LinkedFailure(name: "a")
        let cycleB = LinkedFailure(name: "b")
        cycleA.next = cycleB
        cycleB.next = cycleA
        guard case let .array(cycleList)? = EluExceptionSerializer.properties(for: cycleA)[
            EluExceptionSerializer.listProperty
        ] else {
            return XCTFail("Expected a cycle list")
        }
        XCTAssertEqual(cycleList.count, 2)

        let long = NSError(
            domain: "long",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(repeating: "m", count: 5_000)]
        )
        guard case let .string(message)? = EluExceptionSerializer.properties(for: long)[
            EluExceptionSerializer.messageProperty
        ] else {
            return XCTFail("Expected a bounded message")
        }
        XCTAssertEqual(message.unicodeScalars.count, EluExceptionSerializer.maximumMessageCodePoints)
    }

    func testBoundingKeepsWholeScalars() {
        XCTAssertEqual(EluExceptionSerializer.bounded("😀😀", maximumCodePoints: 1), "😀")
        XCTAssertEqual(EluExceptionSerializer.bounded("ok 😀 end", maximumCodePoints: 64), "ok 😀 end")
        XCTAssertEqual(EluExceptionSerializer.bounded("abc", maximumCodePoints: 2), "ab")
    }

    func testCommandUsesTheExceptionKindAndLetsExplicitPropertiesWin() throws {
        let command = EluExceptionSerializer.command(
            for: CheckoutFailure(),
            occurredAt: Date(timeIntervalSince1970: 1_785_801_660),
            versions: try EluVersionContext(
                runtime: EluVersionComponent(name: "elu-ios", version: "0.1.0"),
                facade: EluVersionComponent(name: "Elu", version: "1")
            ),
            explicitProperties: [
                EluExceptionSerializer.messageProperty: .string("redacted"),
                "screen": .string("Checkout"),
            ]
        )

        XCTAssertEqual(command.kind, .exception)
        XCTAssertEqual(command.name, EluExceptionSerializer.eventName)
        XCTAssertEqual(command.properties[EluExceptionSerializer.typeProperty], .string("CheckoutFailure"))
        XCTAssertEqual(command.properties[EluExceptionSerializer.messageProperty], .string("redacted"))
        XCTAssertEqual(command.properties["screen"], .string("Checkout"))
    }
}
