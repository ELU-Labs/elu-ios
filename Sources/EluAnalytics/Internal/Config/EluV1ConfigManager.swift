import CryptoKit
import Foundation

struct EluV1AuthorizedEndpointSet: Equatable, Sendable {
    private let endpoints: [EluV1EndpointRole: URL]

    fileprivate init(_ endpoints: [EluV1EndpointRole: URL]) {
        self.endpoints = endpoints
    }

    var roles: Set<EluV1EndpointRole> {
        Set(endpoints.keys)
    }

    subscript(role: EluV1EndpointRole) -> URL? {
        endpoints[role]
    }
}

/// A platform transport pair that has passed the external replay readback gate.
/// Merely appearing in server config does not make a codec usable on this runtime.
struct EluV1ReplayTransportSelection: Equatable, Hashable, Sendable {
    let codec: String
    let compression: EluV1Compression

    init?(codec: String, compression: EluV1Compression) {
        guard EluV1Validation.validCapabilityIdentifier(codec) else { return nil }
        self.codec = codec
        self.compression = compression
    }
}

enum EluV1PrivacyInvalidReason: Equatable, Sendable {
    case missingState
    case payloadTooLarge
    case malformedState
    case unsupportedSchemaVersion
    case invalidPolicyHash
    case policyRevisionMismatch
    case contextRevisionMismatch
    case identityOptStateMismatch
    case regionPolicyConflict
    case effectiveMaskingWeakerThanPolicy
    case unadvertisedReplayTransport
    case claimedAuthorizationMismatch
}

enum EluV1CaptureRestrictionReason: Equatable, Sendable {
    case featureDisabled
    case policyDisabled
    case onDeviceBlocked
    case onDeviceUnknown
    case identityOptedOut
}

enum EluV1CaptureAuthorization: Equatable, Sendable {
    case authorized
    case restricted(EluV1CaptureRestrictionReason)
    case invalid(EluV1PrivacyInvalidReason)
}

enum EluV1ReplayRestrictionReason: Equatable, Sendable {
    case captureUnavailable
    case featureDisabled
    case policyDisabled
    case notSampled
    case maskingNotValidated
    case sessionIneligible
    case budgetExhausted
    case transportNotSelected
    case nativeMaskingFallbackMissing
    case unsupportedLocalTransport
}

enum EluV1ReplayAuthorization: Equatable, Sendable {
    case authorized(EluV1ReplayTransportSelection)
    case restricted(EluV1ReplayRestrictionReason)
    case invalid(EluV1PrivacyInvalidReason)
}

/// Immutable authorization result. It deliberately contains no raw endpoint
/// map: a caller can receive only roles authorized by the currently installed
/// config, effective privacy state, identity snapshot, and local capabilities.
struct EluV1ConfigResolution: Equatable, Sendable {
    let configRevision: String
    let siteId: String
    let issuedAt: Date
    let expiresAt: Date
    let endpoints: EluV1AuthorizedEndpointSet
    let captureAuthorization: EluV1CaptureAuthorization
    let replayAuthorization: EluV1ReplayAuthorization
}

enum EluV1ConfigUpdateResult: Equatable, Sendable {
    case enabled(revision: String, expiresAt: Date)
    case disabled(revision: String)
    case revoked(revision: String)
    case expired(revision: String)
    case stale(revision: String)
}

/// Internal, serialized v1 config owner. It retains one active config and a
/// terminal boundary for the newest validated document, including disabled,
/// revoked, expired, and conflicting outcomes. Older responses can never
/// restore authority after a newer kill switch or lower expiry.
final class EluV1ConfigManager: @unchecked Sendable {
    static let maximumConfigBytes = 65_536
    static let maximumPrivacyStateBytes = 32_768

    private struct PreparedConfig {
        let document: EluV1ConfigDocument
        let semanticValue: EluJSONValue
        let trustedEndpoints: [EluV1EndpointRole: URL]?
    }

