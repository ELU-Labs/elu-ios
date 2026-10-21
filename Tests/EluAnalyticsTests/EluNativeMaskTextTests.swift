import Foundation
import XCTest
@testable import EluAnalytics

/// Runs every case of the shared vector file that the web rule generated. The
/// Android SDK and the service validate the same file, so output must match exactly.
final class EluNativeMaskTextTests: XCTestCase {
    private struct Vectors {
        let maxBytes: Int
        let whitespace: [UInt16]
        let text: [(input: String, expected: String)]
        let input: [(input: String, length: Int, expected: String)]
        let shaped: [(value: String, expected: Bool)]
    }

    func testEveryTextVectorMatchesTheWebRule() throws {
        let vectors = try load()
        XCTAssertEqual(vectors.maxBytes, EluNativeMaskText.maximumBytes)
        XCTAssertEqual(vectors.text.count, 21)
        for (index, item) in vectors.text.enumerated() {
            let actual = EluNativeMaskText.maskText(item.input)
            XCTAssertEqual(Array(actual.utf16), Array(item.expected.utf16), "text vector \(index)")
            XCTAssertLessThanOrEqual(actual.utf8.count, vectors.maxBytes, "text vector \(index)")
            XCTAssertTrue(EluNativeMaskText.isMaskShaped(actual), "text vector \(index)")
        }
    }

    func testEveryInputVectorMatchesTheWebRule() throws {
        let vectors = try load()
        XCTAssertEqual(vectors.input.count, 9)
        for (index, item) in vectors.input.enumerated() {
            XCTAssertEqual(item.input.utf16.count, item.length, "input vector \(index)")
            XCTAssertEqual((item.input as NSString).length, item.length, "input vector \(index)")
            let actual = EluNativeMaskText.maskInput(utf16Length: item.length)
            XCTAssertEqual(Array(actual.utf16), Array(item.expected.utf16), "input vector \(index)")
            XCTAssertTrue(EluNativeMaskText.isInputMask(actual), "input vector \(index)")
        }
    }

    func testEveryMaskShapeVectorMatches() throws {
        let vectors = try load()
        XCTAssertEqual(vectors.shaped.count, 10)
        for (index, item) in vectors.shaped.enumerated() {
            XCTAssertEqual(EluNativeMaskText.isMaskShaped(item.value), item.expected, "shape vector \(index)")
        }
    }

    func testWhitespaceIsExactlyTheSharedUnitsNotThePlatformPredicate() throws {
        let vectors = try load()
        XCTAssertEqual(vectors.whitespace.count, 25)
        let actual = (0 ... 0xFFFF).map { UInt16($0) }.filter { EluNativeMaskText.isWhitespace($0) }
        XCTAssertEqual(actual, vectors.whitespace)
        // Platform whitespace differs: NEL and ZWSP are starred, BOM is kept.
        XCTAssertTrue(Character("\u{0085}").isWhitespace)
        XCTAssertEqual(EluNativeMaskText.maskText("a\u{0085}\u{200B}\u{FEFF}b"), "***\u{FEFF}*")
    }

    func testEncoderEmitsEveryVectorExactlyAndRefusesUnmaskedValues() throws {
        let vectors = try load()
        let viewport = try EluNativeViewport(width: 390, height: 844)
        let bounds = try EluNativeRect(x: 0, y: 0, width: 100, height: 30)
        func encode(_ kind: EluNativeMaskedKind) throws -> [String: Any] {
            var encoder = try EluNativeWireframeEncoder()
            let node = EluNativeMaskedNode(identity: UUID(), kind: kind, bounds: bounds, clip: bounds, style: try .init())
            let chunk = try encoder.encode([.init(ordinal: 0, timestamp: 1, viewport: viewport, nodes: [node])])
            XCTAssertEqual(try EluV1StrictCanonicalJSON.parse(chunk.data).canonicalData, chunk.data)
            let events = try XCTUnwrap(JSONSerialization.jsonObject(with: chunk.data) as? [[String: Any]])
            let data = try XCTUnwrap(events[1]["data"] as? [String: Any])
            let root = try XCTUnwrap((data["wireframes"] as? [[String: Any]])?.first)
            return try XCTUnwrap((root["childWireframes"] as? [[String: Any]])?.first)
        }
        for item in vectors.text {
            let leaf = try encode(.maskedText(item.expected))
            XCTAssertEqual((leaf["text"] as? String).map { Array($0.utf16) }, Array(item.expected.utf16))
        }
        for item in vectors.input {
            let leaf = try encode(.input(secure: true, maskedValue: item.expected))
            XCTAssertEqual(leaf["value"] as? String, item.expected)
        }
        var encoder = try EluNativeWireframeEncoder()
        for kind in [EluNativeMaskedKind.maskedText("[masked]"), .maskedText("PRIVATE"), .input(secure: false, maskedValue: "** *"),
                     .input(secure: true, maskedValue: "secret"), .maskedText(String(repeating: "*", count: 4_097))] {
            let node = EluNativeMaskedNode(identity: UUID(), kind: kind, bounds: bounds, clip: bounds, style: try .init())
            XCTAssertThrowsError(try encoder.encode([.init(ordinal: 0, timestamp: 1, viewport: viewport, nodes: [node])])) {
                XCTAssertEqual($0 as? EluNativeEncodingError, .invalidText)
            }
        }
    }

    func testLongTextVisitsOnlyTheCappedPrefix() {
        let long = String(repeating: "x", count: 1_000_000)
        XCTAssertEqual(EluNativeMaskText.maskText(long), String(repeating: "*", count: 4_096))
        XCTAssertEqual(EluNativeMaskText.maskInput(utf16Length: 1_000_000).utf8.count, 4_096)
        XCTAssertEqual(EluNativeMaskText.maskInput(utf16Length: 0), "")
    }

