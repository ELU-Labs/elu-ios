import Foundation

/// Pure candidate codec. This does not advertise v2 or install an observer. The
/// capture owner must commit the initial snapshot before arming touch collection.
struct EluNativeWireframeV2Encoder: Sendable {
    static let codec = "elu-native-wireframe-v2"
    struct State: Equatable, Sendable {
        var geometry: EluNativeWireframeEncoder.State
        var activeIdentity: UUID?
        var lastMove: EluNativeInteractionTime?
        var lastGeometry: EluNativeInteractionTime?
        var lastContinuous: UInt64?
    }

    private let geometryEncoder: EluNativeWireframeEncoder
    let profile: EluNativeMaskingProfile
    private(set) var state: State
    var rootID: Int64 { geometryEncoder.rootID }
    var limits: EluNativeWireframeEncoder.Limits { geometryEncoder.limits }

    init(profile: EluNativeMaskingProfile,
         limits: EluNativeWireframeEncoder.Limits = try! .init(),
         firstNodeID: Int64 = EluNativeWireframeEncoder.minimumNodeID) throws {
        geometryEncoder = try .init(limits: limits, firstNodeID: firstNodeID)
        self.profile = profile
        state = State(geometry: geometryEncoder.state)
    }

    /// Both geometry and interaction state are speculative until every record,
    /// logical unit and byte passes. A failed candidate consumes no IDs or times.
    mutating func encode(_ records: [EluNativeReplayRecord]) throws -> EluNativeEncodedChunk {
        guard !records.isEmpty, records.count <= limits.events else { throw EluNativeEncodingError.eventLimit }
        guard state.geometry.nextSequence < EluNativeWireframeEncoder.maximumSafeInteger else {
            throw EluNativeEncodingError.counterExhausted
        }
        var next = state
        var output = Data([0x5b]), eventCount = 0, logicalCount = 0, representations = 0
        var firstTimestamp: Int64?
        for record in records {
            if case let .interaction(.moves(points)) = record, !(1 ... 10).contains(points.count) {
                throw EluNativeInteractionError.invalidBatch
            }
            let times = record.times
            guard let first = times.first, let last = times.last else { throw EluNativeInteractionError.invalidBatch }
            try validateTimes(times, state: next)
            if firstTimestamp == nil { firstTimestamp = first.timestamp }
            switch record {
            case let .geometry(frame, continuous):
                if let old = next.lastGeometry {
                    guard frame.timestamp >= old.timestamp, frame.timestamp - old.timestamp >= 200,
                          continuous >= old.continuous, continuous - old.continuous >= 200_000_000 else {
                        throw EluNativeInteractionError.invalidOrder
                    }
                }
                if !profile.allowsOrdinaryText {
                    for node in frame.nodes {
                        if case let .ordinaryText(text) = node.kind, text != EluNativeWireframeEncoder.mask {
                            throw EluNativeInteractionError.privateTarget
                        }
                    }
                }
                let before = eventCount
                try geometryEncoder.appendGeometry(frame, state: &next.geometry, output: &output,
                    eventCount: &eventCount, representations: &representations, v2: true)
                logicalCount += eventCount - before
                next.lastGeometry = .init(timestamp: frame.timestamp, continuous: continuous)
                if let active = next.activeIdentity {
                    guard let node = next.geometry.live.first(where: { $0.value.identity == active }),
                          lawful(node.value) else { throw EluNativeInteractionError.privateTarget }
                }
            case let .interaction(interaction):
                // A geometry record earlier in this same candidate is insufficient:
                // initial producer arming must follow a committed initial chunk.
                guard state.geometry.viewport != nil else { throw EluNativeInteractionError.initialCommitRequired }
                guard profile.allowsOrdinaryText else { throw EluNativeInteractionError.privateTarget }
                logicalCount += interaction.logicalCost
                guard logicalCount <= limits.events, eventCount < limits.events else { throw EluNativeEncodingError.eventLimit }
                let bytes = try encodeInteraction(interaction, state: &next)
                if eventCount > 0 { try append(Data([0x2c]), to: &output) }
                try append(bytes, to: &output)
                eventCount += 1
                next.geometry.lastTimestamp = last.timestamp
            }
            guard logicalCount <= limits.events else { throw EluNativeEncodingError.eventLimit }
            next.lastContinuous = last.continuous
        }
        guard output.count < limits.decodedBytes, let firstTimestamp, let lastTimestamp = next.geometry.lastTimestamp else {
            throw EluNativeEncodingError.byteLimit
        }
        output.append(0x5d)
        let chunk = EluNativeEncodedChunk(sequence: next.geometry.nextSequence,
            firstTimestamp: firstTimestamp, lastTimestamp: lastTimestamp,
            // Descriptive outer-record count; the separate enforced logical
            // ceiling charges source6 by its position count, without an extra unit.
            eventCount: eventCount, nodeRepresentations: representations, data: output)
        next.geometry.nextSequence += 1
        state = next
        return chunk
    }