    private enum BoundaryOutcome: Equatable {
        case enabled
        case disabled
        case revoked
        case expired
        case conflicted
    }

    private struct ConfigBoundary {
        let prepared: PreparedConfig
        var outcome: BoundaryOutcome
    }

    // This module does not interpret iOS masking-rule dialects, so native
    // replay authorization always requires recorded fallback proof.
    private static let recognizedIOSMaskingRuleDialects: Set<String> = []

    private let lock = NSLock()
    private let readbackProvenReplayTransports: Set<EluV1ReplayTransportSelection>
    private var newestBoundary: ConfigBoundary?
    private var activeConfig: PreparedConfig?

    init(
        readbackProvenReplayTransports: Set<EluV1ReplayTransportSelection> = []
    ) {
        self.readbackProvenReplayTransports = readbackProvenReplayTransports
    }

    func update(configData: Data, now: Date) throws -> EluV1ConfigUpdateResult {
        lock.lock()
        defer { lock.unlock() }

        do {
            try Self.validateClock(now)
            let prepared = try Self.prepareConfig(configData)
            expireActiveConfigIfNeeded(now: now)

            if var boundary = newestBoundary {
                if prepared.document.issuedAt < boundary.prepared.document.issuedAt {
                    return .stale(revision: prepared.document.revision)
                }

                if prepared.document.issuedAt == boundary.prepared.document.issuedAt {
                    guard prepared.document.revision == boundary.prepared.document.revision,
                          prepared.semanticValue == boundary.prepared.semanticValue,
                          boundary.outcome != .conflicted
                    else {
                        boundary.outcome = .conflicted
                        newestBoundary = boundary
                        activeConfig = nil
                        throw EluV1ConfigResolutionError.conflictingConfigAtIssuedAt
                    }

                    switch boundary.outcome {
                    case .disabled:
                        return .disabled(revision: prepared.document.revision)
                    case .revoked:
                        return .revoked(revision: prepared.document.revision)
                    case .expired:
                        return .expired(revision: prepared.document.revision)
                    case .conflicted:
                        throw EluV1ConfigResolutionError.conflictingConfigAtIssuedAt
                    case .enabled:
                        if prepared.document.expiresAt.isAtOrBefore(now) {
                            boundary.outcome = .expired
                            newestBoundary = boundary
                            activeConfig = nil
                            return .expired(revision: prepared.document.revision)
                        }
                        // A malformed response may fail closed temporarily. An
                        // identical validated response at the same boundary can
                        // restore that exact authority, but no conflicting one can.
                        activeConfig = boundary.prepared
                        return .enabled(
                            revision: prepared.document.revision,
                            expiresAt: prepared.document.expiresAt.date
                        )
                    }
                }
            }

            return installNewBoundary(prepared, now: now)
        } catch {
            activeConfig = nil
            throw error
        }
    }

