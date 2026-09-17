import Foundation

/// Bounded candidate codec, deliberately unregistered. One value belongs to one
/// logical replay; callers serialize access and never reset it under that replay.
struct EluNativeWireframeEncoder: Sendable {
    static let minimumNodeID: Int64 = 10_000_000
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    static let mask = "[masked]"
    static let placeholder = "Content hidden"

    struct Limits: Equatable, Sendable {
        let liveNodes: Int
        let lifetimeIDs: Int
        let representations: Int
        let events: Int
        let decodedBytes: Int
        init(liveNodes: Int = 10_000, lifetimeIDs: Int = 100_000,
             representations: Int = 100_000, events: Int = 10_000,
             decodedBytes: Int = 16_777_216) throws {
            guard (1 ... 10_000).contains(liveNodes),
                  (1 ... 100_000).contains(lifetimeIDs), liveNodes <= lifetimeIDs,
                  (1 ... 100_000).contains(representations),
                  (1 ... 10_000).contains(events), (2 ... 16_777_216).contains(decodedBytes)
            else { throw EluNativeEncodingError.invalidLimits }
            self.liveNodes = liveNodes; self.lifetimeIDs = lifetimeIDs
            self.representations = representations; self.events = events; self.decodedBytes = decodedBytes
        }
    }

    struct LiveNode: Equatable, Sendable {
        let id: Int64
        let value: EluNativeMaskedNode
    }
    struct State: Equatable, Sendable {
        var nextSequence: Int64 = 0
        var nextFrameOrdinal: Int64 = 0
        var lastTimestamp: Int64?
        var viewport: EluNativeViewport?
        var live: [LiveNode] = []
        var retired: Set<UUID> = []
        var allocatedIDs = 1 // The root also consumes the lifetime budget.
        var nextNodeID: Int64?
        var rendererBudget = 0
    }

    let limits: Limits
    let rootID: Int64
    private(set) var state: State

    init(limits: Limits = try! Limits(), firstNodeID: Int64 = minimumNodeID) throws {
        guard (Self.minimumNodeID ... Self.maximumSafeInteger).contains(firstNodeID)
        else { throw EluNativeEncodingError.counterExhausted }
        self.limits = limits; rootID = firstNodeID
        state = State(nextNodeID: firstNodeID == Self.maximumSafeInteger ? nil : firstNodeID + 1)
    }

