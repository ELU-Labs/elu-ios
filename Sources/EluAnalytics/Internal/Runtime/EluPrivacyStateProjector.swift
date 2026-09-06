import Foundation

/// The active config members the privacy-state producer projects from.
struct EluV1PrivacyProjectionContext: Sendable {
    let policy: EluV1PrivacyPolicy
    let features: EluV1Features
    let capabilities: EluV1Capabilities
}

/// Masking the local replay runtime applies to captured frames. Secure inputs
/// are always masked on this platform, so a capability can never describe
/// handling weaker than the frozen state schema allows.
struct EluPrivacyMaskingCapability: Equatable, Sendable {
    var text: EluV1MaskingLevel
    var inputs: EluV1MaskingLevel
    var images: EluV1ImagePolicy

    /// Whether this masking is at least as strong as `policy` on every axis.
    func satisfies(_ policy: EluV1MaskingPolicy) -> Bool {
        (policy.text == .sensitive || text == .all)
            && (policy.inputs == .sensitive || inputs == .all)
            && (policy.images == .allow || images == .block)
    }

    /// The weakest masking that is at least as strong as both this capability
    /// and `policy`.
    func strengthened(to policy: EluV1MaskingPolicy) -> EluPrivacyMaskingCapability {
        EluPrivacyMaskingCapability(
            text: policy.text == .all ? .all : text,
            inputs: policy.inputs == .all ? .all : inputs,
            images: policy.images == .block ? .block : images
        )
    }
}

/// Device-local facts the producer combines with the installed policy.
struct EluPrivacyProjectionInput: Equatable, Sendable {
    let contextRevision: Int64
    let identityOptedOut: Bool
    /// IANA identifier of the device time zone; nil or empty fails closed.
    let timeZoneIdentifier: String?
    let evaluatedAt: Date
    /// Masking the runtime currently applies.
    let appliedMasking: EluPrivacyMaskingCapability
    /// Masking-rule dialects the runtime interprets; iOS rules outside this set
    /// are handled by the blanket fallback.
    let recognizedMaskingRuleDialects: Set<String>
    /// Uniform draw in `[0, 1)` compared against the policy sample rate.
    let replaySampleDraw: Double
    let replaySessionEligible: Bool
    let replayBudgetRemainingSeconds: Int
    /// Readback-proven local pairs in preference order.
    let localReplayTransports: [EluV1ReplayTransportPair]

    init(
        contextRevision: Int64,
        identityOptedOut: Bool,
        timeZoneIdentifier: String?,
        evaluatedAt: Date,
        appliedMasking: EluPrivacyMaskingCapability,
        recognizedMaskingRuleDialects: Set<String> = [],
        replaySampleDraw: Double,
        replaySessionEligible: Bool,
        replayBudgetRemainingSeconds: Int,
        localReplayTransports: [EluV1ReplayTransportPair]
    ) {
        self.contextRevision = contextRevision
        self.identityOptedOut = identityOptedOut
        self.timeZoneIdentifier = timeZoneIdentifier
        self.evaluatedAt = evaluatedAt
        self.appliedMasking = appliedMasking
        self.recognizedMaskingRuleDialects = recognizedMaskingRuleDialects
        self.replaySampleDraw = replaySampleDraw
        self.replaySessionEligible = replaySessionEligible
        self.replayBudgetRemainingSeconds = replayBudgetRemainingSeconds
        self.localReplayTransports = localReplayTransports
    }
}

struct EluProjectedOnDeviceDecision: Equatable, Sendable {
    let decision: EluV1Decision
    let source: EluV1DecisionSource
    let reason: String?
}

