import Foundation

enum EluV1ConfigStatus: String, Decodable, Equatable, Sendable {
    case enabled
    case disabled
    case revoked
}

enum EluV1EndpointRole: String, CaseIterable, Hashable, Sendable {
    case events
    case replay
    case flags
    case assets
}

enum EluV1ConfigResolutionError: Error, Equatable, Sendable {
    case configPayloadTooLarge
    case privacyPayloadTooLarge
    case malformedConfig
    case malformedPrivacyState
    case unsupportedConfigSchemaVersion
    case unsupportedPrivacyPolicySchemaVersion
    case unsupportedPrivacyStateSchemaVersion
    case invalidConfigValidityWindow
    case expiredConfig
    case invalidClock
    case missingActiveConfig
    case conflictingConfigAtIssuedAt
    case inactiveConfig(EluV1ConfigStatus)
    case untrustedEndpoint(EluV1EndpointRole)
    case privacyPolicyRevisionMismatch
    case privacyContextRevisionMismatch
    case privacyOptStateMismatch
    case invalidEffectivePolicyHash
    case effectiveMaskingIsWeakerThanPolicy
    case inconsistentCaptureAuthorization
    case inconsistentReplayAuthorization
}

struct EluV1ConfigDocument: Decodable, Sendable {
    static let schemaVersion = 1

    let revision: String
    let issuedAt: EluV1Timestamp
    let expiresAt: EluV1Timestamp
    let status: EluV1ConfigStatus
    let site: EluV1Site?
    let endpoints: EluV1RawEndpoints?
    let privacy: EluV1PrivacyPolicy?
    let features: EluV1Features?
    let capabilities: EluV1Capabilities?
    let session: EluV1SessionPolicy?
    let limits: EluV1Limits?
    let reason: String?

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
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw EluV1ConfigResolutionError.unsupportedConfigSchemaVersion
        }

        revision = try container.decode(String.self, forKey: .revision)
        guard EluV1Validation.validString(revision, minimum: 1, maximum: 128) else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
        issuedAt = try EluV1Timestamp(container.decode(String.self, forKey: .issuedAt))
        expiresAt = try EluV1Timestamp(container.decode(String.self, forKey: .expiresAt))
        status = try container.decode(EluV1ConfigStatus.self, forKey: .status)
        site = try container.eluDecodeIfPresent(EluV1Site.self, forKey: .site)
        endpoints = try container.eluDecodeIfPresent(EluV1RawEndpoints.self, forKey: .endpoints)
        privacy = try container.eluDecodeIfPresent(EluV1PrivacyPolicy.self, forKey: .privacy)
        features = try container.eluDecodeIfPresent(EluV1Features.self, forKey: .features)
        capabilities = try container.eluDecodeIfPresent(EluV1Capabilities.self, forKey: .capabilities)
        session = try container.eluDecodeIfPresent(EluV1SessionPolicy.self, forKey: .session)
        limits = try container.eluDecodeIfPresent(EluV1Limits.self, forKey: .limits)
        reason = try container.eluDecodeIfPresent(String.self, forKey: .reason)
        if let reason, !EluV1Validation.validString(reason, minimum: 0, maximum: 256) {
            throw EluV1ConfigResolutionError.malformedConfig
        }

        switch status {
        case .enabled:
            guard site != nil,
                  endpoints != nil,
                  privacy != nil,
                  features != nil,
                  capabilities != nil,
                  session != nil,
                  limits != nil
            else {
                throw EluV1ConfigResolutionError.malformedConfig
            }
        case .disabled, .revoked:
            guard reason != nil, site == nil, endpoints == nil else {
                throw EluV1ConfigResolutionError.malformedConfig
            }
        }

        // These mirror config.schema.json's conditional requirements. The
        // surrounding object is not itself required by the condition, which
        // matters for otherwise-valid disabled/revoked documents.
        if features?.replay == true {
            if let endpoints, endpoints.replay == nil {
                throw EluV1ConfigResolutionError.malformedConfig
            }
            if let capabilities,
               capabilities.replay.acceptedCodecs.isEmpty
                   || capabilities.replay.acceptedCompressions.isEmpty
            {
                throw EluV1ConfigResolutionError.malformedConfig
            }
        }
        if features?.assets == true, let endpoints, endpoints.assets == nil {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }
}

struct EluV1Site: Decodable, Sendable {
    let id: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        guard EluV1Validation.validString(id, minimum: 1, maximum: 128) else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }
}