    /// All candidate state and bytes remain local until the entire chunk passes.
    /// No asynchronous work or global clocks are consulted by this operation.
    mutating func encode(_ snapshots: [EluNativeMaskedSnapshot]) throws -> EluNativeEncodedChunk {
        guard !snapshots.isEmpty, snapshots.count <= limits.events else { throw EluNativeEncodingError.eventLimit }
        guard state.nextSequence < Self.maximumSafeInteger else { throw EluNativeEncodingError.counterExhausted }
        var next = state
        var output = Data([0x5b]), eventCount = 0, representations = 0
        for frame in snapshots {
            try validate(frame, previous: next)
            let previous = Dictionary(uniqueKeysWithValues: next.live.map { ($0.value.identity, $0) })
            let identities = Set(frame.nodes.map(\.identity))
            next.retired.formUnion(next.live.lazy.filter { !identities.contains($0.value.identity) }.map { $0.value.identity })
            var current: [LiveNode] = []
            current.reserveCapacity(frame.nodes.count)
            for node in frame.nodes {
                if let old = previous[node.identity] { current.append(LiveNode(id: old.id, value: node)) }
                else {
                    guard !next.retired.contains(node.identity) else { throw EluNativeEncodingError.retiredIdentity }
                    guard next.allocatedIDs < limits.lifetimeIDs else { throw EluNativeEncodingError.nodeLimit }
                    guard let id = next.nextNodeID else { throw EluNativeEncodingError.counterExhausted }
                    next.nextNodeID = id == Self.maximumSafeInteger ? nil : id + 1
                    next.allocatedIDs += 1
                    current.append(LiveNode(id: id, value: node))
                }
            }
            let survivors = next.live.filter { identities.contains($0.value.identity) }
            let added = current.filter { previous[$0.value.identity] == nil }
            // The inherited renderer appends replacements. A full snapshot is
            // required for changes/reordering so earlier leaves cannot jump above
            // later ones. Only removals and suffix additions use mutations.
            let currentByIdentity = Dictionary(uniqueKeysWithValues: current.map { ($0.value.identity, $0) })
            let unchangedSurvivors = survivors.allSatisfy { old in
                currentByIdentity[old.value.identity] == old
            }
            let suffixOrder = current.map(\.id) == survivors.map(\.id) + added.map(\.id)
            let noChange = current == next.live
            let first = next.viewport == nil
            let mutationCost = added.reduce(0) { $0 + generatedNodeCost($1.value.kind) }
            let full = first || !unchangedSurvivors || !suffixOrder || noChange
                || next.rendererBudget + mutationCost > 1_000_000
            let count = full ? current.count + 1 : added.count
            guard count <= limits.representations - representations else { throw EluNativeEncodingError.representationLimit }
            representations += count
            if first {
                try appendEvent(meta(frame), to: &output, count: &eventCount)
            }
            if full {
                try appendFull(frame, nodes: current, to: &output, count: &eventCount)
                // Actual converter: two CSS nodes per full snapshot, one child
                // for text/labelled placeholder, zero for our other leaf forms.
                next.rendererBudget = 2 + current.reduce(0) { $0 + generatedNodeCost($1.value.kind) }
            } else {
                let removed = next.live.filter { !identities.contains($0.value.identity) }
                try appendMutation(frame, added: added, removed: removed, to: &output, count: &eventCount)
                next.rendererBudget += mutationCost
            }
            next.live = current; next.viewport = frame.viewport
            next.lastTimestamp = frame.timestamp; next.nextFrameOrdinal += 1
        }
        guard output.count < limits.decodedBytes else { throw EluNativeEncodingError.byteLimit }
        output.append(0x5d)
        let chunk = EluNativeEncodedChunk(sequence: next.nextSequence,
            firstTimestamp: snapshots[0].timestamp, lastTimestamp: snapshots[snapshots.count - 1].timestamp,
            eventCount: eventCount, nodeRepresentations: representations, data: output)
        next.nextSequence += 1
        state = next
        return chunk
    }

    private func generatedNodeCost(_ kind: EluNativeMaskedKind) -> Int {
        switch kind {
        case .text, .placeholder: return 1
        case .rectangle, .input: return 0
        }
    }

    private func validate(_ frame: EluNativeMaskedSnapshot, previous: State) throws {
        guard frame.ordinal == previous.nextFrameOrdinal, frame.ordinal < Self.maximumSafeInteger else { throw EluNativeEncodingError.frameOrder }
        guard (1 ... Self.maximumSafeInteger).contains(frame.timestamp),
              previous.lastTimestamp.map({ frame.timestamp >= $0 }) ?? true else { throw EluNativeEncodingError.invalidTimestamp }
        guard previous.viewport.map({ $0 == frame.viewport }) ?? true else { throw EluNativeEncodingError.invalidViewport }
        guard frame.nodes.count < limits.liveNodes else { throw EluNativeEncodingError.nodeLimit }
        var seen: Set<UUID> = []
        for node in frame.nodes {
            guard seen.insert(node.identity).inserted else { throw EluNativeEncodingError.duplicateIdentity }
            let c = node.clip, b = node.bounds
            guard c.x >= 0, c.y >= 0, c.x + c.width <= Double(frame.viewport.width),
                  c.y + c.height <= Double(frame.viewport.height) else { throw EluNativeEncodingError.invalidGeometry }
            if c.width > 0 && c.height > 0 {
                guard c.x >= b.x, c.y >= b.y, c.x + c.width <= b.x + b.width,
                      c.y + c.height <= b.y + b.height else { throw EluNativeEncodingError.invalidGeometry }
            }
        }
    }