    /// Measurement: a sign-in screen in "mask all text" mode while someone types
    /// 10 characters per second into the email field for 60 seconds. Chunks are
    /// sealed every 10 seconds, as capture does. "Before" is the earlier wire
    /// output, where every masked value was the fixed word `[masked]`.
    func testTypingIntoAMaskedFieldBandwidthPerMinute() throws {
        for fps in [1, 5] {
            var before = try EluNativeWireframeEncoder(), still = try EluNativeWireframeEncoder()
            var typing = try EluNativeWireframeEncoder()
            var raw = [0, 0, 0], sent = [0, 0, 0], full = [0, 0, 0]
            let frames = 60 * fps, perChunk = 10 * fps
            for start in stride(from: 0, to: frames, by: perChunk) {
                let range = start ..< min(start + perChunk, frames)
                // Same byte length as `[masked]`, swapped back to the exact earlier bytes.
                let earlier = String(decoding: try before.encode(range.map { try signInFrame($0, fps: fps, typed: nil) }).data, as: UTF8.self)
                    .replacingOccurrences(of: "\"********\"", with: "\"[masked]\"")
                XCTAssertTrue(earlier.contains("\"value\":\"[masked]\"")); XCTAssertFalse(earlier.contains("*"))
                let stillData = try still.encode(range.map { try signInFrame($0, fps: fps, typed: 0) }).data
                let typingData = try typing.encode(range.map { try signInFrame($0, fps: fps, typed: $0 * 10 / fps) }).data
                let chunks = [Data(earlier.utf8), stillData, typingData]
                for (index, data) in chunks.enumerated() {
                    raw[index] += data.count
                    sent[index] += try EluNativeReplaySealer.gzip(data, maximumBytes: 16_777_216).base64EncodedString().utf8.count
                    let events = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                    full[index] += events.filter { ($0["type"] as? NSNumber)?.intValue == 2 }.count
                }
            }
            print("NATIVE_MASK_BANDWIDTH fps=\(fps) frames=\(frames) fullSnapshots(before,still,typing)=\(full) " +
                  "uncompressedBytesPerMinute(before,still,typing)=\(raw) sentPayloadBytesPerMinute(before,still,typing)=\(sent)")
            // Every captured frame was already a full snapshot; stars add no events.
            XCTAssertEqual(full[0], frames); XCTAssertEqual(full[1], frames); XCTAssertEqual(full[2], frames)
            XCTAssertLessThan(Double(sent[2]), Double(sent[0]) * 1.5)
        }
    }

    private func signInFrame(_ ordinal: Int, fps: Int, typed: Int?) throws -> EluNativeMaskedSnapshot {
        let word = "********"
        func text(_ value: String) -> EluNativeMaskedKind { .maskedText(typed == nil ? word : EluNativeMaskText.maskText(value)) }
        func input(_ length: Int) -> String { typed == nil ? word : EluNativeMaskText.maskInput(utf16Length: length) }
        let kinds: [EluNativeMaskedKind] = [
            .rectangle, text("Sign in"), .rectangle, text("Welcome back. Sign in to continue to your account."),
            text("Email address"), .input(secure: false, maskedValue: input(typed ?? 0)),
            text("Password"), .input(secure: true, maskedValue: input(12)), text("Forgot your password?"),
            .rectangle, text("Sign in"), .rectangle, text("Don't have an account? Create one"), .rectangle,
            text("By continuing you agree to the Terms of Service and Privacy Policy."), text("Version 4.2.1 (1187)"),
        ]
        let nodes = try kinds.enumerated().map { index, kind -> EluNativeMaskedNode in
            let rect = try EluNativeRect(x: 16, y: Double(40 + index * 48), width: 358, height: 40)
            let style = try kind == .rectangle ? EluNativeStyle(backgroundColor: .init(red: 243, green: 244, blue: 246))
                : EluNativeStyle(color: .init(red: 17, green: 24, blue: 39), fontSize: 16, fontFamily: .system)
            return .init(identity: try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))),
                         kind: kind, bounds: rect, clip: rect, style: style)
        }
        return .init(ordinal: Int64(ordinal), timestamp: 1_785_888_060_000 + Int64(ordinal * 1_000 / fps),
                     viewport: try .init(width: 390, height: 844), nodes: nodes)
    }

    private func load() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Conformance/native-mask-vectors.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let whitespace = try XCTUnwrap(root["whitespaceUtf16Units"] as? [String]).map { try XCTUnwrap(UInt16($0, radix: 16)) }
        let text = try XCTUnwrap(root["text"] as? [[String: Any]]).map {
            (input: try XCTUnwrap($0["input"] as? String), expected: try XCTUnwrap($0["expected"] as? String))
        }
        let input = try XCTUnwrap(root["input"] as? [[String: Any]]).map {
            (input: try XCTUnwrap($0["input"] as? String), length: try XCTUnwrap(($0["utf16Length"] as? NSNumber)?.intValue),
             expected: try XCTUnwrap($0["expected"] as? String))
        }
        let shaped = try XCTUnwrap(root["maskShaped"] as? [[String: Any]]).map {
            (value: try XCTUnwrap($0["value"] as? String), expected: try XCTUnwrap($0["expected"] as? Bool))
        }
        return Vectors(maxBytes: try XCTUnwrap((root["maxBytes"] as? NSNumber)?.intValue), whitespace: whitespace,
                       text: text, input: input, shaped: shaped)
    }
}
