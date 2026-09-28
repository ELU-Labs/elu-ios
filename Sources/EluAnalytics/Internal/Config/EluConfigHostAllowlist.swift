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
/// are accepted, plus exactly the self-hosted ELU instance an app declares as
/// `EluSetupOptions.apiHost`: both HTTPS on the default port with the same
/// host, and no credentials, path, query, fragment or trailing dot, so the
/// declaration cannot widen the allowlist to any other host. A loopback origin
/// is accepted only when the binary permits it, which is limited to debug
/// builds; there is no environment variable, URL scheme, or runtime switch
/// that widens the release allowlist.
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

    /// Loopback names the self-hosted rule never accepts: they are governed
    /// by the debug-only loopback rule alone.
    static let selfHostedExcludedHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "::1",
        "[::1]",
        "10.0.2.2",
    ]

    static func resolve(_ options: EluSetupOptions) -> EluConfigHostResolution {
        resolve(configHost: options.configHost, apiHost: options.apiHost)
    }

    static func resolve(
        configHost: URL,
        apiHost: URL? = nil,
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
        } else if approvedHosts.contains(host) {
            guard components.port == nil || components.port == 443 else {
                return .rejected(.untrustedPort)
            }
        } else {
            guard let apiHost, let declared = selfHostedOrigin(apiHost),
                  selfHostedOrigin(configHost) == declared
            else {
                return .rejected(.hostNotApproved)
            }
            return .approved(declared)
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

    /// `https://host` for an HTTPS origin on the default port with a plain,
    /// non-loopback host and no credentials, path, query or fragment, else nil.
    static func selfHostedOrigin(_ value: URL) -> URL? {
        guard let components = URLComponents(url: value, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.port == nil,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil
        else {
            return nil
        }
        let host = rawHost.lowercased()
        guard !host.hasSuffix("."), !host.hasPrefix("."), !selfHostedExcludedHosts.contains(host) else {
            return nil
        }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        return origin.url
    }
}