struct EluV1RawEndpoints: Decodable, Sendable {
    let events: String
    let replay: String?
    let flags: String
    let assets: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case events
        case replay
        case flags
        case assets
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decode(String.self, forKey: .events)
        replay = try container.eluDecodeIfPresent(String.self, forKey: .replay)
        flags = try container.decode(String.self, forKey: .flags)
        assets = try container.eluDecodeIfPresent(String.self, forKey: .assets)
        for endpoint in [events, replay, flags, assets].compactMap({ $0 }) {
            guard EluV1Validation.isAbsoluteHTTPSURI(endpoint) else {
                throw EluV1ConfigResolutionError.malformedConfig
            }
        }
    }
}

struct EluV1Features: Decodable, Sendable {
    let capture: Bool
    let replay: Bool
    let flags: Bool
    let assets: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case capture
        case replay
        case flags
        case assets
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capture = try container.decode(Bool.self, forKey: .capture)
        replay = try container.decode(Bool.self, forKey: .replay)
        flags = try container.decode(Bool.self, forKey: .flags)
        assets = try container.decode(Bool.self, forKey: .assets)
    }
}

struct EluV1Capabilities: Decodable, Sendable {
    let replay: EluV1ReplayCapabilities

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case replay
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replay = try container.decode(EluV1ReplayCapabilities.self, forKey: .replay)
    }
}

struct EluV1ReplayCapabilities: Decodable, Sendable {
    let acceptedCodecs: [String]
    let acceptedCompressions: [EluV1Compression]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case acceptedCodecs
        case acceptedCompressions
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        acceptedCodecs = try container.decode([String].self, forKey: .acceptedCodecs)
        acceptedCompressions = try container.decode(
            [EluV1Compression].self,
            forKey: .acceptedCompressions
        )
        guard acceptedCodecs.count <= 32,
              Set(acceptedCodecs).count == acceptedCodecs.count,
              acceptedCodecs.allSatisfy(EluV1Validation.validCapabilityIdentifier),
              acceptedCompressions.count <= 8,
              Set(acceptedCompressions).count == acceptedCompressions.count
        else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }
}

enum EluV1Compression: String, Decodable, Hashable, Sendable {
    case none
    case gzip
}

struct EluV1SessionPolicy: Decodable, Sendable {
    let idleTimeoutSeconds: Int
    let maximumDurationSeconds: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case idleTimeoutSeconds
        case maximumDurationSeconds
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idleTimeoutSeconds = try container.decode(Int.self, forKey: .idleTimeoutSeconds)
        maximumDurationSeconds = try container.decode(Int.self, forKey: .maximumDurationSeconds)
        guard (60 ... 36_000).contains(idleTimeoutSeconds), maximumDurationSeconds == 86_400 else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }
}

struct EluV1Limits: Decodable, Sendable {
    let eventBatchCount: Int
    let eventBatchBytes: Int
    let replayChunkBytes: Int
    let queueBytes: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case eventBatchCount
        case eventBatchBytes
        case replayChunkBytes
        case queueBytes
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventBatchCount = try container.decode(Int.self, forKey: .eventBatchCount)
        eventBatchBytes = try container.decode(Int.self, forKey: .eventBatchBytes)
        replayChunkBytes = try container.decode(Int.self, forKey: .replayChunkBytes)
        queueBytes = try container.decode(Int.self, forKey: .queueBytes)
        guard (1 ... 1_000).contains(eventBatchCount),
              (1_024 ... 10_485_760).contains(eventBatchBytes),
              (1_024 ... 52_428_800).contains(replayChunkBytes),
              (1_024 ... 268_435_456).contains(queueBytes)
        else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }
}

struct EluV1PrivacyPolicy: Decodable, Sendable {
    static let schemaVersion = 1

    let revision: String
    let capture: EluV1CapturePolicy
    let replay: EluV1ReplayPolicy
    let masking: EluV1MaskingPolicy
    let regionPolicy: EluV1RegionPolicy

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case revision
        case capture
        case replay
        case masking
        case regionPolicy
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw EluV1ConfigResolutionError.unsupportedPrivacyPolicySchemaVersion
        }
        revision = try container.decode(String.self, forKey: .revision)
        guard EluV1Validation.validString(revision, minimum: 1, maximum: 128) else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
        capture = try container.decode(EluV1CapturePolicy.self, forKey: .capture)
        replay = try container.decode(EluV1ReplayPolicy.self, forKey: .replay)
        masking = try container.decode(EluV1MaskingPolicy.self, forKey: .masking)
        regionPolicy = try container.decode(EluV1RegionPolicy.self, forKey: .regionPolicy)
    }
}