    func authorize(
        effectivePrivacyStateData: Data?,
        identity: EluIdentitySnapshot,
        now: Date
    ) throws -> EluV1ConfigResolution {
        lock.lock()
        defer { lock.unlock() }

        try Self.validateClock(now)
        expireActiveConfigIfNeeded(now: now)
        guard let active = activeConfig else {
            throw EluV1ConfigResolutionError.missingActiveConfig
        }
        let config = active.document
        guard let site = config.site,
              let privacyPolicy = config.privacy,
              let features = config.features,
              let capabilities = config.capabilities,
              let trustedEndpoints = active.trustedEndpoints
        else {
            throw EluV1ConfigResolutionError.malformedConfig
        }

        var configAuthorized: [EluV1EndpointRole: URL] = [:]
        if features.flags {
            configAuthorized[.flags] = trustedEndpoints[.flags]
        }

        func resolution(
            capture: EluV1CaptureAuthorization,
            replay: EluV1ReplayAuthorization,
            eventsAuthorized: Bool = false,
            replayAuthorized: Bool = false
        ) -> EluV1ConfigResolution {
            var authorized = configAuthorized
            if eventsAuthorized {
                authorized[.events] = trustedEndpoints[.events]
            }
            if replayAuthorized {
                authorized[.replay] = trustedEndpoints[.replay]
            }
            return EluV1ConfigResolution(
                configRevision: config.revision,
                siteId: site.id,
                issuedAt: config.issuedAt.date,
                expiresAt: config.expiresAt.date,
                endpoints: EluV1AuthorizedEndpointSet(authorized),
                captureAuthorization: capture,
                replayAuthorization: replay
            )
        }

        func invalidPrivacy(_ reason: EluV1PrivacyInvalidReason) -> EluV1ConfigResolution {
            resolution(capture: .invalid(reason), replay: .invalid(reason))
        }

        guard let effectivePrivacyStateData else {
            return invalidPrivacy(.missingState)
        }

        let effectivePrivacy: EluV1EffectivePrivacyState
        do {
            effectivePrivacy = try Self.decodePrivacyState(effectivePrivacyStateData)
            try Self.verifyEffectivePolicyHash(
                effectivePrivacyStateData,
                expected: effectivePrivacy.effectivePolicyHash
            )
        } catch {
            return invalidPrivacy(Self.sharedPrivacyInvalidReason(for: error))
        }

        guard effectivePrivacy.policyRevision == privacyPolicy.revision else {
            return invalidPrivacy(.policyRevisionMismatch)
        }
        guard effectivePrivacy.contextRevision == identity.identity.contextRevision else {
            return invalidPrivacy(.contextRevisionMismatch)
        }
        guard effectivePrivacy.identityOptedOut == identity.identity.optedOut else {
            return invalidPrivacy(.identityOptStateMismatch)
        }

        let captureAllowed = features.capture
            && privacyPolicy.capture.enabled
            && effectivePrivacy.onDeviceDecision.decision == .allow
            && !identity.identity.optedOut

        let captureAuthorization: EluV1CaptureAuthorization
        if privacyPolicy.regionPolicy.mode == .block,
           effectivePrivacy.onDeviceDecision.decision == .allow
        {
            captureAuthorization = .invalid(.regionPolicyConflict)
        } else if effectivePrivacy.captureAllowed != captureAllowed {
            captureAuthorization = .invalid(.claimedAuthorizationMismatch)
        } else if captureAllowed {
            captureAuthorization = .authorized
        } else {
            captureAuthorization = .restricted(
                Self.captureRestrictionReason(
                    features: features,
                    policy: privacyPolicy,
                    privacy: effectivePrivacy,
                    identity: identity
                )
            )
        }

        let selectedServerTransport: EluV1ReplayTransportSelection?
        var replayInvalidReason: EluV1PrivacyInvalidReason?
        if let transport = effectivePrivacy.replayTransport {
            if transport.advertised,
               capabilities.replay.acceptedCodecs.contains(transport.codec),
               capabilities.replay.acceptedCompressions.contains(transport.compression),
               let selection = EluV1ReplayTransportSelection(
                   codec: transport.codec,
                   compression: transport.compression
               )
            {
                selectedServerTransport = selection
            } else {
                selectedServerTransport = nil
                replayInvalidReason = .unadvertisedReplayTransport
            }
        } else {
            selectedServerTransport = nil
        }

        if !Self.effectiveMasking(
            effectivePrivacy.effectiveMasking,
            satisfies: privacyPolicy.masking
        ) {
            replayInvalidReason = replayInvalidReason ?? .effectiveMaskingWeakerThanPolicy
        }

        let replayTransportAdvertised = selectedServerTransport != nil
        let serverReplayAllowed = captureAllowed
            && features.replay
            && privacyPolicy.replay.enabled
            && effectivePrivacy.replaySampled
            && effectivePrivacy.maskingValidated
            && effectivePrivacy.replaySessionEligible
            && effectivePrivacy.replayBudgetRemainingSeconds > 0
            && replayTransportAdvertised

        let iosRules = privacyPolicy.masking.platformRules?.filter { $0.platform == .ios } ?? []
        let allIOSRulesAreRecognized = !iosRules.isEmpty && iosRules.allSatisfy {
            Self.recognizedIOSMaskingRuleDialects.contains($0.targetDialect)
        }
        let nativeMaskingProven = allIOSRulesAreRecognized
            || effectivePrivacy.effectiveMasking.platformFallbackApplied

        let replayAuthorization: EluV1ReplayAuthorization
        if let replayInvalidReason {
            replayAuthorization = .invalid(replayInvalidReason)
        } else if effectivePrivacy.replayAllowed != serverReplayAllowed {
            replayAuthorization = .invalid(.claimedAuthorizationMismatch)
        } else if captureAuthorization != .authorized {
            replayAuthorization = .restricted(.captureUnavailable)
        } else if !serverReplayAllowed {
            replayAuthorization = .restricted(
                Self.replayRestrictionReason(
                    features: features,
                    policy: privacyPolicy,
                    privacy: effectivePrivacy,
                    transportSelected: selectedServerTransport != nil
                )
            )
        } else if !nativeMaskingProven {
            replayAuthorization = .restricted(.nativeMaskingFallbackMissing)
        } else if let selection = selectedServerTransport,
                  readbackProvenReplayTransports.contains(selection)
        {
            replayAuthorization = .authorized(selection)
        } else {
            replayAuthorization = .restricted(.unsupportedLocalTransport)
        }

        // The assets role is browser-only. Native config still validates any
        // advertised URL so an untrusted member poisons the whole document,
        // but iOS never exposes that endpoint as runtime authority.
        return resolution(
            capture: captureAuthorization,
            replay: replayAuthorization,
            eventsAuthorized: captureAuthorization == .authorized,
            replayAuthorized: {
                if case .authorized = replayAuthorization { return true }
                return false
            }()
        )
    }

