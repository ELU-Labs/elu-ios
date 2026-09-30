#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit
import zlib

enum EluSwiftUIReplayFailure: Error, Equatable {
    case invalidDeclaration, missingRegion, duplicateRegion, invalidGeometry, staleGeometry
    case busy, cadence, deadline, incompleteDraw, invalidPixels, pngLimit, pngEncoding
}

/// Local observation only. This registry grants no capture authority and is not
/// installed in the runtime. The future original capture owner must supply its
/// existing authority/physical-admission boundaries around collection and sealing.
@MainActor
final class EluSwiftUIReplayRegistry {
    private final class WeakMarker {
        weak var value: EluSwiftUIReplayMarkerView?
        init(_ value: EluSwiftUIReplayMarkerView) { self.value = value }
    }
    let requiredRegions: Set<String>
    private var validDeclaration: Bool
    private var markers: [WeakMarker] = []
    private var revision: UInt64 = 0
    private var lastAttempt: TimeInterval?
    private var activeLease: EluSwiftUIReplayFrameLease?
    private weak var sourceRoot: EluSwiftUIReplayMarkerView?
    private weak var sourceWindow: UIWindow?
    private var originalSource: EluSwiftUIReplaySourceIdentity?

    init(requiredRegions: Set<String>) {
        let valid = requiredRegions.count <= 64 && requiredRegions.allSatisfy {
            !$0.isEmpty && $0.utf8.prefix(129).count <= 128
        }
        self.requiredRegions = valid ? requiredRegions : []
        validDeclaration = valid
    }
    deinit { activeLease?.revoke() }

    func geometryChanged() {
        activeLease?.revoke()
        if revision == .max { validDeclaration = false } else { revision += 1 }
    }
    func rootBindingChanged(_ marker: EluSwiftUIReplayMarkerView) {
        if marker === sourceRoot {
            originalSource = nil; sourceRoot = nil; sourceWindow = nil
        }
    }
    func add(_ marker: EluSwiftUIReplayMarkerView) {
        markers.removeAll { $0.value == nil }
        guard !markers.contains(where: { $0.value === marker }) else { return }
        // A duplicate/unknown registration is never silently omitted. Overflow
        // permanently closes this scope instead of retaining an unbounded list.
        guard markers.count < 130, marker.region.map({ !$0.isEmpty && $0.utf8.prefix(129).count <= 128 }) ?? true else {
            validDeclaration = false; geometryChanged(); return
        }
        markers.append(WeakMarker(marker)); geometryChanged()
    }
    func remove(_ marker: EluSwiftUIReplayMarkerView) {
        rootBindingChanged(marker)
        markers.removeAll { $0.value == nil || $0.value === marker }
        geometryChanged()
    }

    struct Ancestor {
        weak var view: UIView?
        weak var parent: UIView?
        let bounds: CGRect
        let center: CGPoint
        let clips: Bool
    }
    struct Witness {
        weak var marker: EluSwiftUIReplayMarkerView?
        let rect: CGRect
        let ancestors: [Ancestor]
    }
    struct Plan {
        weak var window: UIWindow?
        let viewport: CGRect
        let masks: [CGRect]
        let witnesses: [Witness]
        let revision: UInt64
    }