struct EluV1CapturePolicy: Decodable, Sendable {
    let enabled: Bool
    let reason: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled
        case reason
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        reason = try container.eluDecodeIfPresent(String.self, forKey: .reason)
        if let reason, !EluV1Validation.validString(reason, minimum: 0, maximum: 256) {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }
}

struct EluV1ReplayPolicy: Decodable, Sendable {
    let enabled: Bool
    let reason: String?
    let sampleRate: Double
    let minimumDurationSeconds: Int
    let maximumDurationSeconds: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled
        case reason
        case sampleRate
        case minimumDurationSeconds
        case maximumDurationSeconds
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        reason = try container.eluDecodeIfPresent(String.self, forKey: .reason)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        minimumDurationSeconds = try container.decode(Int.self, forKey: .minimumDurationSeconds)
        maximumDurationSeconds = try container.decode(Int.self, forKey: .maximumDurationSeconds)
        guard reason.map({ EluV1Validation.validString($0, minimum: 0, maximum: 256) }) ?? true,
              sampleRate.isFinite,
              (0 ... 1).contains(sampleRate),
              (0 ... 3_600).contains(minimumDurationSeconds),
              (0 ... 86_400).contains(maximumDurationSeconds)
        else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }
}

enum EluV1MaskingLevel: String, Decodable, Equatable, Sendable {
    case all
    case sensitive
}

enum EluV1ImagePolicy: String, Decodable, Equatable, Sendable {
    case block
    case allow
}

struct EluV1MaskingPolicy: Decodable, Sendable {
    let text: EluV1MaskingLevel
    let inputs: EluV1MaskingLevel
    let images: EluV1ImagePolicy
    let secureInputsMasked: Bool
    let platformRules: [EluV1PlatformRule]?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case text
        case inputs
        case images
        case secureInputsMasked
        case platformRules
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(EluV1MaskingLevel.self, forKey: .text)
        inputs = try container.decode(EluV1MaskingLevel.self, forKey: .inputs)
        images = try container.decode(EluV1ImagePolicy.self, forKey: .images)
        secureInputsMasked = try container.decode(Bool.self, forKey: .secureInputsMasked)
        platformRules = try container.eluDecodeIfPresent([EluV1PlatformRule].self, forKey: .platformRules)
        guard secureInputsMasked, (platformRules?.count ?? 0) <= 128 else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }
}

enum EluV1Platform: String, Decodable, Equatable, Sendable {
    case browser
    case android
    case ios
}

enum EluV1PlatformRuleAction: String, Decodable, Sendable {
    case mask
    case block
}

struct EluV1PlatformRule: Decodable, Sendable {
    let platform: EluV1Platform
    let action: EluV1PlatformRuleAction
    let targetDialect: String
    let target: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case platform
        case action
        case targetDialect
        case target
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platform = try container.decode(EluV1Platform.self, forKey: .platform)
        action = try container.decode(EluV1PlatformRuleAction.self, forKey: .action)
        targetDialect = try container.decode(String.self, forKey: .targetDialect)
        target = try container.decode(String.self, forKey: .target)
        guard EluV1Validation.validCapabilityIdentifier(targetDialect),
              EluV1Validation.validString(target, minimum: 1, maximum: 512)
        else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }
}

enum EluV1RegionMode: String, Decodable, Equatable, Sendable {
    case allow
    case block
    case blockEuOnDevice = "block-eu-on-device"
}

struct EluV1RegionPolicy: Decodable, Sendable {
    static let evaluator = "elu-eu-timezone-v1"

    let mode: EluV1RegionMode
    let evaluator: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mode
        case evaluator
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(EluV1RegionMode.self, forKey: .mode)
        evaluator = try container.eluDecodeIfPresent(String.self, forKey: .evaluator)
        guard evaluator == nil || evaluator == Self.evaluator,
              mode != .blockEuOnDevice || evaluator == Self.evaluator
        else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
    }
}

struct EluV1EffectivePrivacyState: Decodable, Sendable {
    static let schemaVersion = 1