    private static func sharedPrivacyInvalidReason(for error: Error) -> EluV1PrivacyInvalidReason {
        guard let error = error as? EluV1ConfigResolutionError else {
            return .malformedState
        }
        switch error {
        case .privacyPayloadTooLarge:
            return .payloadTooLarge
        case .unsupportedPrivacyStateSchemaVersion:
            return .unsupportedSchemaVersion
        case .invalidEffectivePolicyHash:
            return .invalidPolicyHash
        default:
            return .malformedState
        }
    }

    private static func captureRestrictionReason(
        features: EluV1Features,
        policy: EluV1PrivacyPolicy,
        privacy: EluV1EffectivePrivacyState,
        identity: EluIdentitySnapshot
    ) -> EluV1CaptureRestrictionReason {
        if identity.identity.optedOut { return .identityOptedOut }
        switch privacy.onDeviceDecision.decision {
        case .block:
            return .onDeviceBlocked
        case .unknown:
            return .onDeviceUnknown
        case .allow:
            break
        }
        if !features.capture { return .featureDisabled }
        return .policyDisabled
    }

    private static func replayRestrictionReason(
        features: EluV1Features,
        policy: EluV1PrivacyPolicy,
        privacy: EluV1EffectivePrivacyState,
        transportSelected: Bool
    ) -> EluV1ReplayRestrictionReason {
        if !features.replay { return .featureDisabled }
        if !policy.replay.enabled { return .policyDisabled }
        if !privacy.replaySampled { return .notSampled }
        if !privacy.maskingValidated { return .maskingNotValidated }
        if !privacy.replaySessionEligible { return .sessionIneligible }
        if privacy.replayBudgetRemainingSeconds == 0 { return .budgetExhausted }
        if !transportSelected { return .transportNotSelected }
        // The formula can be false only through capture at this point, but that
        // case is handled before this helper.
        return .captureUnavailable
    }

