import Foundation

enum EluNativeMaskingProfileError: Error, Equatable, Sendable {
    case invalidSize
    case unrecognizedProfile
}

/// Policy compatibility is not source, channel, recorder or storage authority.
enum EluNativeMaskingCompatibility: Equatable, Sendable {
    case compatible
    case policyUnavailable
    case unsupportedPlatform
    case unresolvedBlockRule
}

/// The caller must retain the distinction between an unavailable policy and an
/// actual restrictive current policy. This result never performs a queue purge.
enum EluNativeMaskingRetention: Equatable, Sendable {
    case compatible
    case policyUnavailable
    case unrecognizedStoredProfile
    case restrictivePolicy
}

/// Closed, immutable native masking metadata. It contains no remote target
/// dialect, source token, clock, session, budget or advertised transport claim.
struct EluNativeMaskingProfile: Equatable, Sendable {
    static let maximumBytes = 1_024
    private static let frozenBytes = Data(#"{"blockTraversal":"stop","configuredBlockRuleHandling":"deny-unresolved","contentAccess":"none","imageRule":"block","inputRule":"all","maskInheritance":"subtree","maskToken":"[masked]","opaqueViewRule":"block","placeholderToken":"Content hidden","profileKind":"elu-native-blanket-mask-v1","schemaVersion":1,"secureInputsMasked":true,"textRule":"all","webViewRule":"block"}"#.utf8)
    let canonicalBytes: Data
    var hash: String { EluV1StrictCanonicalJSON.hash(canonicalBytes) }

    private init(canonicalBytes: Data) { self.canonicalBytes = canonicalBytes }

    /// A description of the implemented fixed behavior, never permission to run it.
    static func blanketMask() -> Self { Self(canonicalBytes: frozenBytes) }

    static func parse(_ bytes: Data) throws -> Self {
        guard (1 ... maximumBytes).contains(bytes.count) else { throw EluNativeMaskingProfileError.invalidSize }
        let document = try EluV1StrictCanonicalJSON.parse(bytes)
        guard case .object = document.value, document.canonicalData == bytes,
              bytes == frozenBytes else { throw EluNativeMaskingProfileError.unrecognizedProfile }
        // Return private immutable storage, not a potentially externally aliased Data buffer.
        return Self(canonicalBytes: frozenBytes)
    }

    /// The supplied policy must come from the validated original configuration.
    /// Mask-only targets are covered by all-content masking without interpreting
    /// their dialect; an applicable block target remains unresolved and denies.
    func compatibility(with policy: EluV1MaskingPolicy?, platform: EluV1Platform) -> EluNativeMaskingCompatibility {
        guard let policy else { return .policyUnavailable }
        guard platform == .ios || platform == .android else { return .unsupportedPlatform }
        for rule in policy.platformRules ?? [] where rule.platform == platform {
            if case .block = rule.action { return .unresolvedBlockRule }
        }
        // The closed parsed policy permits all/sensitive and allow/block only;
        // fixed all/all/block behavior satisfies all those masking levels.
        return .compatible
    }

    static func retention(of storedBytes: Data, required policy: EluV1MaskingPolicy?,
                          platform: EluV1Platform) -> EluNativeMaskingRetention {
        guard let policy else { return .policyUnavailable }
        guard let profile = try? parse(storedBytes) else { return .unrecognizedStoredProfile }
        switch profile.compatibility(with: policy, platform: platform) {
        case .compatible: return .compatible
        case .policyUnavailable: return .policyUnavailable
        case .unsupportedPlatform, .unresolvedBlockRule: return .restrictivePolicy
        }
    }
}