    let policyRevision: String
    let contextRevision: Int64
    let onDeviceDecision: EluV1OnDeviceDecision
    let captureAllowed: Bool
    let replayAllowed: Bool
    let replaySampled: Bool
    let identityOptedOut: Bool
    let maskingValidated: Bool
    let replaySessionEligible: Bool
    let replayBudgetRemainingSeconds: Int
    let replayTransport: EluV1ReplayTransport?
    let effectiveMasking: EluV1EffectiveMasking
    let effectivePolicyHash: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case policyRevision
        case contextRevision
        case onDeviceDecision
        case captureAllowed
        case replayAllowed
        case replaySampled
        case identityOptedOut
        case maskingValidated
        case replaySessionEligible
        case replayBudgetRemainingSeconds
        case replayTransport
        case effectiveMasking
        case effectivePolicyHash
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw EluV1ConfigResolutionError.unsupportedPrivacyStateSchemaVersion
        }
        policyRevision = try container.decode(String.self, forKey: .policyRevision)
        contextRevision = try container.decode(Int64.self, forKey: .contextRevision)
        onDeviceDecision = try container.decode(EluV1OnDeviceDecision.self, forKey: .onDeviceDecision)
        captureAllowed = try container.decode(Bool.self, forKey: .captureAllowed)
        replayAllowed = try container.decode(Bool.self, forKey: .replayAllowed)
        replaySampled = try container.decode(Bool.self, forKey: .replaySampled)
        identityOptedOut = try container.decode(Bool.self, forKey: .identityOptedOut)
        maskingValidated = try container.decode(Bool.self, forKey: .maskingValidated)
        replaySessionEligible = try container.decode(Bool.self, forKey: .replaySessionEligible)
        replayBudgetRemainingSeconds = try container.decode(
            Int.self,
            forKey: .replayBudgetRemainingSeconds
        )
        if container.contains(.replayTransport) {
            replayTransport = try container.decodeIfPresent(
                EluV1ReplayTransport.self,
                forKey: .replayTransport
            )
        } else {
            throw EluV1ConfigResolutionError.malformedPrivacyState
        }
        effectiveMasking = try container.decode(EluV1EffectiveMasking.self, forKey: .effectiveMasking)
        effectivePolicyHash = try container.decode(String.self, forKey: .effectivePolicyHash)

        guard EluV1Validation.validString(policyRevision, minimum: 1, maximum: 128),
              contextRevision >= 0,
              (0 ... 86_400).contains(replayBudgetRemainingSeconds),
              EluV1Validation.validPolicyHash(effectivePolicyHash)
        else {
            throw EluV1ConfigResolutionError.malformedPrivacyState
        }
    }
}

enum EluV1Decision: String, Decodable, Equatable, Sendable {
    case allow
    case block
    case unknown
}

enum EluV1DecisionSource: String, Decodable, Sendable {
    case notEvaluated = "not-evaluated"
    case deviceRegion = "device-region"
    case localConsent = "local-consent"
    case remoteKillSwitch = "remote-kill-switch"
}

struct EluV1OnDeviceDecision: Decodable, Sendable {
    let decision: EluV1Decision
    let source: EluV1DecisionSource
    let reason: String?
    let evaluatedAt: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case decision
        case source
        case reason
        case evaluatedAt
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(EluV1Decision.self, forKey: .decision)
        source = try container.decode(EluV1DecisionSource.self, forKey: .source)
        reason = try container.eluDecodeIfPresent(String.self, forKey: .reason)
        evaluatedAt = try container.eluDecodeIfPresent(String.self, forKey: .evaluatedAt)
        guard reason.map({ EluV1Validation.validString($0, minimum: 0, maximum: 256) }) ?? true else {
            throw EluV1ConfigResolutionError.malformedPrivacyState
        }
        if let evaluatedAt {
            _ = try EluV1Timestamp(evaluatedAt)
        }
    }
}

struct EluV1ReplayTransport: Decodable, Sendable {
    let codec: String
    let compression: EluV1Compression
    let advertised: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case codec
        case compression
        case advertised
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codec = try container.decode(String.self, forKey: .codec)
        compression = try container.decode(EluV1Compression.self, forKey: .compression)
        advertised = try container.decode(Bool.self, forKey: .advertised)
        guard EluV1Validation.validCapabilityIdentifier(codec), advertised else {
            throw EluV1ConfigResolutionError.malformedPrivacyState
        }
    }
}