/// A produced effective privacy state. `stateData` is the canonical, hashed
/// document that the config manager verifies before granting capture or
/// replay authority; the remaining members mirror the claims it carries.
struct EluProjectedPrivacyState: Equatable, Sendable {
    let stateData: Data
    let effectivePolicyHash: String
    let onDeviceDecision: EluProjectedOnDeviceDecision
    let captureAllowed: Bool
    let replayAllowed: Bool
    let replaySampled: Bool
    let maskingValidated: Bool
    let platformFallbackApplied: Bool
    /// Masking the runtime must apply for this state to hold.
    let effectiveMasking: EluPrivacyMaskingCapability
    let replayTransport: EluV1ReplayTransportPair?
    let replayBudgetRemainingSeconds: Int
}

enum EluPrivacyStateProjectionError: Error, Equatable, Sendable {
    case invalidClock
    case invalidContextRevision
    case invalidSampleDraw
}

/// Produces the on-device effective privacy state from the installed policy,
/// the EU region guard, local masking, and local replay facts. The output is
/// the only input the capture authority accepts for privacy, so every claim
/// here is derived the same way the config manager re-derives it.
enum EluPrivacyStateProjector {
    static let regionalPolicyReason = "regional-policy"
    static let identityOptedOutReason = "identity-opted-out"

    static func project(
        context: EluV1PrivacyProjectionContext,
        input: EluPrivacyProjectionInput
    ) throws -> EluProjectedPrivacyState {
        guard input.evaluatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw EluPrivacyStateProjectionError.invalidClock
        }
        guard input.contextRevision >= 0 else {
            throw EluPrivacyStateProjectionError.invalidContextRevision
        }

        let policy = context.policy
        let decision = onDeviceDecision(
            regionPolicy: policy.regionPolicy,
            timeZoneIdentifier: input.timeZoneIdentifier,
            identityOptedOut: input.identityOptedOut
        )
        let captureAllowed = context.features.capture
            && policy.capture.enabled
            && decision.decision == .allow
            && !input.identityOptedOut

        let effectiveMasking = input.appliedMasking.strengthened(to: policy.masking)
        let maskingValidated = input.appliedMasking.satisfies(policy.masking)
        let iosRules = policy.masking.platformRules?.filter { $0.platform == .ios } ?? []
        let allIOSRulesRecognized = !iosRules.isEmpty && iosRules.allSatisfy {
            input.recognizedMaskingRuleDialects.contains($0.targetDialect)
        }
        let platformFallbackApplied = !allIOSRulesRecognized

        let replaySampled = try isSampled(
            draw: input.replaySampleDraw,
            sampleRate: policy.replay.sampleRate
        )
        let replayBudgetRemainingSeconds = min(
            max(0, input.replayBudgetRemainingSeconds),
            policy.replay.maximumDurationSeconds,
            86_400
        )
        let replayTransport = input.localReplayTransports.first {
            context.capabilities.replay.advertises(codec: $0.codec, compression: $0.compression)
        }
        let replayAllowed = captureAllowed
            && context.features.replay
            && policy.replay.enabled
            && replaySampled
            && maskingValidated
            && input.replaySessionEligible
            && replayBudgetRemainingSeconds > 0
            && replayTransport != nil

        var decisionMembers: [EluV1StrictCanonicalJSON.Member] = [
            member("decision", string(decision.decision.rawValue)),
            member("source", string(decision.source.rawValue)),
            member("evaluatedAt", string(EluRFC3339.string(from: input.evaluatedAt))),
        ]
        if let reason = decision.reason {
            decisionMembers.append(member("reason", string(reason)))
        }
        let transportValue: EluV1StrictCanonicalJSON.Value = replayTransport.map {
            .object([
                member("codec", string($0.codec)),
                member("compression", string($0.compression.rawValue)),
                member("advertised", .bool(true)),
            ])
        } ?? .null

