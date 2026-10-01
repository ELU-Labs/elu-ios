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
    /// A normalized origin, with the explicitly declared self-hosted path prefix.
    case approved(URL)
    case rejected(EluConfigHostRejection)
}

/// Approved origins for `EluSetupOptions.configHost`.
///
/// The option stays source-compatible, but only enumerated ELU HTTPS origins
/// are accepted, plus exactly the self-hosted ELU instance an app declares as
/// `EluSetupOptions.apiHost`: both HTTPS on the default port with the same
/// host and path prefix, and no credentials, query, fragment or trailing dot, so the
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
        if let apiHost, selfHostedOrigin(apiHost) == nil { return .rejected(.hostNotApproved) }
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
        guard components.query == nil else {
            return .rejected(.queryPresent)
        }
        guard components.fragment == nil else {
            return .rejected(.fragmentPresent)
        }

        // A prefix is authority only when the application declared this exact
        // canonical base. Cloud and debug-loopback allowlists remain root-only.
        if let apiHost, let declared = selfHostedOrigin(apiHost),
           selfHostedOrigin(configHost) == declared {
            return .approved(declared)
        }
        guard components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else {
            return .rejected(.pathPresent)
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

    /// Canonical HTTPS base on the default port, with an optional regular path
    /// prefix. Preserve its encoded bytes; never resolve dot segments or turn an
    /// encoded separator into a different server-side path.
    static func selfHostedOrigin(_ value: URL) -> URL? {
        guard let components = URLComponents(url: value, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.port == nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else {
            return nil
        }
        let host = rawHost.lowercased()
        guard !host.hasSuffix("."), !host.hasPrefix("."), !selfHostedExcludedHosts.contains(host) else {
            return nil
        }
        let path = components.percentEncodedPath
        let prefix = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard prefix.isEmpty || prefix.hasPrefix("/") else { return nil }
        for encoded in prefix.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            guard !encoded.isEmpty, let segment = String(encoded).removingPercentEncoding,
                  segment != ".", segment != "..",
                  !segment.unicodeScalars.contains(where: {
                      $0.value <= 0x20 || $0.value == 0x7f || $0 == "/" || $0 == "\\"
                  })
            else { return nil }
        }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.percentEncodedPath = prefix
        return origin.url
    }
}
