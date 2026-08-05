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
    let exactIssuedAt: EluV1Timestamp
    let exactExpiresAt: EluV1Timestamp
    let configSemanticHash: String
    let policySourceHash: String
    let decisionHash: String?
    let decisionContextRevision: Int64?
    let sessionIdleTimeoutSeconds: Int
    let sessionMaximumDurationSeconds: Int
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

enum EluV1FlagRestriction: String, Codable, Equatable, Sendable {
    case missing
    case disabled
    case revoked
    case expired
    case featureDisabled
    case malformed
    case conflict
    case terminal
    case wallRollback
    case storageUnavailable
}

struct EluV1FlagAuthorizationSnapshot: Equatable, Sendable {
    let exactConstructorSiteKey: String
    let siteNamespaceDigest: String
    let siteId: String
    let endpoint: URL
    let configRevision: String
    let configIssuedAt: EluV1Timestamp
    let configSemanticHash: String
    let activationGeneration: Int64
    let barrierGeneration: Int64
    let configExpiresAt: EluV1Timestamp
}

enum EluV1FlagAuthorization: Equatable, Sendable {
    case allowed(EluV1FlagAuthorizationSnapshot)
    case restricted(EluV1FlagRestriction)
}

struct EluV1PreparedFlagConfig: Equatable, Sendable {
    let token: String
    let exactConstructorSiteKey: String
    let siteNamespaceDigest: String
    let siteId: String?
    let endpoint: URL?
    let configRevision: String
    let issuedAt: EluV1Timestamp
    let expiresAt: EluV1Timestamp
    let semanticHash: String
    let activationGeneration: Int64
    let restriction: EluV1FlagRestriction?
}

struct EluV1FlagActivationCounter: Equatable, Sendable {
    static let maximum = Int64(9_007_199_254_740_991)

    private(set) var value: Int64
    private(set) var isTerminal: Bool

    init(value: Int64 = 0, isTerminal: Bool = false) {
        precondition((0 ... Self.maximum).contains(value))
        self.value = value
        self.isTerminal = isTerminal
    }