        var members: [EluV1StrictCanonicalJSON.Member] = [
            member("schemaVersion", .number(String(EluV1EffectivePrivacyState.schemaVersion))),
            member("policyRevision", string(policy.revision)),
            member("contextRevision", .number(String(input.contextRevision))),
            member("onDeviceDecision", .object(decisionMembers)),
            member("captureAllowed", .bool(captureAllowed)),
            member("replayAllowed", .bool(replayAllowed)),
            member("replaySampled", .bool(replaySampled)),
            member("identityOptedOut", .bool(input.identityOptedOut)),
            member("maskingValidated", .bool(maskingValidated)),
            member("replaySessionEligible", .bool(input.replaySessionEligible)),
            member("replayBudgetRemainingSeconds", .number(String(replayBudgetRemainingSeconds))),
            member("replayTransport", transportValue),
            member(
                "effectiveMasking",
                .object([
                    member("text", string(effectiveMasking.text.rawValue)),
                    member("inputs", string(effectiveMasking.inputs.rawValue)),
                    member("images", string(effectiveMasking.images.rawValue)),
                    member("secureInputsMasked", .bool(true)),
                    member("platformFallbackApplied", .bool(platformFallbackApplied)),
                ])
            ),
        ]
        // The hash covers the canonical document without its own member, which
        // is exactly what the config manager recomputes during verification.
        let effectivePolicyHash = try EluV1StrictCanonicalJSON.hash(.object(members))
        members.append(member("effectivePolicyHash", string(effectivePolicyHash)))
        let stateData = try EluV1StrictCanonicalJSON.canonicalData(for: .object(members))

        return EluProjectedPrivacyState(
            stateData: stateData,
            effectivePolicyHash: effectivePolicyHash,
            onDeviceDecision: decision,
            captureAllowed: captureAllowed,
            replayAllowed: replayAllowed,
            replaySampled: replaySampled,
            maskingValidated: maskingValidated,
            platformFallbackApplied: platformFallbackApplied,
            effectiveMasking: effectiveMasking,
            replayTransport: replayTransport,
            replayBudgetRemainingSeconds: replayBudgetRemainingSeconds
        )
    }

    /// Region policy first, then local consent. A remote block never reports an
    /// allow decision, and the EU guard fails closed on an unreadable zone.
    static func onDeviceDecision(
        regionPolicy: EluV1RegionPolicy,
        timeZoneIdentifier: String?,
        identityOptedOut: Bool
    ) -> EluProjectedOnDeviceDecision {
        switch regionPolicy.mode {
        case .block:
            return EluProjectedOnDeviceDecision(
                decision: .block,
                source: .remoteKillSwitch,
                reason: regionalPolicyReason
            )
        case .blockEuOnDevice:
            if EluEuGuard.isEuTimezone(timeZoneIdentifier) {
                return EluProjectedOnDeviceDecision(
                    decision: .block,
                    source: .deviceRegion,
                    reason: regionalPolicyReason
                )
            }
            if identityOptedOut {
                return localConsentBlock
            }
            return EluProjectedOnDeviceDecision(decision: .allow, source: .deviceRegion, reason: nil)
        case .allow:
            if identityOptedOut {
                return localConsentBlock
            }
            return EluProjectedOnDeviceDecision(decision: .allow, source: .notEvaluated, reason: nil)
        }
    }

    /// A rate of zero never samples and a rate of one always does; the draw
    /// must be a finite value in `[0, 1)`.
    static func isSampled(draw: Double, sampleRate: Double) throws -> Bool {
        guard draw.isFinite, draw >= 0, draw < 1 else {
            throw EluPrivacyStateProjectionError.invalidSampleDraw
        }
        return sampleRate > 0 && draw < sampleRate
    }

    private static var localConsentBlock: EluProjectedOnDeviceDecision {
        EluProjectedOnDeviceDecision(
            decision: .block,
            source: .localConsent,
            reason: identityOptedOutReason
        )
    }

    private static func member(
        _ name: String,
        _ value: EluV1StrictCanonicalJSON.Value
    ) -> EluV1StrictCanonicalJSON.Member {
        EluV1StrictCanonicalJSON.Member(name: Array(name.utf16), value: value)
    }

    private static func string(_ value: String) -> EluV1StrictCanonicalJSON.Value {
        .string(Array(value.utf16))
    }
}