    private func validateTimes(_ times: [EluNativeInteractionTime], state: State) throws {
        var wall = state.geometry.lastTimestamp
        var continuous = state.lastContinuous
        for time in times {
            guard (1 ... EluNativeWireframeEncoder.maximumSafeInteger).contains(time.timestamp),
                  wall.map({ time.timestamp >= $0 }) ?? true,
                  continuous.map({ time.continuous >= $0 }) ?? true else {
                throw EluNativeInteractionError.invalidOrder
            }
            wall = time.timestamp; continuous = time.continuous
        }
    }

    private func lawful(_ node: EluNativeMaskedNode) -> Bool {
        guard node.clip.width > 0, node.clip.height > 0 else { return false }
        switch node.kind {
        case .rectangle: return true
        case let .ordinaryText(text): return text != EluNativeWireframeEncoder.mask
        case .text, .input, .placeholder: return false
        }
    }

    private func pointID(_ point: EluNativeInteractionPoint, state: State) throws -> Int64 {
        guard point.geometryOrdinal == state.geometry.nextFrameOrdinal - 1 else {
            throw EluNativeInteractionError.staleGeometry
        }
        guard let viewport = state.geometry.viewport,
              let node = state.geometry.live.first(where: { $0.value.identity == point.identity }),
              lawful(node.value) else { throw EluNativeInteractionError.privateTarget }
        let clip = node.value.clip
        guard point.x >= 0, point.y >= 0, point.x < Int64(viewport.width), point.y < Int64(viewport.height),
              Double(point.x) >= clip.x, Double(point.y) >= clip.y,
              Double(point.x) < clip.x + clip.width, Double(point.y) < clip.y + clip.height else {
            throw EluNativeInteractionError.invalidPoint
        }
        return node.id
    }

    private typealias JSON = EluV1StrictCanonicalJSON.Value
    private func member(_ name: String, _ value: JSON) -> EluV1StrictCanonicalJSON.Member {
        .init(name: Array(name.utf16), value: value)
    }
    private func integer(_ value: Int64) -> JSON { .number(String(value)) }

    private func encodeInteraction(_ interaction: EluNativeInteraction, state: inout State) throws -> Data {
        var fields: [EluV1StrictCanonicalJSON.Member]
        let timestamp: Int64
        switch interaction {
        case let .start(point), let .end(point):
            let beginning: Bool
            if case .start = interaction { beginning = true } else { beginning = false }
            guard beginning ? state.activeIdentity == nil : state.activeIdentity != nil else {
                throw EluNativeInteractionError.invalidGesture
            }
            let id = try pointID(point, state: state)
            state.activeIdentity = beginning ? point.identity : nil
            timestamp = point.time.timestamp
            fields = [member("source", integer(2)), member("type", integer(beginning ? 7 : 9)),
                      member("id", integer(id)), member("x", integer(point.x)), member("y", integer(point.y)),
                      member("pointerType", integer(2))]
        case let .cancel(time):
            guard state.activeIdentity != nil else { throw EluNativeInteractionError.invalidGesture }
            state.activeIdentity = nil; timestamp = time.timestamp
            fields = [member("source", integer(2)), member("type", integer(10)),
                      member("id", integer(rootID)), member("pointerType", integer(2))]
        case let .moves(points):
            guard (1 ... 10).contains(points.count), let last = points.last else {
                throw EluNativeInteractionError.invalidBatch
            }
            guard state.activeIdentity != nil else { throw EluNativeInteractionError.invalidGesture }
            timestamp = last.time.timestamp
            var positions: [JSON] = []
            var previous: Int64?
            for point in points {
                let offset = point.time.timestamp - timestamp
                guard (-900 ... 0).contains(offset), previous.map({ offset > $0 }) ?? true else {
                    throw EluNativeInteractionError.invalidBatch
                }
                if let old = state.lastMove {
                    guard point.time.timestamp >= old.timestamp,
                          point.time.timestamp - old.timestamp >= 100,
                          point.time.continuous >= old.continuous,
                          point.time.continuous - old.continuous >= 100_000_000 else {
                        throw EluNativeInteractionError.moveRate
                    }
                }
                let id = try pointID(point, state: state)
                positions.append(.object([member("id", integer(id)), member("x", integer(point.x)),
                    member("y", integer(point.y)), member("timeOffset", integer(offset))]))
                state.lastMove = point.time; state.activeIdentity = point.identity; previous = offset
            }
            fields = [member("source", integer(6)), member("positions", .array(positions))]
        }
        return try EluV1StrictCanonicalJSON.canonicalData(for: .object([
            member("type", integer(3)), member("timestamp", integer(timestamp)), member("data", .object(fields))]))
    }

    private func append(_ bytes: Data, to output: inout Data) throws {
        guard bytes.count < limits.decodedBytes - output.count else { throw EluNativeEncodingError.byteLimit }
        output.append(bytes)
    }
}