struct EluV1EffectiveMasking: Decodable, Sendable {
    let text: EluV1MaskingLevel
    let inputs: EluV1MaskingLevel
    let images: EluV1ImagePolicy
    let secureInputsMasked: Bool
    let platformFallbackApplied: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case text
        case inputs
        case images
        case secureInputsMasked
        case platformFallbackApplied
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(EluV1MaskingLevel.self, forKey: .text)
        inputs = try container.decode(EluV1MaskingLevel.self, forKey: .inputs)
        images = try container.decode(EluV1ImagePolicy.self, forKey: .images)
        secureInputsMasked = try container.decode(Bool.self, forKey: .secureInputsMasked)
        platformFallbackApplied = try container.decode(Bool.self, forKey: .platformFallbackApplied)
        guard secureInputsMasked else {
            throw EluV1ConfigResolutionError.malformedPrivacyState
        }
    }
}

struct EluV1Timestamp: Comparable, Sendable {
    let date: Date
    private let baseSecond: Int64
    private let isLeapSecond: Bool
    private let fractionalDigits: [UInt8]

    init(_ value: String) throws {
        guard let parsed = EluV1Validation.parseRFC3339(value) else {
            throw EluV1ConfigResolutionError.malformedConfig
        }
        date = parsed.date
        baseSecond = parsed.baseSecond
        isLeapSecond = parsed.isLeapSecond
        fractionalDigits = parsed.fractionalDigits
    }

