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
    case restrictivePolicy
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
    /// Exact class equality is the only substitution the service accepts.
    enum MaskingClass: Equatable, Sendable { case blanket, sensitive }
    /// `star` describes current capture: length-preserving `*` masks.
    /// `token` describes chunks sealed by earlier versions; nothing new uses it.
    enum MaskRule: Equatable, Sendable { case token, star }

    static let maximumBytes = 1_024
    private static let blanketTokenBytes = Data(#"{"blockTraversal":"stop","configuredBlockRuleHandling":"deny-unresolved","contentAccess":"none","imageRule":"block","inputRule":"all","maskInheritance":"subtree","maskToken":"[masked]","opaqueViewRule":"block","placeholderToken":"Content hidden","profileKind":"elu-native-blanket-mask-v1","schemaVersion":1,"secureInputsMasked":true,"textRule":"all","webViewRule":"block"}"#.utf8)
    private static let sensitiveTokenBytes = Data(#"{"blockTraversal":"stop","configuredBlockRuleHandling":"deny-unresolved","contentAccess":"native-text","imageRule":"block","inputRule":"all","maskInheritance":"subtree","maskToken":"[masked]","opaqueViewRule":"block","placeholderToken":"Content hidden","profileKind":"elu-native-sensitive-mask-v1","schemaVersion":1,"secureInputsMasked":true,"textRule":"sensitive","webViewRule":"block"}"#.utf8)
    private static let blanketStarBytes = Data(#"{"blockTraversal":"stop","configuredBlockRuleHandling":"deny-unresolved","contentAccess":"masked-shape","imageRule":"block","inputMask":"star-per-utf16-unit","inputRule":"all","maskInheritance":"subtree","maskedTextMaxBytes":4096,"opaqueViewRule":"block","placeholderToken":"Content hidden","profileKind":"elu-native-blanket-star-mask-v1","schemaVersion":2,"secureInputsMasked":true,"textMask":"star-non-whitespace-utf16","textRule":"all","webViewRule":"block"}"#.utf8)
    private static let sensitiveStarBytes = Data(#"{"blockTraversal":"stop","configuredBlockRuleHandling":"deny-unresolved","contentAccess":"native-text","imageRule":"block","inputMask":"star-per-utf16-unit","inputRule":"all","maskInheritance":"subtree","maskedTextMaxBytes":4096,"opaqueViewRule":"block","placeholderToken":"Content hidden","profileKind":"elu-native-sensitive-star-mask-v1","schemaVersion":2,"secureInputsMasked":true,"textMask":"star-non-whitespace-utf16","textRule":"sensitive","webViewRule":"block"}"#.utf8)
    private static let known: [(bytes: Data, maskingClass: MaskingClass, rule: MaskRule)] = [
        (blanketStarBytes, .blanket, .star), (sensitiveStarBytes, .sensitive, .star),
        (blanketTokenBytes, .blanket, .token), (sensitiveTokenBytes, .sensitive, .token),
    ]
    let canonicalBytes: Data
    let maskingClass: MaskingClass
    let rule: MaskRule
    var allowsOrdinaryText: Bool { maskingClass == .sensitive }
    var textMasking: EluV1MaskingLevel { allowsOrdinaryText ? .sensitive : .all }
    var hash: String { EluV1StrictCanonicalJSON.hash(canonicalBytes) }

    private init(_ entry: (bytes: Data, maskingClass: MaskingClass, rule: MaskRule)) {
        canonicalBytes = entry.bytes; maskingClass = entry.maskingClass; rule = entry.rule
    }

    /// A description of the implemented fixed behavior, never permission to run it.
    /// Both describe current capture, which always masks with `*`.
    static func blanketMask() -> Self { Self(known[0]) }
    static func sensitiveMask() -> Self { Self(known[1]) }

    static func select(for policy: EluV1MaskingPolicy, platform: EluV1Platform) -> Self {
        let hasApplicableRules = policy.platformRules?.contains { $0.platform == platform } ?? false
        return policy.text == .sensitive && !hasApplicableRules ? .sensitiveMask() : .blanketMask()
    }

    /// Accepts all four closed documents, so chunks sealed before an upgrade
    /// keep their original description and remain deliverable.
    static func parse(_ bytes: Data) throws -> Self {
        guard (1 ... maximumBytes).contains(bytes.count) else { throw EluNativeMaskingProfileError.invalidSize }
        let document = try EluV1StrictCanonicalJSON.parse(bytes)
        guard case .object = document.value, document.canonicalData == bytes,
              let entry = known.first(where: { $0.bytes == bytes }) else { throw EluNativeMaskingProfileError.unrecognizedProfile }
        // Return private immutable storage, not a potentially externally aliased Data buffer.
        return Self(entry)
    }

    /// The supplied policy must come from the validated original configuration.
    /// Mask-only targets are covered by all-content masking without interpreting
    /// their dialect; an applicable block target remains unresolved and denies.
    func compatibility(with policy: EluV1MaskingPolicy?, platform: EluV1Platform) -> EluNativeMaskingCompatibility {
        guard let policy else { return .policyUnavailable }
        guard platform == .ios || platform == .android else { return .unsupportedPlatform }
        if allowsOrdinaryText && (policy.text != .sensitive ||
            policy.platformRules?.contains(where: { $0.platform == platform }) == true) {
            return .restrictivePolicy
        }
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
        case .unsupportedPlatform, .unresolvedBlockRule, .restrictivePolicy: return .restrictivePolicy
        }
    }
}
