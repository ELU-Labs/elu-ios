import Foundation

/// Closed binary formats. This descriptive tuple is not capture authority or a
/// release advertisement; the installed runtime still selects its proven v1 tuple.
enum EluNativeReplayProtocol: CaseIterable, Equatable, Sendable {
    case v1
    case v2

    var codec: String {
        switch self {
        case .v1: return "elu-native-wireframe-v1"
        case .v2: return "elu-native-wireframe-v2"
        }
    }
    var generation: String {
        switch self {
        case .v1: return "protocol-generation-v1"
        case .v2: return "protocol-generation-v2"
        }
    }
    var chunkIdentityDomain: String {
        switch self {
        case .v1: return "elu-native-replay-chunk-v1"
        case .v2: return "elu-native-replay-chunk-v2"
        }
    }
    var transport: EluV1ReplayTransportSelection {
        EluV1ReplayTransportSelection(codec: codec, compression: .gzip)!
    }
    static func matching(codec: String, compression: String, generation: String?) -> Self? {
        guard let generation, compression.utf8.elementsEqual("gzip".utf8) else { return nil }
        return allCases.first { $0.codec.utf8.elementsEqual(codec.utf8) && $0.generation.utf8.elementsEqual(generation.utf8) }
    }
    static func isNativeCodec(_ codec: String) -> Bool {
        allCases.contains { $0.codec.utf8.elementsEqual(codec.utf8) }
    }
}