    static func < (lhs: EluV1Timestamp, rhs: EluV1Timestamp) -> Bool {
        if lhs.baseSecond != rhs.baseSecond {
            return lhs.baseSecond < rhs.baseSecond
        }
        if lhs.isLeapSecond != rhs.isLeapSecond {
            return !lhs.isLeapSecond
        }
        let count = max(lhs.fractionalDigits.count, rhs.fractionalDigits.count)
        for index in 0 ..< count {
            let left = index < lhs.fractionalDigits.count ? lhs.fractionalDigits[index] : 0
            let right = index < rhs.fractionalDigits.count ? rhs.fractionalDigits[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: EluV1Timestamp, rhs: EluV1Timestamp) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// Compares the exact RFC 3339 instant with Foundation's exact binary64
    /// clock value. Converting the config timestamp to `Date` first would lose
    /// arbitrary fractional digits and would map a leap second past midnight.
    func isAtOrBefore(_ clock: Date) -> Bool {
        // Date stores its binary64 value relative to 2001. Converting it to
        // 1970 first can round away one bit at current dates, so move the
        // integral config second onto Date's native reference scale instead.
        let clockSeconds = clock.timeIntervalSinceReferenceDate
        let clockParts = Self.exactClockParts(clockSeconds)
        let clockWholeSecond = clockParts.wholeSecond
        let configWholeSecond = Double(baseSecond - 978_307_200)

        if configWholeSecond != clockWholeSecond {
            return configWholeSecond < clockWholeSecond
        }

        // A POSIX Date in this base second describes the ordinary :59 second.
        // The RFC 3339 leap second follows it and precedes the next whole second.
        if isLeapSecond {
            return false
        }

        let clockFractionDigits = clockParts.fractionalDigits
        let count = max(fractionalDigits.count, clockFractionDigits.count)
        for index in 0 ..< count {
            let configDigit = index < fractionalDigits.count ? fractionalDigits[index] : 0
            let clockDigit = index < clockFractionDigits.count ? clockFractionDigits[index] : 0
            if configDigit != clockDigit {
                return configDigit < clockDigit
            }
        }
        return true
    }

    /// Floors the exact duration from `earlier` to this timestamp to whole
    /// nanoseconds. Leap-second windows and unrepresentable durations fail
    /// closed instead of being rounded into a longer authority lease.
    func floorNanoseconds(since earlier: EluV1Timestamp) -> UInt64? {
        guard !isLeapSecond, !earlier.isLeapSecond else { return nil }
        return Self.floorNanoseconds(
            laterWholeSecond: baseSecond,
            laterFractionDigits: fractionalDigits,
            earlierWholeSecond: earlier.baseSecond,
            earlierFractionDigits: earlier.fractionalDigits
        )
    }

    /// Floors the exact duration from Foundation's binary64 wall-clock sample
    /// to this timestamp without first rounding this timestamp through Date.
    func floorNanoseconds(after clock: Date) -> UInt64? {
        guard !isLeapSecond, clock.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }
        let clockParts = Self.exactClockParts(clock.timeIntervalSinceReferenceDate)
        guard let clockWhole = Int64(exactly: clockParts.wholeSecond),
              clockWhole <= Int64.max - 978_307_200
        else {
            return nil
        }
        return Self.floorNanoseconds(
            laterWholeSecond: baseSecond,
            laterFractionDigits: fractionalDigits,
            earlierWholeSecond: clockWhole + 978_307_200,
            earlierFractionDigits: clockParts.fractionalDigits
        )
    }

    private static func floorNanoseconds(
        laterWholeSecond: Int64,
        laterFractionDigits: [UInt8],
        earlierWholeSecond: Int64,
        earlierFractionDigits: [UInt8]
    ) -> UInt64? {
        let (wholeDelta, wholeOverflow) = laterWholeSecond.subtractingReportingOverflow(
            earlierWholeSecond
        )
        guard !wholeOverflow else { return nil }

        let later = nanosecondParts(laterFractionDigits)
        let earlier = nanosecondParts(earlierFractionDigits)
        let (scaledWhole, scaledOverflow) = wholeDelta.multipliedReportingOverflow(by: 1_000_000_000)
        guard !scaledOverflow else { return nil }
        let (withNanos, nanosOverflow) = scaledWhole.addingReportingOverflow(
            later.nanoseconds - earlier.nanoseconds
        )
        guard !nanosOverflow else { return nil }

        let remainderComparison = compareDecimalDigits(later.remainder, earlier.remainder)
        let floorValue: Int64
        if remainderComparison < 0 {
            guard withNanos > Int64.min else { return nil }
            floorValue = withNanos - 1
        } else {
            floorValue = withNanos
        }
        guard floorValue >= 0 else { return nil }
        return UInt64(floorValue)
    }

    private static func nanosecondParts(
        _ digits: [UInt8]
    ) -> (nanoseconds: Int64, remainder: ArraySlice<UInt8>) {
        var nanoseconds: Int64 = 0
        for index in 0 ..< 9 {
            nanoseconds *= 10
            if index < digits.count {
                nanoseconds += Int64(digits[index])
            }
        }
        return (
            nanoseconds,
            digits.count > 9 ? digits[9...] : digits[digits.endIndex ..< digits.endIndex]
        )
    }

    private static func compareDecimalDigits(
        _ lhs: ArraySlice<UInt8>,
        _ rhs: ArraySlice<UInt8>
    ) -> Int {
        let count = max(lhs.count, rhs.count)
        for index in 0 ..< count {
            let left = index < lhs.count ? lhs[lhs.index(lhs.startIndex, offsetBy: index)] : 0
            let right = index < rhs.count ? rhs[rhs.index(rhs.startIndex, offsetBy: index)] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    private static func exactClockParts(
        _ seconds: Double
    ) -> (wholeSecond: Double, fractionalDigits: [UInt8]) {
        if seconds >= 0 {
            let wholeSecond = floor(seconds)
            return (
                wholeSecond,
                exactDecimalDigits(forBinaryFraction: seconds - wholeSecond)
            )
        }

        let magnitude = -seconds
        let magnitudeWholeSecond = floor(magnitude)
        let magnitudeFraction = magnitude - magnitudeWholeSecond
        guard magnitudeFraction > 0 else {
            return (-magnitudeWholeSecond, [])
        }

        // For a negative non-integral value, floor(-x) is -(floor(x) + 1)
        // and its positive fraction is 1 minus x's exact binary fraction.
        var fractionalDigits = exactDecimalDigits(forBinaryFraction: magnitudeFraction)
        var carry: UInt8 = 1
        for index in fractionalDigits.indices.reversed() {
            let value = 9 - fractionalDigits[index] + carry
            fractionalDigits[index] = value % 10
            carry = value / 10
        }
        while fractionalDigits.last == 0 {
            fractionalDigits.removeLast()
        }
        return (-magnitudeWholeSecond - 1, fractionalDigits)
    }

    /// Every finite binary64 fraction has a terminating decimal expansion.
    /// Build that expansion without rounding so a one-nanosecond config
    /// boundary cannot collapse onto a coarser `Date` value.
    private static func exactDecimalDigits(forBinaryFraction value: Double) -> [UInt8] {
        guard value > 0 else { return [] }

        let bits = value.bitPattern
        let fractionMask = (UInt64(1) << 52) - 1
        let storedFraction = bits & fractionMask
        let storedExponent = Int((bits >> 52) & 0x7FF)

        var significand: UInt64
        var denominatorPower: Int
        if storedExponent == 0 {
            significand = storedFraction
            denominatorPower = 1_074
        } else {
            significand = (UInt64(1) << 52) | storedFraction
            denominatorPower = 1_075 - storedExponent
        }

        while denominatorPower > 0, significand.isMultiple(of: 2) {
            significand /= 2
            denominatorPower -= 1
        }

        var digits = String(significand).utf8.map { $0 - 48 }
        for _ in 0 ..< denominatorPower {
            var carry: UInt16 = 0
            for index in digits.indices.reversed() {
                let product = UInt16(digits[index]) * 5 + carry
                digits[index] = UInt8(product % 10)
                carry = product / 10
            }
            while carry > 0 {
                digits.insert(UInt8(carry % 10), at: 0)
                carry /= 10
            }
        }

        if digits.count < denominatorPower {
            digits.insert(contentsOf: repeatElement(0, count: denominatorPower - digits.count), at: 0)
        }
        while digits.last == 0 {
            digits.removeLast()
        }
        return digits
    }
}

private extension KeyedDecodingContainer {
    func eluDecodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else { return nil }
        // Unlike decodeIfPresent, an explicit null is invalid for every
        // optional member in the frozen config/privacy schemas.
        return try decode(T.self, forKey: key)
    }
}

enum EluV1Validation {
    struct ParsedTimestamp {
        let date: Date
        let baseSecond: Int64
        let isLeapSecond: Bool
        let fractionalDigits: [UInt8]
    }

    static func validString(_ value: String, minimum: Int, maximum: Int) -> Bool {
        let count = value.unicodeScalars.count
        return count >= minimum && count <= maximum
    }

    static func validCapabilityIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 5,
              bytes.count <= 68,
              bytes.starts(with: Array("elu-".utf8))
        else {
            return false
        }
        let body = bytes.dropFirst(4)
        guard let first = body.first, isLowercaseLetterOrDigit(first) else { return false }
        return body.dropFirst().allSatisfy {
            isLowercaseLetterOrDigit($0) || $0 == 45 || $0 == 46
        }
    }

    static func validPolicyHash(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 71, bytes.starts(with: Array("sha256:".utf8)) else { return false }
        return bytes.dropFirst(7).allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    static func isAbsoluteHTTPSURI(_ value: String) -> Bool {
        guard value.hasPrefix("https://"),
              value.utf8.allSatisfy({ (0x21 ... 0x7E).contains($0) }),
              !value.contains("\\"),
              hasValidPercentEncoding(value),
              !containsEncodedDotSegment(value),
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.url != nil
        else {
            return false
        }
        return true
    }

    static func parseRFC3339(_ value: String) -> ParsedTimestamp? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20,
              digits(bytes, 0 ..< 4),
              bytes[4] == 45,
              digits(bytes, 5 ..< 7),
              bytes[7] == 45,
              digits(bytes, 8 ..< 10),
              bytes[10] == 84 || bytes[10] == 116,
              digits(bytes, 11 ..< 13),
              bytes[13] == 58,
              digits(bytes, 14 ..< 16),
              bytes[16] == 58,
              digits(bytes, 17 ..< 19)
        else {
            return nil
        }

        var cursor = 19
        var fraction: [UInt8] = []
        if cursor < bytes.count, bytes[cursor] == 46 {
            cursor += 1
            let start = cursor
            while cursor < bytes.count, isDigit(bytes[cursor]) {
                fraction.append(bytes[cursor] - 48)
                cursor += 1
            }
            guard cursor > start else { return nil }
        }

        let offsetSeconds: Int
        if cursor + 1 == bytes.count, bytes[cursor] == 90 || bytes[cursor] == 122 {
            offsetSeconds = 0
        } else {
            guard cursor + 6 == bytes.count,
                  bytes[cursor] == 43 || bytes[cursor] == 45,
                  digits(bytes, (cursor + 1) ..< (cursor + 3)),
                  bytes[cursor + 3] == 58,
                  digits(bytes, (cursor + 4) ..< (cursor + 6))
            else {
                return nil
            }
            let hours = integer(bytes, (cursor + 1) ..< (cursor + 3))
            let minutes = integer(bytes, (cursor + 4) ..< (cursor + 6))
            guard hours <= 23, minutes <= 59 else { return nil }
            let magnitude = hours * 3_600 + minutes * 60
            offsetSeconds = bytes[cursor] == 45 ? -magnitude : magnitude
        }

        let year = integer(bytes, 0 ..< 4)
        let month = integer(bytes, 5 ..< 7)
        let day = integer(bytes, 8 ..< 10)
        let hour = integer(bytes, 11 ..< 13)
        let minute = integer(bytes, 14 ..< 16)
        let second = integer(bytes, 17 ..< 19)
        guard (0 ... 9_999).contains(year),
              (1 ... 12).contains(month),
              (1 ... daysInMonth(year: year, month: month)).contains(day),
              (0 ... 23).contains(hour),
              (0 ... 59).contains(minute),
              (0 ... 60).contains(second)
        else {
            return nil
        }

        let calendarSecond = min(second, 59)
        let localBaseSecond = daysFromCivil(year: year, month: month, day: day) * 86_400
            + Int64(hour * 3_600 + minute * 60 + calendarSecond)
        let utcBaseSecond = localBaseSecond - Int64(offsetSeconds)
        let isLeapSecond = second == 60
        if isLeapSecond {
            let boundary = utcBaseSecond + 1
            guard boundary % 86_400 == 0 else { return nil }
            let boundaryDay = boundary / 86_400
            let candidateYears = (year - 1) ... (year + 1)
            let isPermittedBoundary = candidateYears.contains { candidateYear in
                boundaryDay == daysFromCivil(year: candidateYear, month: 1, day: 1)
                    || boundaryDay == daysFromCivil(year: candidateYear, month: 7, day: 1)
            }
            guard isPermittedBoundary else { return nil }
        }

        var fractionValue = 0.0
        var place = 0.1
        for digit in fraction.prefix(17) {
            fractionValue += Double(digit) * place
            place /= 10
        }
        return ParsedTimestamp(
            date: Date(
                timeIntervalSince1970: Double(utcBaseSecond + (isLeapSecond ? 1 : 0))
                    + fractionValue
            ),
            baseSecond: utcBaseSecond,
            isLeapSecond: isLeapSecond,
            fractionalDigits: fraction
        )
    }

    private static func hasValidPercentEncoding(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25 {
                guard index + 2 < bytes.count,
                      isHexDigit(bytes[index + 1]),
                      isHexDigit(bytes[index + 2])
                else {
                    return false
                }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func containsEncodedDotSegment(_ value: String) -> Bool {
        guard let schemeEnd = value.range(of: "://")?.upperBound else { return true }
        let suffix = value[schemeEnd...]
        guard let pathStart = suffix.firstIndex(of: "/") else { return false }
        let pathAndLater = suffix[pathStart...]
        let pathEnd = pathAndLater.firstIndex(where: { $0 == "?" || $0 == "#" })
            ?? pathAndLater.endIndex
        let rawPath = pathAndLater[..<pathEnd]

        return rawPath.split(separator: "/", omittingEmptySubsequences: false).contains { segment in
            var decoded: [UInt8] = []
            let bytes = Array(segment.utf8)
            var index = 0
            while index < bytes.count {
                if bytes[index] == 0x25, index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]),
                   let low = hexValue(bytes[index + 2])
                {
                    decoded.append(high * 16 + low)
                    index += 3
                } else {
                    decoded.append(bytes[index])
                    index += 1
                }
            }
            return decoded == [0x2E] || decoded == [0x2E, 0x2E]
        }
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    /// Proleptic Gregorian days relative to 1970-01-01. Astronomical year zero
    /// is intentionally supported because RFC 3339's `date-fullyear` is 4DIGIT.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear >= 0 ? adjustedYear / 400 : (adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era * 146_097 + dayOfEra - 719_468)
    }

    private static func isLowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (97 ... 122).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        hexValue(byte) != nil
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57:
            return byte - 48
        case 65 ... 70:
            return byte - 65 + 10
        case 97 ... 102:
            return byte - 97 + 10
        default:
            return nil
        }
    }

    private static func digits(_ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        range.allSatisfy { $0 < bytes.count && isDigit(bytes[$0]) }
    }

    private static func integer(_ bytes: [UInt8], _ range: Range<Int>) -> Int {
        range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
    }
}