    mutating func advance() -> Int64? {
        guard !isTerminal, value < Self.maximum else {
            isTerminal = true
            return nil
        }
        value += 1
        return value
    }
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
        let canonicalData: Data
        let semanticHash: String
        let policySourceHash: String?
        let trustedEndpoints: [EluV1EndpointRole: URL]?
    }

    private struct PreparedFlagProjection {
        let revision: String
        let issuedAt: EluV1Timestamp
        let expiresAt: EluV1Timestamp
        let status: EluV1ConfigStatus
        let siteId: String?
        let endpoint: URL?
        let flagsEnabled: Bool?
        let semanticHash: String
    }

    /// Closed projection of the config envelope for the flags channel. Known
    /// unrelated channel members may be present, absent, or unauthorized, but
    /// they are never decoded into flag authority.
    private struct FlagConfigProjection: Decodable {
        let revision: String
        let issuedAt: EluV1Timestamp
        let expiresAt: EluV1Timestamp
        let status: EluV1ConfigStatus
        let siteId: String?
        let flagsEndpoint: String?
        let flagsEnabled: Bool?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion
            case revision
            case issuedAt
            case expiresAt
            case status
            case site
            case endpoints
            case privacy
            case features
            case capabilities
            case session
            case limits
            case reason
        }

        init(from decoder: Decoder) throws {
            try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(Int.self, forKey: .schemaVersion)
                == EluV1ConfigDocument.schemaVersion
            else {
                throw EluV1ConfigResolutionError.unsupportedConfigSchemaVersion
            }
            revision = try container.decode(String.self, forKey: .revision)
            guard EluV1Validation.validString(revision, minimum: 1, maximum: 128) else {
                throw EluV1ConfigResolutionError.malformedConfig
            }
            issuedAt = try EluV1Timestamp(
                container.decode(String.self, forKey: .issuedAt)
            )
            expiresAt = try EluV1Timestamp(
                container.decode(String.self, forKey: .expiresAt)
            )
            status = try container.decode(EluV1ConfigStatus.self, forKey: .status)
            let reason = try container.eluDecodeIfPresent(String.self, forKey: .reason)
            if let reason, !EluV1Validation.validString(reason, minimum: 0, maximum: 256) {
                throw EluV1ConfigResolutionError.malformedConfig
            }

            if status == .enabled {
                let site = try container.decode(FlagSiteProjection.self, forKey: .site)
                let endpoints = try container.decode(
                    FlagEndpointsProjection.self,
                    forKey: .endpoints
                )
                let features = try container.decode(
                    FlagFeaturesProjection.self,
                    forKey: .features
                )
                siteId = site.id
                flagsEndpoint = endpoints.flags
                flagsEnabled = features.flags
            } else {
                guard reason != nil,
                      !container.contains(.site),
                      !container.contains(.endpoints)
                else {
                    throw EluV1ConfigResolutionError.malformedConfig
                }
                siteId = nil
                flagsEndpoint = nil
                flagsEnabled = nil
            }
        }
    }

    private struct FlagSiteProjection: Decodable {
        let id: String

        private enum CodingKeys: String, CodingKey, CaseIterable { case id }

        init(from decoder: Decoder) throws {
            try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            guard EluV1Validation.validString(id, minimum: 1, maximum: 128) else {
                throw EluV1ConfigResolutionError.malformedConfig
            }
        }
    }

    private struct FlagEndpointsProjection: Decodable {
        let flags: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case events
            case replay
            case flags
            case assets
        }

        init(from decoder: Decoder) throws {
            try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            flags = try container.decode(String.self, forKey: .flags)
        }
    }

    private struct FlagFeaturesProjection: Decodable {
        let flags: Bool

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case capture
            case replay
            case flags
            case assets
        }

        init(from decoder: Decoder) throws {
            try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            flags = try container.decode(Bool.self, forKey: .flags)
        }
    }

    struct ValidatedCandidateIdentity: Equatable, Sendable {
        let issuedAt: EluV1Timestamp
        let semanticHash: String
        let policySourceHash: String?
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
    private let flagOwner: (siteKey: String, namespaceDigest: String)?
    private var newestBoundary: ConfigBoundary?
    private var activeConfig: PreparedConfig?
    private var lastValidatedCandidateIdentity: ValidatedCandidateIdentity?
    private var pendingFlagConfig: EluV1PreparedFlagConfig?
    private var activeFlagAuthorization: EluV1FlagAuthorizationSnapshot?
    private var flagActivationCounter: EluV1FlagActivationCounter

    init(
        readbackProvenReplayTransports: Set<EluV1ReplayTransportSelection> = []
    ) {
        self.readbackProvenReplayTransports = readbackProvenReplayTransports
        flagOwner = nil
        flagActivationCounter = EluV1FlagActivationCounter()
    }

    init(
        exactConstructorSiteKey: String,
        readbackProvenReplayTransports: Set<EluV1ReplayTransportSelection> = [],
        flagActivationCounter: EluV1FlagActivationCounter = EluV1FlagActivationCounter()
    ) throws {
        self.readbackProvenReplayTransports = readbackProvenReplayTransports
        flagOwner = (
            exactConstructorSiteKey,
            try EluV1SiteNamespace.digest(exactConstructorSiteKey: exactConstructorSiteKey)
        )
        self.flagActivationCounter = flagActivationCounter
    }

    /// Phase one of flag activation. It invalidates the owner-local generation
    /// immediately and returns a closed candidate without publishing allow
    /// authority. The flag client must durably apply its barrier before commit.
    func prepareFlagConfig(configData: Data, now: Date) throws -> EluV1PreparedFlagConfig {
        lock.lock()
        defer { lock.unlock() }

        guard let flagOwner else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
        guard let activationGeneration = flagActivationCounter.advance() else {
            activeFlagAuthorization = nil
            pendingFlagConfig = nil
            throw EluV1ConfigResolutionError.flagActivationGenerationExhausted
        }
        activeFlagAuthorization = nil
        pendingFlagConfig = nil

        do {
            try Self.validateClock(now)
            let prepared = try Self.prepareFlagProjection(configData)
            let restriction: EluV1FlagRestriction?
            switch prepared.status {
            case .disabled:
                restriction = .disabled
            case .revoked:
                restriction = .revoked
            case .enabled:
                if prepared.expiresAt.isAtOrBefore(now) {
                    restriction = .expired
                } else if prepared.flagsEnabled != true {
                    restriction = .featureDisabled
                } else {
                    restriction = nil
                }
            }
            let siteId = prepared.siteId
            let endpoint = prepared.endpoint
            guard restriction != nil || (siteId != nil && endpoint != nil) else {
                throw EluV1ConfigResolutionError.malformedConfig
            }
            let candidate = EluV1PreparedFlagConfig(
                token: UUID().uuidString,
                exactConstructorSiteKey: flagOwner.siteKey,
                siteNamespaceDigest: flagOwner.namespaceDigest,
                siteId: siteId,
                endpoint: endpoint,
                configRevision: prepared.revision,
                issuedAt: prepared.issuedAt,
                expiresAt: prepared.expiresAt,
                semanticHash: prepared.semanticHash,
                activationGeneration: activationGeneration,
                restriction: restriction
            )
            pendingFlagConfig = candidate
            return candidate
        } catch {
            activeFlagAuthorization = nil
            pendingFlagConfig = nil
            throw error
        }
    }

    /// Phase three of flag activation. Only the exact pending token can be
    /// published, and only after the store returns its durable barrier token.
    func commitFlagConfig(
        _ candidate: EluV1PreparedFlagConfig,
        barrierGeneration: Int64
    ) -> EluV1FlagAuthorization {
        lock.lock()
        defer { lock.unlock() }
        guard barrierGeneration >= 0,
              barrierGeneration <= 9_007_199_254_740_991,
              !flagActivationCounter.isTerminal,
              pendingFlagConfig == candidate,
              candidate.activationGeneration == flagActivationCounter.value
        else {
            activeFlagAuthorization = nil
            pendingFlagConfig = nil
            return .restricted(.storageUnavailable)
        }
        pendingFlagConfig = nil
        if let restriction = candidate.restriction {
            activeFlagAuthorization = nil
            return .restricted(restriction)
        }
        guard let siteId = candidate.siteId, let endpoint = candidate.endpoint else {
            activeFlagAuthorization = nil
            return .restricted(.malformed)
        }
        let snapshot = EluV1FlagAuthorizationSnapshot(
            exactConstructorSiteKey: candidate.exactConstructorSiteKey,
            siteNamespaceDigest: candidate.siteNamespaceDigest,
            siteId: siteId,
            endpoint: endpoint,
            configRevision: candidate.configRevision,
            configIssuedAt: candidate.issuedAt,
            configSemanticHash: candidate.semanticHash,
            activationGeneration: candidate.activationGeneration,
            barrierGeneration: barrierGeneration,
            configExpiresAt: candidate.expiresAt
        )
        activeFlagAuthorization = snapshot
        return .allowed(snapshot)
    }

    func rejectPendingFlagConfig(_ candidate: EluV1PreparedFlagConfig?) {
        lock.lock()
        defer { lock.unlock() }
        if candidate == nil || pendingFlagConfig == candidate {
            pendingFlagConfig = nil
        }
        activeFlagAuthorization = nil
    }

    func currentFlagAuthorization(now: Date) -> EluV1FlagAuthorization {
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            activeFlagAuthorization = nil
            return .restricted(.wallRollback)
        }
        guard let snapshot = activeFlagAuthorization else {
            return .restricted(.missing)
        }
        guard !snapshot.configExpiresAt.isAtOrBefore(now) else {
            activeFlagAuthorization = nil
            _ = flagActivationCounter.advance()
            return .restricted(.expired)
        }
        return .allowed(snapshot)
    }

    func update(configData: Data, now: Date) throws -> EluV1ConfigUpdateResult {
        lock.lock()
        defer { lock.unlock() }

        do {
            lastValidatedCandidateIdentity = nil
            try Self.validateClock(now)
            let prepared = try Self.prepareConfig(configData)
            lastValidatedCandidateIdentity = ValidatedCandidateIdentity(
                issuedAt: prepared.document.issuedAt,
                semanticHash: prepared.semanticHash,
                policySourceHash: prepared.policySourceHash
            )
            expireActiveConfigIfNeeded(now: now)

            if var boundary = newestBoundary {
                if prepared.document.issuedAt < boundary.prepared.document.issuedAt {
                    return .stale(revision: prepared.document.revision)
                }

                if prepared.document.issuedAt == boundary.prepared.document.issuedAt {
                    guard prepared.semanticHash == boundary.prepared.semanticHash,
                          prepared.canonicalData == boundary.prepared.canonicalData,
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

    func validatedCandidateIdentity() -> ValidatedCandidateIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return lastValidatedCandidateIdentity
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
              let session = config.session,
              let policySourceHash = active.policySourceHash,
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
            decisionHash: String? = nil,
            decisionContextRevision: Int64? = nil,
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
                exactIssuedAt: config.issuedAt,
                exactExpiresAt: config.expiresAt,
                configSemanticHash: active.semanticHash,
                policySourceHash: policySourceHash,
                decisionHash: decisionHash,
                decisionContextRevision: decisionContextRevision,
                sessionIdleTimeoutSeconds: session.idleTimeoutSeconds,
                sessionMaximumDurationSeconds: session.maximumDurationSeconds,
                endpoints: EluV1AuthorizedEndpointSet(authorized),
                captureAuthorization: capture,
                replayAuthorization: replay
            )
        }

        func invalidPrivacy(
            _ reason: EluV1PrivacyInvalidReason,
            contextRevision: Int64? = nil
        ) -> EluV1ConfigResolution {
            resolution(
                capture: .invalid(reason),
                replay: .invalid(reason),
                decisionContextRevision: contextRevision
            )
        }

        guard let effectivePrivacyStateData else {
            return invalidPrivacy(.missingState)
        }

        let effectivePrivacy: EluV1EffectivePrivacyState
        let decisionHash: String
        do {
            let decoded = try Self.decodePrivacyState(effectivePrivacyStateData)
            effectivePrivacy = decoded.state
            decisionHash = try Self.verifyEffectivePolicyHash(
                decoded.document,
                expected: effectivePrivacy.effectivePolicyHash
            )
        } catch {
            return invalidPrivacy(Self.sharedPrivacyInvalidReason(for: error))
        }

        guard effectivePrivacy.policyRevision == privacyPolicy.revision else {
            return invalidPrivacy(
                .policyRevisionMismatch,
                contextRevision: effectivePrivacy.contextRevision
            )
        }
        guard effectivePrivacy.contextRevision == identity.identity.contextRevision else {
            return invalidPrivacy(
                .contextRevisionMismatch,
                contextRevision: effectivePrivacy.contextRevision
            )
        }
        guard effectivePrivacy.identityOptedOut == identity.identity.optedOut else {
            return invalidPrivacy(
                .identityOptStateMismatch,
                contextRevision: effectivePrivacy.contextRevision
            )
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
            decisionHash: decisionHash,
            decisionContextRevision: effectivePrivacy.contextRevision,
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
        let (document, strictDocument) = try decodeConfig(data)
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
            canonicalData: strictDocument.canonicalData,
            semanticHash: EluV1StrictCanonicalJSON.hash(strictDocument.canonicalData),
            policySourceHash: try strictDocument.canonicalObjectProperty("privacy").map {
                EluV1StrictCanonicalJSON.hash($0)
            },
            trustedEndpoints: trustedEndpoints
        )
    }

    /// Flags consume only their own endpoint role. Known unrelated channel
    /// values remain part of the semantic document when present, but are not
    /// required or interpreted and cannot grant or deny flag authority.
    private static func prepareFlagProjection(_ data: Data) throws -> PreparedFlagProjection {
        let (projection, strictDocument) = try decodeFlagProjection(data)
        guard projection.issuedAt < projection.expiresAt else {
            throw EluV1ConfigResolutionError.invalidConfigValidityWindow
        }
        let endpoint = try projection.flagsEndpoint.map {
            try validateEndpoint($0, role: .flags)
        }
        return PreparedFlagProjection(
            revision: projection.revision,
            issuedAt: projection.issuedAt,
            expiresAt: projection.expiresAt,
            status: projection.status,
            siteId: projection.siteId,
            endpoint: endpoint,
            flagsEnabled: projection.flagsEnabled,
            semanticHash: EluV1StrictCanonicalJSON.hash(strictDocument.canonicalData),
        )
    }

    private static func decodeFlagProjection(_ data: Data) throws
        -> (FlagConfigProjection, EluV1StrictCanonicalJSON.Document)
    {
        guard data.count <= maximumConfigBytes else {
            throw EluV1ConfigResolutionError.configPayloadTooLarge
        }
        do {
            let strictDocument = try EluV1StrictCanonicalJSON.parse(data)
            guard case .object = strictDocument.value else {
                throw EluV1ConfigResolutionError.malformedConfig
            }
            return (
                try JSONDecoder().decode(
                    FlagConfigProjection.self,
                    from: strictDocument.canonicalData
                ),
                strictDocument
            )
        } catch let error as EluV1ConfigResolutionError {
            throw error
        } catch {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }

    private static func decodeConfig(_ data: Data) throws
        -> (EluV1ConfigDocument, EluV1StrictCanonicalJSON.Document)
    {
        guard data.count <= maximumConfigBytes else {
            throw EluV1ConfigResolutionError.configPayloadTooLarge
        }
        do {
            let strictDocument = try EluV1StrictCanonicalJSON.parse(data)
            guard case .object = strictDocument.value else {
                throw EluV1ConfigResolutionError.malformedConfig
            }
            return (
                try JSONDecoder().decode(
                    EluV1ConfigDocument.self,
                    from: strictDocument.canonicalData
                ),
                strictDocument
            )
        } catch let error as EluV1ConfigResolutionError {
            throw error
        } catch {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }

    private static func decodePrivacyState(_ data: Data) throws
        -> (state: EluV1EffectivePrivacyState, document: EluV1StrictCanonicalJSON.Document)
    {
        guard data.count <= maximumPrivacyStateBytes else {
            throw EluV1ConfigResolutionError.privacyPayloadTooLarge
        }
        do {
            let strictDocument = try EluV1StrictCanonicalJSON.parse(data)
            guard case .object = strictDocument.value else {
                throw EluV1ConfigResolutionError.malformedPrivacyState
            }
            return (
                try JSONDecoder().decode(
                    EluV1EffectivePrivacyState.self,
                    from: strictDocument.canonicalData
                ),
                strictDocument
            )
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

    @discardableResult
    private static func verifyEffectivePolicyHash(
        _ document: EluV1StrictCanonicalJSON.Document,
        expected: String
    ) throws -> String {
        let actual = EluV1StrictCanonicalJSON.hash(
            try document.canonicalRemovingObjectProperty("effectivePolicyHash")
        )
        guard actual == expected else {
            throw EluV1ConfigResolutionError.invalidEffectivePolicyHash
        }
        return actual
    }

    /// Shared by privacy evaluation and conformance tests. Computing a hash
    /// does not validate or authorize the state.
    static func computedEffectivePolicyHash(for data: Data) throws -> String {
        do {
            let document = try EluV1StrictCanonicalJSON.parse(data)
            guard case .object = document.value,
                  case let .string(hashUnits)? = try document.objectProperty("effectivePolicyHash")
            else {
                throw EluV1ConfigResolutionError.malformedPrivacyState
            }
            let rawHash = String(decoding: hashUnits, as: UTF16.self)
            guard EluV1Validation.validPolicyHash(rawHash) else {
                throw EluV1ConfigResolutionError.malformedPrivacyState
            }
            return EluV1StrictCanonicalJSON.hash(
                try document.canonicalRemovingObjectProperty("effectivePolicyHash")
            )
        } catch {
            throw EluV1ConfigResolutionError.malformedPrivacyState
        }
    }
}