    private typealias JSON = EluV1StrictCanonicalJSON.Value
    private func member(_ name: String, _ value: JSON) -> EluV1StrictCanonicalJSON.Member {
        .init(name: Array(name.utf16), value: value)
    }
    private func string(_ value: String) -> JSON { .string(Array(value.utf16)) }
    private func integer(_ value: Int64) -> JSON { .number(String(value)) }
    private func number(_ value: Double) -> JSON { .number(String(value)) }
    private func rectangle(_ value: EluNativeRect) -> JSON {
        .object([member("x", number(value.x)), member("y", number(value.y)),
                 member("width", number(value.width)), member("height", number(value.height))])
    }
    private func wireframe(_ node: LiveNode) -> JSON {
        let n = node.value, b = n.bounds
        var fields = [member("id", integer(node.id)), member("x", number(b.x)), member("y", number(b.y)),
                      member("width", number(b.width)), member("height", number(b.height)), member("clip", rectangle(n.clip))]
        switch n.kind {
        case .rectangle: fields.append(member("type", string("rectangle")))
        case .text: fields += [member("type", string("text")), member("text", string(Self.mask))]
        case let .input(secure): fields += [member("type", string("input")), member("inputType", string(secure ? "password" : "text")), member("disabled", .bool(true)), member("value", string(Self.mask))]
        case .placeholder: fields += [member("type", string("placeholder")), member("label", string(Self.placeholder))]
        }
        var style: [EluV1StrictCanonicalJSON.Member] = []
        if let value = n.style.color { style.append(member("color", string(value.wireValue))) }
        if let value = n.style.backgroundColor { style.append(member("backgroundColor", string(value.wireValue))) }
        if let value = n.style.fontSize { style.append(member("fontSize", number(value))) }
        if let value = n.style.fontFamily { style.append(member("fontFamily", string(value.rawValue))) }
        if !style.isEmpty { fields.append(member("style", .object(style))) }
        return .object(fields)
    }
    private func meta(_ frame: EluNativeMaskedSnapshot) throws -> Data {
        try EluV1StrictCanonicalJSON.canonicalData(for: .object([
            member("type", integer(4)), member("timestamp", integer(frame.timestamp)),
            member("data", .object([member("width", integer(Int64(frame.viewport.width))), member("height", integer(Int64(frame.viewport.height)))]))]))
    }
    private func append(_ bytes: Data, to output: inout Data) throws {
        // Reserve the final array terminator at every append. This checks bytes
        // while building individual events, not after a giant array is allocated.
        guard bytes.count < limits.decodedBytes - output.count else { throw EluNativeEncodingError.byteLimit }
        output.append(bytes)
    }
    private func text(_ value: String, to output: inout Data) throws { try append(Data(value.utf8), to: &output) }
    private func beginEvent(to output: inout Data, count: inout Int) throws {
        guard count < limits.events else { throw EluNativeEncodingError.eventLimit }
        if count > 0 { try text(",", to: &output) }
        count += 1
    }
    private func appendEvent(_ bytes: Data, to output: inout Data, count: inout Int) throws {
        try beginEvent(to: &output, count: &count); try append(bytes, to: &output)
    }
    private func appendFull(_ frame: EluNativeMaskedSnapshot, nodes: [LiveNode], to output: inout Data, count: inout Int) throws {
        try beginEvent(to: &output, count: &count)
        try text("{\"data\":{\"initialOffset\":{\"left\":0,\"top\":0},\"wireframes\":[{\"childWireframes\":[", to: &output)
        for (index, node) in nodes.enumerated() {
            if index > 0 { try text(",", to: &output) }
            try append(EluV1StrictCanonicalJSON.canonicalData(for: wireframe(node)), to: &output)
        }
        try text("],\"height\":\(frame.viewport.height),\"id\":\(rootID),\"type\":\"div\",\"width\":\(frame.viewport.width),\"x\":0,\"y\":0}]},\"timestamp\":\(frame.timestamp),\"type\":2}", to: &output)
    }
    private func appendMutation(_ frame: EluNativeMaskedSnapshot, added: [LiveNode], removed: [LiveNode], to output: inout Data, count: inout Int) throws {
        try beginEvent(to: &output, count: &count)
        try text("{\"data\":{\"adds\":[", to: &output)
        for (index, node) in added.enumerated() {
            if index > 0 { try text(",", to: &output) }
            try text("{\"parentId\":\(rootID),\"wireframe\":", to: &output)
            try append(EluV1StrictCanonicalJSON.canonicalData(for: wireframe(node)), to: &output)
            try text("}", to: &output)
        }
        try text("],\"removes\":[", to: &output)
        for (index, node) in removed.enumerated() {
            if index > 0 { try text(",", to: &output) }
            try text("{\"id\":\(node.id),\"parentId\":\(rootID)}", to: &output)
        }
        try text("],\"source\":0,\"updates\":[]},\"timestamp\":\(frame.timestamp),\"type\":3}", to: &output)
    }
}