    private func installNewBoundary(
        _ prepared: PreparedConfig,
        now: Date
    ) -> EluV1ConfigUpdateResult {
        let revision = prepared.document.revision
        if prepared.document.expiresAt.isAtOrBefore(now) {
            newestBoundary = ConfigBoundary(prepared: prepared, outcome: .expired)
            activeConfig = nil
            return .expired(revision: revision)
        }

        switch prepared.document.status {
        case .enabled:
            newestBoundary = ConfigBoundary(prepared: prepared, outcome: .enabled)
            activeConfig = prepared
            return .enabled(revision: revision, expiresAt: prepared.document.expiresAt.date)
        case .disabled:
            newestBoundary = ConfigBoundary(prepared: prepared, outcome: .disabled)
            activeConfig = nil
            return .disabled(revision: revision)
        case .revoked:
            newestBoundary = ConfigBoundary(prepared: prepared, outcome: .revoked)
            activeConfig = nil
            return .revoked(revision: revision)
        }
    }

    private func expireActiveConfigIfNeeded(now: Date) {
        guard let active = activeConfig,
              active.document.expiresAt.isAtOrBefore(now)
        else {
            return
        }
        activeConfig = nil
        if var boundary = newestBoundary,
           boundary.prepared.document.issuedAt == active.document.issuedAt
        {
            boundary.outcome = .expired
            newestBoundary = boundary
        }
    }