    /// No text, input values, accessibility or private view types are inspected.
    /// This is the declared-region contract, not automatic masking coverage.
    func plan(check: () throws -> Void = {}) throws -> Plan {
        try check()
        guard validDeclaration else { throw EluSwiftUIReplayFailure.invalidDeclaration }
        let originalRevision = revision
        let live = markers.compactMap(\.value)
        guard live.allSatisfy({ $0.region == nil || requiredRegions.contains($0.region!) }) else {
            throw EluSwiftUIReplayFailure.invalidDeclaration
        }
        var witnesses: [Witness] = []
        var originalWindow: UIWindow?
        var totalAncestors = 0
        let roles: [String?] = [nil] + requiredRegions.sorted().map { Optional($0) }
        for role in roles {
            try check()
            let matches = live.filter { $0.region == role }
            guard !matches.isEmpty else { throw EluSwiftUIReplayFailure.missingRegion }
            guard matches.count == 1 else { throw EluSwiftUIReplayFailure.duplicateRegion }
            let marker = matches[0]
            guard let window = marker.window, window.isKeyWindow, !window.isHidden,
                  window.alpha == 1, window.windowLevel == .normal,
                  UIApplication.shared.applicationState == .active,
                  window.windowScene.map({ $0.activationState == .foregroundActive }) ?? true,
                  marker.superview != nil, Self.valid(marker.bounds) else {
                throw EluSwiftUIReplayFailure.invalidGeometry
            }
            if let originalWindow, originalWindow !== window { throw EluSwiftUIReplayFailure.invalidGeometry }
            originalWindow = window
            var ancestors: [Ancestor] = []
            var cursor: UIView? = marker
            while let view = cursor {
                try check(); totalAncestors += 1
                guard totalAncestors <= 2048, ancestors.count < 64,
                      !view.isHidden, view.alpha == 1, view.transform == .identity,
                      CATransform3DIsIdentity(view.layer.transform), CATransform3DIsIdentity(view.layer.sublayerTransform),
                      view.layer.mask == nil, view.layer.shadowOpacity == 0,
                      view.layer.animationKeys()?.isEmpty ?? true,
                      view.layer.filters?.isEmpty ?? true,
                      view.layer.backgroundFilters?.isEmpty ?? true,
                      Self.valid(view.bounds) else { throw EluSwiftUIReplayFailure.invalidGeometry }
                ancestors.append(Ancestor(view: view, parent: view.superview, bounds: view.bounds,
                    center: view.center, clips: view.clipsToBounds))
                if view === window { break }
                cursor = view.superview
            }
            guard ancestors.last?.view === window else { throw EluSwiftUIReplayFailure.invalidGeometry }
            let rect = marker.convert(marker.bounds, to: window)
            guard Self.valid(rect) else { throw EluSwiftUIReplayFailure.invalidGeometry }
            witnesses.append(Witness(marker: marker, rect: rect, ancestors: ancestors))
        }
        guard let window = originalWindow, let viewport = witnesses.first?.rect,
              window.bounds.contains(viewport), viewport.width >= 1, viewport.height >= 1,
              viewport.width <= 2048, viewport.height <= 2048,
              floor(viewport.width) * floor(viewport.height) <= 1_048_576 else {
            throw EluSwiftUIReplayFailure.invalidGeometry
        }
        let masks = witnesses.dropFirst().compactMap { witness -> CGRect? in
            // Each public wrapper clips its own paint. A registered wrapper may
            // be fully outside the original root; its intent must still exist.
            let clipped = witness.rect.intersection(viewport)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            let x = max(0, floor(clipped.minX - viewport.minX))
            let y = max(0, floor(clipped.minY - viewport.minY))
            let mask = CGRect(x: x, y: y,
                width: min(floor(viewport.width), ceil(clipped.maxX - viewport.minX)) - x,
                height: min(floor(viewport.height), ceil(clipped.maxY - viewport.minY)) - y)
            return mask.width > 0 && mask.height > 0 ? mask : nil
        }
        try check()
        guard revision == originalRevision else { throw EluSwiftUIReplayFailure.staleGeometry }
        return Plan(window: window, viewport: viewport, masks: masks, witnesses: witnesses, revision: revision)
    }

    func validate(_ original: Plan, check: () throws -> Void = {}) throws {
        guard original.revision == revision else { throw EluSwiftUIReplayFailure.staleGeometry }
        let current = try plan(check: check)
        guard original.window != nil, current.window === original.window,
              current.viewport == original.viewport, current.masks == original.masks,
              current.witnesses.count == original.witnesses.count else { throw EluSwiftUIReplayFailure.staleGeometry }
        for (old, new) in zip(original.witnesses, current.witnesses) {
            guard old.marker != nil, old.marker === new.marker, old.rect == new.rect,
                  old.ancestors.count == new.ancestors.count else { throw EluSwiftUIReplayFailure.staleGeometry }
            for (a, b) in zip(old.ancestors, new.ancestors) {
                guard a.view != nil, a.view === b.view, a.parent === b.parent,
                      a.bounds == b.bounds, a.center == b.center, a.clips == b.clips else {
                    throw EluSwiftUIReplayFailure.staleGeometry
                }
            }
        }
    }

