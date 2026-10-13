import Foundation

/// Owned installation metadata. Customer superproperties cannot alter these fields.
struct EluPersonIdentityState: Codable, Equatable, Sendable {
    static let maximumBytes = 2_048
    var deviceId: String
    var processingEnabled: Bool = false

    func permits(_ identity: EluIdentityState, mode: EluPersonProfilesMode) -> Bool {
        switch mode {
        case .never: return false
        case .always: return true
        case .identifiedOnly: return processingEnabled || identity.userId != nil || !identity.groups.isEmpty
        }
    }

    func encoded() throws -> Data {
        guard EluIdentityState.valid(deviceId, maximumLength: 256) else { throw EluRuntimeQueueError.corruptStorage }
        let value: [String: Any] = ["deviceId": deviceId, "processingEnabled": processingEnabled]
        return try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: value)).canonicalData
    }

    static func decode(_ data: Data) throws -> Self {
        guard (1...maximumBytes).contains(data.count) else { throw EluRuntimeQueueError.corruptStorage }
        let parsed = try EluV1StrictCanonicalJSON.parse(data)
        guard parsed.canonicalData == data, case let .object(fields) = parsed.value,
              Set(fields.map { String(decoding: $0.name, as: UTF16.self) }) == ["deviceId", "processingEnabled"]
        else { throw EluRuntimeQueueError.corruptStorage }
        let value = try JSONDecoder().decode(Self.self, from: data)
        _ = try value.encoded()
        return value
    }
}
