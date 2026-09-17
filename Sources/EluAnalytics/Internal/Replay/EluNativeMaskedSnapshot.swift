import Foundation

/// Internal masked values only. This is neither a UIKit collector nor proof of
/// source/privacy permission. There is deliberately no text, URL or image input.
enum EluNativeEncodingError: Error, Equatable, Sendable {
    case invalidGeometry
    case invalidViewport
    case invalidTimestamp
    case frameOrder
    case duplicateIdentity
    case retiredIdentity
    case nodeLimit
    case representationLimit
    case eventLimit
    case byteLimit
    case counterExhausted
    case invalidLimits
}

struct EluNativeRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) throws {
        guard [x, y, width, height].allSatisfy(\.isFinite),
              abs(x) <= 1_000_000, abs(y) <= 1_000_000,
              (0 ... 1_000_000).contains(width), (0 ... 1_000_000).contains(height),
              (x + width).isFinite, (y + height).isFinite
        else { throw EluNativeEncodingError.invalidGeometry }
        self.x = x == 0 ? 0 : x; self.y = y == 0 ? 0 : y
        self.width = width; self.height = height
    }
}

struct EluNativeViewport: Equatable, Sendable {
    let width: Int
    let height: Int

    init(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite,
              (1 ... 16_384).contains(width), (1 ... 16_384).contains(height),
              width.rounded(.towardZero) == width, height.rounded(.towardZero) == height
        else { throw EluNativeEncodingError.invalidViewport }
        self.width = Int(width); self.height = Int(height)
    }
}

/// Components, not CSS strings. Pattern images and dynamic providers never cross
/// this value boundary. UIKit color extraction is a separately reviewed collector.
struct EluNativeSolidColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    var wireValue: String {
        let rgb = String(format: "#%02x%02x%02x", red, green, blue)
        return alpha == 255 ? rgb : rgb + String(format: "%02x", alpha)
    }
}

enum EluNativeFont: String, Equatable, Sendable {
    case sansSerif = "sans-serif"
    case serif
    case monospace
    case system = "system-ui"
}

struct EluNativeStyle: Equatable, Sendable {
    let color: EluNativeSolidColor?
    let backgroundColor: EluNativeSolidColor?
    let fontSize: Double?
    let fontFamily: EluNativeFont?

    init(color: EluNativeSolidColor? = nil, backgroundColor: EluNativeSolidColor? = nil,
         fontSize: Double? = nil, fontFamily: EluNativeFont? = nil) throws {
        guard fontSize.map({ $0.isFinite && (1 ... 256).contains($0) }) ?? true
        else { throw EluNativeEncodingError.invalidGeometry }
        self.color = color; self.backgroundColor = backgroundColor
        self.fontSize = fontSize; self.fontFamily = fontFamily
    }
}

enum EluNativeMaskedKind: Equatable, Sendable {
    case rectangle
    case text
    case input(secure: Bool)
    case placeholder
}

struct EluNativeMaskedNode: Equatable, Sendable {
    /// Local projection identity, never serialized. A retired projection identity
    /// cannot return; a reappearing view needs a newly allocated local identity.
    let identity: UUID
    let kind: EluNativeMaskedKind
    let bounds: EluNativeRect
    let clip: EluNativeRect
    let style: EluNativeStyle

    init(identity: UUID, kind: EluNativeMaskedKind, bounds: EluNativeRect,
         clip: EluNativeRect, style: EluNativeStyle) {
        self.identity = identity; self.kind = kind; self.bounds = bounds
        self.clip = clip; self.style = style
    }
}

struct EluNativeMaskedSnapshot: Equatable, Sendable {
    /// Encoder-local ordinal, absent from the wire. Starts at zero, no gaps.
    let ordinal: Int64
    /// Original integer Unix milliseconds; never replaced by encoding time.
    let timestamp: Int64
    let viewport: EluNativeViewport
    /// Flat native paint order. Clipping/privacy ancestry was resolved before
    /// constructing these immutable values; no view references are retained.
    let nodes: [EluNativeMaskedNode]
}

struct EluNativeEncodedChunk: Equatable, Sendable {
    let sequence: Int64
    let firstTimestamp: Int64
    let lastTimestamp: Int64
    let eventCount: Int
    let nodeRepresentations: Int
    /// Canonical uncompressed inner event array, not a prepared HTTP request.
    let data: Data
}
