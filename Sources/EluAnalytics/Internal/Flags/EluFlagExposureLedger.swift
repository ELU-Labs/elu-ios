import CryptoKit
import Foundation

/// Exposure history belongs to the anonymous visitor, independently of the
/// current account, session, configuration or disposable evaluation cache.
struct EluFlagExposureLedger: Equatable, Sendable {
    static let maximumEntries = 4_096
    static let maximumBytes = 300_000
    let anonymousId: String
    var digests: Set<String> = []

    func encoded() throws -> Data {
        guard EluIdentityState.valid(anonymousId, maximumLength: 256),
              digests.count <= Self.maximumEntries,
              digests.allSatisfy(Self.validDigest) else { throw EluRuntimeQueueError.corruptStorage }
        let data = try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject:
            ["anonymousId": anonymousId, "digests": digests.sorted()])).canonicalData
        guard data.count <= Self.maximumBytes else { throw EluRuntimeQueueError.corruptStorage }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard (1...maximumBytes).contains(data.count) else { throw EluRuntimeQueueError.corruptStorage }
        struct Stored: Decodable { let anonymousId: String; let digests: [String] }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        let value = Self(anonymousId: stored.anonymousId, digests: Set(stored.digests))
        // Exact canonical round-trip rejects unknown/duplicate keys, duplicate
        // entries, alternate ordering and noncanonical representations.
        guard try value.encoded() == data else { throw EluRuntimeQueueError.corruptStorage }
        return value
    }

    static func digest(key: String, value: EluV1FlagValue?) throws -> String {
        let typed = EluV1FlagJSONValue.array([try EluV1FlagJSON.string(key), .bool(value != nil), value?.jsonValue ?? .null])
        var bytes = Data("elu-flag-exposure-v1\0".utf8)
        bytes.append(try EluV1FlagJSON.canonicalData(for: typed))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct EluFlagExposureRequest: Sendable {
    let anonymousId: String
    let digest: String
}