    /// Only the collector can create this detached source identity. It refers
    /// to one registry's original root/window, not a caller-selected label or a
    /// privacy grant. Current source permission remains an independent check.
    func sourceIdentity() throws -> EluSwiftUIReplaySourceIdentity {
        try sourceIdentity(for: plan())
    }
    private func sourceIdentity(for plan: Plan) throws -> EluSwiftUIReplaySourceIdentity {
        guard let root = plan.witnesses.first?.marker, let window = plan.window else {
            throw EluSwiftUIReplayFailure.staleGeometry
        }
        if let originalSource, sourceRoot === root, sourceWindow === window { return originalSource }
        let identity = EluSwiftUIReplaySourceIdentity()
        sourceRoot = root; sourceWindow = window; originalSource = identity
        return identity
    }

    /// The injected draw is an internal deterministic fault seam. Production's
    /// default invokes the original mounted window once, synchronously. Neither
    /// this seam nor a returned frame is public authority or a queue admission.
    func capture(deadline: TimeInterval, clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                 draw: ((UIWindow, CGRect, CGContext) -> Bool)? = nil,
                 onDiscard: ((Int, Bool) -> Void)? = nil) throws -> EluSwiftUIReplayFrame {
        let start = clock()
        guard start.isFinite, deadline.isFinite, deadline > start else { throw EluSwiftUIReplayFailure.deadline }
        guard activeLease?.isClosed ?? true else { throw EluSwiftUIReplayFailure.busy }
        if let previous = lastAttempt {
            guard start >= previous, start - previous >= 1 else { throw EluSwiftUIReplayFailure.cadence }
        }
        lastAttempt = start
        let limit = min(deadline, start + 0.050)
        var observed = start
        func check() throws {
            let now = clock()
            guard now.isFinite, now >= observed, now <= limit else { throw EluSwiftUIReplayFailure.deadline }
            observed = now
        }
        let lease = EluSwiftUIReplayFrameLease(); activeLease = lease
        var accepted = false
        defer { if !accepted { lease.finish() } }
        let original = try plan(check: check)
        let source = try sourceIdentity(for: original)
        guard let window = original.window else { throw EluSwiftUIReplayFailure.invalidGeometry }
        // Retain only whole pixels inside the root. Rounding its outer extent
        // upward could sample a neighboring window region outside this scope.
        let width = Int(floor(original.viewport.width)), height = Int(floor(original.viewport.height))
        var allowed = [CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))]
        for mask in original.masks {
            allowed = allowed.flatMap { Self.subtract(mask, from: $0) }
            guard allowed.count <= 256 else { throw EluSwiftUIReplayFailure.invalidGeometry }
        }
        // No CGImage or platform PNG exists. Rejection erases this exact owned
        // allocation before release. Renderer-owned internal buffers are outside
        // this retained-output contract.
        let storage = EluSwiftUIReplayPixels(width: width, height: height)
        defer {
            if !accepted {
                storage.clear()
                // Internal test observation contains only bounded scalar facts,
                // never pixels. Inspect while the original allocation is alive.
                if let onDiscard { onDiscard(storage.count, storage.isZero) }
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: storage.pointer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw EluSwiftUIReplayFailure.invalidPixels
        }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        if allowed.isEmpty { context.clip(to: .zero) } else { context.clip(to: allowed) }
        try check(); try validate(original, check: check)
        let rect = CGRect(x: -original.viewport.minX, y: -original.viewport.minY,
            width: window.bounds.width, height: window.bounds.height)
        let complete: Bool
        if let draw { complete = draw(window, rect, context) }
        else {
            UIGraphicsPushContext(context)
            // The mask plan describes current geometry. A stale composited
            // snapshot could still contain private paint at a previous location.
            // Incorporate pending updates, then revalidate the original plan.
            complete = window.drawHierarchy(in: rect, afterScreenUpdates: true)
            UIGraphicsPopContext()
        }
        guard complete else { throw EluSwiftUIReplayFailure.incompleteDraw }
        try check(); try validate(original, check: check)
        // Always overwrite the validated union; pre-draw clipping is a defense,
        // never a substitute for the post-draw lifetime/geometry proof.
        for mask in original.masks {
            for y in Int(mask.minY)..<Int(mask.maxY) {
                try check()
                for x in Int(mask.minX)..<Int(mask.maxX) { storage.fill(x: x, y: y) }
            }
        }
        guard storage.isOpaque else { throw EluSwiftUIReplayFailure.invalidPixels }
        try check(); try validate(original, check: check)
        guard lease.isCurrent else { throw EluSwiftUIReplayFailure.staleGeometry }
        let frame = EluSwiftUIReplayFrame(storage: storage, lease: lease, sourceIdentity: source)
        accepted = true
        return frame
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
    private static func subtract(_ cut: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(cut)
        if overlap.isNull || overlap.isEmpty { return [rect] }
        return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
            CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
            CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
            CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)]
            .filter { $0.width > 0 && $0.height > 0 }
    }
}

