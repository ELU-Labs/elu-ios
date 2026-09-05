import Foundation

enum EluConfigHostRejection: Equatable, Sendable {
    case unsupportedScheme
    case missingHost
    case hostNotApproved
    case untrustedPort
    case credentialsPresent
    case pathPresent
    case queryPresent
    case fragmentPresent
    case loopbackNotPermitted
}

enum EluConfigHostResolution: Equatable, Sendable {
    /// A normalized `scheme://host[:port]` origin with no path, query, or fragment.
    case approved(URL)
    case rejected(EluConfigHostRejection)
}

/// Approved origins for `EluSetupOptions.configHost`.
///
/// The option stays source-compatible, but only enumerated ELU HTTPS origins
/// are accepted. A loopback origin is accepted only when the binary permits
/// it, which is limited to debug builds; there is no environment variable,
/// URL scheme, or runtime switch that widens the release allowlist.
enum EluConfigHostAllowlist {
    static let productionHost = "elu.dev"

    /// Exact ELU config hosts. Subdomains are not matched by suffix.
    static let approvedHosts: Set<String> = [
        productionHost,
        "dev.elu.dev",
        "staging.elu.dev",
        "lab.elu.dev",
    ]

    static let loopbackHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
    ]

    #if DEBUG
        static let loopbackPermitted = true
    #else
        static let loopbackPermitted = false
    #endif

    static func resolve(_ options: EluSetupOptions) -> EluConfigHostResolution {
        resolve(configHost: options.configHost)
    }

    static func resolve(
        configHost: URL,
        loopbackPermitted: Bool = Self.loopbackPermitted
    ) -> EluConfigHostResolution {
        guard let components = URLComponents(url: configHost, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            return .rejected(.unsupportedScheme)
        }
        guard let rawHost = components.host, !rawHost.isEmpty else {
            return .rejected(.missingHost)
        }
        let host = rawHost.lowercased()
        let isLoopback = loopbackHosts.contains(host)

        // Plaintext HTTP is accepted for a loopback origin only.
        guard scheme == "https" || isLoopback else {
            return .rejected(.unsupportedScheme)
        }
        guard components.user == nil, components.password == nil else {
            return .rejected(.credentialsPresent)
        }
        guard components.path.isEmpty || components.path == "/" else {
            return .rejected(.pathPresent)
        }
        guard components.query == nil else {
            return .rejected(.queryPresent)
        }
        guard components.fragment == nil else {
            return .rejected(.fragmentPresent)
        }

        if isLoopback {
            guard loopbackPermitted else {
                return .rejected(.loopbackNotPermitted)
            }
        } else {
            guard approvedHosts.contains(host) else {
                return .rejected(.hostNotApproved)
            }
            guard components.port == nil || components.port == 443 else {
                return .rejected(.untrustedPort)
            }
        }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        if isLoopback, let port = components.port {
            origin.port = port
        }
        guard let url = origin.url else {
            return .rejected(.missingHost)
        }
        return .approved(url)
    }
}