    private static func validateClock(_ now: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw EluV1ConfigResolutionError.invalidClock
        }
    }

    private static func prepareConfig(_ data: Data) throws -> PreparedConfig {
        let (document, semanticValue) = try decodeConfig(data)
        guard document.issuedAt < document.expiresAt else {
            throw EluV1ConfigResolutionError.invalidConfigValidityWindow
        }
        let trustedEndpoints: [EluV1EndpointRole: URL]?
        if document.status == .enabled {
            guard let endpoints = document.endpoints else {
                throw EluV1ConfigResolutionError.malformedConfig
            }
            trustedEndpoints = try validateAllEndpoints(endpoints)
        } else {
            trustedEndpoints = nil
        }
        return PreparedConfig(
            document: document,
            semanticValue: semanticValue,
            trustedEndpoints: trustedEndpoints
        )
    }

    private static func decodeConfig(_ data: Data) throws -> (EluV1ConfigDocument, EluJSONValue) {
        guard data.count <= maximumConfigBytes else {
            throw EluV1ConfigResolutionError.configPayloadTooLarge
        }
        do {
            return (
                try JSONDecoder().decode(EluV1ConfigDocument.self, from: data),
                try JSONDecoder().decode(EluJSONValue.self, from: data)
            )
        } catch let error as EluV1ConfigResolutionError {
            throw error
        } catch {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }

    private static func decodePrivacyState(_ data: Data) throws -> EluV1EffectivePrivacyState {
        guard data.count <= maximumPrivacyStateBytes else {
            throw EluV1ConfigResolutionError.privacyPayloadTooLarge
        }
        do {
            return try JSONDecoder().decode(EluV1EffectivePrivacyState.self, from: data)
        } catch EluV1ConfigResolutionError.unsupportedPrivacyStateSchemaVersion {
            throw EluV1ConfigResolutionError.unsupportedPrivacyStateSchemaVersion
        } catch {
            throw EluV1ConfigResolutionError.malformedPrivacyState
        }
    }

    private static func validateAllEndpoints(
        _ endpoints: EluV1RawEndpoints
    ) throws -> [EluV1EndpointRole: URL] {
        var validated: [EluV1EndpointRole: URL] = [
            .events: try validateEndpoint(endpoints.events, role: .events),
            .flags: try validateEndpoint(endpoints.flags, role: .flags),
        ]
        if let replay = endpoints.replay {
            validated[.replay] = try validateEndpoint(replay, role: .replay)
        }
        if let assets = endpoints.assets {
            validated[.assets] = try validateEndpoint(assets, role: .assets)
        }
        return validated
    }

    private static func validateEndpoint(_ value: String, role: EluV1EndpointRole) throws -> URL {
        let expectedHost: String
        let expectedPath: String
        switch role {
        case .events:
            expectedHost = "ingest.elu.dev"
            expectedPath = "/v1/events"
        case .replay:
            expectedHost = "ingest.elu.dev"
            expectedPath = "/v1/replay"
        case .flags:
            expectedHost = "ingest.elu.dev"
            expectedPath = "/v1/flags"
        case .assets:
            expectedHost = "assets.elu.dev"
            expectedPath = "/sdk/"
        }

        guard EluV1Validation.isAbsoluteHTTPSURI(value),
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host?.lowercased() == expectedHost,
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.percentEncodedPath == expectedPath,
              components.queryItems?.contains(where: { $0.name == "site_key" }) != true,
              let url = components.url
        else {
            throw EluV1ConfigResolutionError.untrustedEndpoint(role)
        }
        return url
    }

    private static func effectiveMasking(
        _ effective: EluV1EffectiveMasking,
        satisfies policy: EluV1MaskingPolicy
    ) -> Bool {
        let textIsSufficient = policy.text == .sensitive || effective.text == .all
        let inputsAreSufficient = policy.inputs == .sensitive || effective.inputs == .all
        let imagesAreSufficient = policy.images == .allow || effective.images == .block
        return effective.secureInputsMasked
            && textIsSufficient
            && inputsAreSufficient
            && imagesAreSufficient
    }

    private static func verifyEffectivePolicyHash(_ data: Data, expected: String) throws {
        let actual = try computedEffectivePolicyHash(for: data)
        guard actual == expected else {
            throw EluV1ConfigResolutionError.invalidEffectivePolicyHash
        }
    }

    /// Shared by privacy evaluation and conformance tests. Computing a hash
    /// does not validate or authorize the state.
    static func computedEffectivePolicyHash(for data: Data) throws -> String {
        let value: EluJSONValue
        do {
            value = try JSONDecoder().decode(EluJSONValue.self, from: data)
        } catch {
            throw EluV1ConfigResolutionError.malformedPrivacyState
        }
        guard case var .object(object) = value,
              case let .string(rawHash)? = object.removeValue(forKey: "effectivePolicyHash"),
              EluV1Validation.validPolicyHash(rawHash)
        else {
            throw EluV1ConfigResolutionError.malformedPrivacyState
        }
        let canonical: String
        do {
            canonical = try canonicalJSON(.object(object))
        } catch {
            throw EluV1ConfigResolutionError.malformedPrivacyState
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalJSON(_ value: EluJSONValue) throws -> String {
        switch value {
        case .null:
            return "null"
        case let .bool(value):
            return value ? "true" : "false"
        case let .integer(value):
            return String(value)
        case let .number(value):
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= Double(Int64.min),
                  value < Double(Int64.max)
            else {
                throw EluV1ConfigResolutionError.malformedPrivacyState
            }
            return String(Int64(value))
        case let .string(value):
            return canonicalJSONString(value)
        case let .array(values):
            return "[" + (try values.map(canonicalJSON).joined(separator: ",")) + "]"
        case let .object(values):
            let members = try values.keys.sorted().map { key in
                canonicalJSONString(key) + ":" + (try canonicalJSON(values[key]!))
            }
            return "{" + members.joined(separator: ",") + "}"
        }
    }

    private static func canonicalJSONString(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                output += "\\b"
            case 0x09:
                output += "\\t"
            case 0x0A:
                output += "\\n"
            case 0x0C:
                output += "\\f"
            case 0x0D:
                output += "\\r"
            case 0x22:
                output += "\\\""
            case 0x5C:
                output += "\\\\"
            case 0 ... 0x1F:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }
}