@MainActor
final class EluSwiftUIReplayMarkerView: UIView {
    private(set) var region: String?
    private weak var registry: EluSwiftUIReplayRegistry?
    init(region: String?, registry: EluSwiftUIReplayRegistry) {
        self.region = region; self.registry = registry
        super.init(frame: .zero)
        isUserInteractionEnabled = false; isAccessibilityElement = false; backgroundColor = .clear
    }
    required init?(coder: NSCoder) { nil }
    func bind(region: String?, registry: EluSwiftUIReplayRegistry) {
        if self.region != region || self.registry !== registry {
            self.registry?.remove(self); self.region = region; self.registry = registry
            registry.geometryChanged()
        }
        if window != nil { registry.add(self) }
    }
    func unbind() { registry?.remove(self); registry = nil }
    override var frame: CGRect { didSet { if oldValue != frame { registry?.geometryChanged() } } }
    override var bounds: CGRect { didSet { if oldValue != bounds { registry?.geometryChanged() } } }
    override var center: CGPoint { didSet { if oldValue != center { registry?.geometryChanged() } } }
    override var transform: CGAffineTransform { didSet { if oldValue != transform { registry?.geometryChanged() } } }
    override var alpha: CGFloat { didSet { if oldValue != alpha { registry?.geometryChanged() } } }
    override var isHidden: Bool { didSet { if oldValue != isHidden { registry?.geometryChanged() } } }
    override func didMoveToSuperview() {
        super.didMoveToSuperview(); registry?.rootBindingChanged(self); registry?.geometryChanged()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        registry?.rootBindingChanged(self)
        if window == nil { registry?.remove(self) } else { registry?.add(self) }
    }
}

/// Opaque collector-owned identity, with no UIKit references or caller minting.
/// Object identity deliberately distinguishes otherwise identical live roots.
final class EluSwiftUIReplaySourceIdentity: Sendable {
    fileprivate init() {}
}

/// Detached revocation/slot state only; no UIKit reference crosses MainActor.
private final class EluSwiftUIReplayFrameLease: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    private var closed = false
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return current && !closed }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    func revoke() { lock.lock(); current = false; lock.unlock() }
    func finish() { lock.lock(); current = false; closed = true; lock.unlock() }
}

private final class EluSwiftUIReplayPixels {
    let width: Int, height: Int, count: Int
    let pointer: UnsafeMutableRawPointer
    init(width: Int, height: Int) {
        self.width = width; self.height = height; count = width * height * 4
        pointer = .allocate(byteCount: count, alignment: 16)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        for y in 0..<height { for x in 0..<width { fill(x: x, y: y) } }
    }
    func fill(x: Int, y: Int) {
        let bytes = pointer.assumingMemoryBound(to: UInt8.self), index = (y * width + x) * 4
        bytes[index] = 73; bytes[index + 1] = 83; bytes[index + 2] = 93; bytes[index + 3] = 255
    }
    var isOpaque: Bool {
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        return stride(from: 3, to: count, by: 4).allSatisfy { bytes[$0] == 255 }
    }
    var isZero: Bool {
        UnsafeRawBufferPointer(start: pointer, count: count).allSatisfy { $0 == 0 }
    }
    func clear() { pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count) }
    deinit { clear(); pointer.deallocate() }
}

