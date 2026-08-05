import CryptoKit
import Darwin
import Foundation

enum EluV1CaptureAuthorityTerminalReason: Equatable, Sendable {
    case disabled
    case revoked
    case privacyBlocked
    case malformed
    case conflict
    case expired
    case siteChanged
    case stale
}

struct EluV1CaptureConfigBoundary: Equatable, Sendable {
    let issuedAt: EluV1Timestamp
    let semanticHash: String
}

enum EluV1CaptureAuthorityState: Equatable, Sendable {
    case absent
    case authorized(EluV1CaptureAuthoritySnapshot)
    case terminal(EluV1CaptureAuthorityTerminal)
}

struct EluV1CaptureAuthoritySnapshot: Equatable, Sendable {
    let ownerEpoch: UInt64
    let configBoundary: EluV1CaptureConfigBoundary
    let expiresAt: EluV1Timestamp
    let policySourceHash: String
    let decisionHash: String
    let ownerNamespaceHash: String
    let configSiteId: String
    let streamId: String
    let identityRevision: Int64
    let contextRevision: Int64
    let identityOptedOut: Bool
    let monotonicStartedAt: UInt64
    let monotonicBudget: UInt64
    let idleTimeoutSeconds: Int
    let maximumDurationSeconds: Int
}

struct EluV1CaptureAuthorityTerminal: Equatable, Sendable {
    let ownerEpoch: UInt64
    let trustedConfigBoundary: EluV1CaptureConfigBoundary?
    let candidateConfigBoundary: EluV1CaptureConfigBoundary?
    let policySourceHash: String?
    let contextRevision: Int64?
    let reason: EluV1CaptureAuthorityTerminalReason
}

enum EluV1CaptureAuthorityUpdateResult: Equatable, Sendable {
    case activated(EluV1CaptureAuthoritySnapshot)
    case terminated(EluV1CaptureAuthorityTerminal)
}

struct EluV1CaptureCommand: Equatable, Sendable {
    let kind: EluEventKind
    let name: String
    let occurredAt: Date
    let properties: [String: EluJSONValue]
    let versions: EluVersionContext
}

enum EluV1CaptureRejection: Equatable, Sendable {
    case authorityAbsent
    case authorityTerminal
    case authorityExpired
    case authorityWitnessChanged
    case optedOut
    case invalidEvent
    case queueLimit
    case storageProvenNotCommitted
    case storageOutcomeUnknown
}

enum EluV1CaptureResult: Equatable, Sendable {
    case accepted(EluQueuedRecord, snapshot: EluRuntimeQueueSnapshot)
    case rejected(EluV1CaptureRejection, snapshot: EluRuntimeQueueSnapshot)
}

enum EluV1BackgroundResult: Equatable, Sendable {
    case changed(EluRuntimeQueueSnapshot)
    case unchanged(EluRuntimeQueueSnapshot)
    case rejectedOptedOut(EluRuntimeQueueSnapshot)
}

enum EluV1SiteNamespace {
    static func digest(exactConstructorSiteKey: String) throws -> String {
        guard !exactConstructorSiteKey.isEmpty,
              let data = exactConstructorSiteKey.data(using: .utf8)
        else {
            throw EluRuntimeQueueError.invalidDirectory
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func directoryComponent(exactConstructorSiteKey: String) throws -> String {
        "site-" + (try digest(exactConstructorSiteKey: exactConstructorSiteKey))
    }
}

/// Sleep-inclusive monotonic source and conservative nanosecond-to-tick
/// conversion for authority leases.
enum EluMachContinuousClock {
    static func now() -> UInt64 {
        mach_continuous_time()
    }

    static func floorTicks(forNanoseconds nanoseconds: UInt64) -> UInt64? {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS,
              info.numer > 0,
              info.denom > 0
        else {
            return nil
        }

        let numerator = UInt64(info.numer)
        let denominator = UInt64(info.denom)
        let quotient = nanoseconds / numerator
        let remainder = nanoseconds % numerator
        let (whole, wholeOverflow) = quotient.multipliedReportingOverflow(by: denominator)
        let (partialProduct, partialOverflow) = remainder.multipliedReportingOverflow(by: denominator)
        guard !wholeOverflow, !partialOverflow else { return nil }
        let partial = partialProduct / numerator
        let (ticks, addOverflow) = whole.addingReportingOverflow(partial)
        guard !addOverflow else { return nil }
        return ticks
    }
}
