import CryptoKit
import Foundation

/// Local setup authority only. Configuration responses may select a maintained
/// role path beneath this base, but cannot add an origin, prefix or redirect permission.
struct EluEndpointPolicy: Equatable, Sendable {
    static let cloud = EluEndpointPolicy(declaredAPIOrigin: nil)
    let declaredAPIOrigin: URL?

    private init(declaredAPIOrigin: URL?) { self.declaredAPIOrigin = declaredAPIOrigin }

    init(apiHost: URL?) throws {
        guard let apiHost else { self = .cloud; return }
        guard let origin = EluConfigHostAllowlist.selfHostedOrigin(apiHost) else {
            throw EluV2ConfigSourceError.untrustedConfigHost
        }
        declaredAPIOrigin = origin
    }

    func endpoint(_ value: String, role: EluV1EndpointRole, schemaVersion: Int = 2) -> URL? {
        let host = declaredAPIOrigin?.host ?? (role == .assets ? "assets.elu.dev" : "ingest.elu.dev")
        let prefix = declaredAPIOrigin.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
        } ?? ""
        let path: String
        switch role {
        case .events: path = "/v1/events"
        case .flags: path = "/v1/flags"
        case .replay: path = schemaVersion == 2 ? "/v2/replay" : "/v1/replay"
        case .assets: path = "/sdk/"
        }
        guard EluV1Validation.isAbsoluteHTTPSURI(value),
              let parts = URLComponents(string: value), parts.scheme == "https",
              parts.host?.lowercased() == host, parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == prefix + path,
              parts.queryItems?.contains(where: { $0.name == "site_key" }) != true
        else { return nil }
        return parts.url
    }

    /// Cloud installations retain their exact existing path. A self-hosted
    /// installation never opens another server's identity, consent or backlog.
    func storageRoot(under root: URL) -> URL {
        guard let origin = declaredAPIOrigin else { return root }
        let material = Data(("elu-ios-runtime-origin-v1\0" + origin.absoluteString).utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("origin-" + digest, isDirectory: true)
    }
}