/// The only candidate form is SDK-owned, opaque, validated pixels. No public
/// initializer, UIImage, bitmap submission, raw diagnostics or file writer exists.
final class EluSwiftUIReplayFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: EluSwiftUIReplayPixels?
    private let lease: EluSwiftUIReplayFrameLease
    let sourceIdentity: EluSwiftUIReplaySourceIdentity
    let width: Int, height: Int
    fileprivate init(storage: EluSwiftUIReplayPixels, lease: EluSwiftUIReplayFrameLease,
                     sourceIdentity: EluSwiftUIReplaySourceIdentity) {
        self.storage = storage; self.lease = lease; width = storage.width; height = storage.height
        self.sourceIdentity = sourceIdentity
    }
    /// One-shot encoding; all owned raw pixels are cleared even on compression,
    /// output-limit or revocation failure. Future admission remains independent.
    func encodePNG() throws -> Data {
        lock.lock(); defer { clearLocked(); lock.unlock() }
        guard let storage, lease.isCurrent else { throw EluSwiftUIReplayFailure.staleGeometry }
        var output = try EluSwiftUIReplayPNG.encode(width: width, height: height,
            rgba: UnsafeRawBufferPointer(start: storage.pointer, count: storage.count))
        guard lease.isCurrent else {
            output.resetBytes(in: 0..<output.count)
            throw EluSwiftUIReplayFailure.staleGeometry
        }
        return output
    }
    func close() { lock.lock(); clearLocked(); lock.unlock() }
    private func clearLocked() { storage?.clear(); storage = nil; lease.finish() }
    deinit { storage?.clear(); lease.finish() }
}

/// Construct the closed PNG grammar directly; platform pngData metadata is never
/// copied. Filter 0, opaque RGBA8, exactly one zlib extent, four chunks including
/// fixed sRGB intent 0. The encoder accepts only internal owned pixel storage.
enum EluSwiftUIReplayPNG {
    static let maximumBytes = 2 * 1024 * 1024
    static func encode(width: Int, height: Int, rgba: UnsafeRawBufferPointer) throws -> Data {
        guard (1...2048).contains(width), (1...2048).contains(height), width * height <= 1_048_576,
              rgba.count == width * height * 4,
              stride(from: 3, to: rgba.count, by: 4).allSatisfy({ rgba[$0] == 255 }) else {
            throw EluSwiftUIReplayFailure.invalidPixels
        }
        let rowBytes = width * 4
        var scanlines = [UInt8](repeating: 0, count: (rowBytes + 1) * height)
        defer { _ = scanlines.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        for y in 0..<height {
            scanlines.withUnsafeMutableBytes { destination in
                destination.baseAddress!.advanced(by: y * (rowBytes + 1) + 1)
                    .copyMemory(from: rgba.baseAddress!.advanced(by: y * rowBytes), byteCount: rowBytes)
            }
        }
        // Fixed output storage, including PNG overhead; incompressible images
        // fail without allocating an unbounded compressBound-sized destination.
        var compressed = [UInt8](repeating: 0, count: maximumBytes - 70)
        defer { _ = compressed.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var count = uLongf(compressed.count)
        let result = compressed.withUnsafeMutableBufferPointer { output in
            scanlines.withUnsafeBufferPointer { input in
                compress2(output.baseAddress, &count, input.baseAddress, uLong(input.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard result == Z_OK, count > 0, count <= uLongf(compressed.count) else {
            throw result == Z_BUF_ERROR ? EluSwiftUIReplayFailure.pngLimit : EluSwiftUIReplayFailure.pngEncoding
        }
        var output = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var header = integer(UInt32(width)) + integer(UInt32(height))
        header += [8, 6, 0, 0, 0]
        append("IHDR", bytes: header, to: &output)
        append("sRGB", bytes: [0], to: &output)
        compressed.withUnsafeBytes { append("IDAT", bytes: $0.prefix(Int(count)), to: &output) }
        append("IEND", bytes: [UInt8](), to: &output)
        guard output.count <= maximumBytes else { throw EluSwiftUIReplayFailure.pngLimit }
        return output
    }
    private static func integer(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
    private static func append<C: Collection>(_ kind: String, bytes: C, to output: inout Data) where C.Element == UInt8 {
        let start = output.count
        output.append(contentsOf: integer(UInt32(bytes.count)))
        output.append(contentsOf: kind.utf8); output.append(contentsOf: bytes)
        let checksum = output.withUnsafeBytes { raw in
            crc32(0, raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: start + 4), uInt(4 + bytes.count))
        }
        output.append(contentsOf: integer(UInt32(checksum)))
    }
}
#endif
