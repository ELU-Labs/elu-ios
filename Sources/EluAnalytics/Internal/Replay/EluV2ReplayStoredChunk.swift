import Foundation

/// Immutable capture-time metadata. A later identity/context change never rewrites it.
struct EluV2ReplayStoredChunk: Equatable, Sendable {
    let ordinal: Int64
    let siteId: String
    let captureProtocolGeneration: String
    let prepared: EluV2ReplayPreparedRequest
    let maskingProfile: Data

    init(ordinal: Int64, siteId: String, captureProtocolGeneration: String,
         prepared: EluV2ReplayPreparedRequest, maskingProfile: Data) throws {
        guard ordinal >= 0,
              EluV1Validation.validString(siteId, minimum: 1, maximum: 128),
              EluV1Validation.validString(captureProtocolGeneration, minimum: 1, maximum: 128),
              EluV2ReplayText.equal(captureProtocolGeneration, prepared.captureProtocolGeneration),
              !maskingProfile.isEmpty, maskingProfile.count <= 16_384 else { throw EluRuntimeQueueError.invalidRecord }
        let profile = try EluV1StrictCanonicalJSON.parse(maskingProfile)
        guard case .object = profile.value,
              profile.canonicalData == maskingProfile,
              EluV1StrictCanonicalJSON.hash(maskingProfile) == prepared.maskingProfileHash else { throw EluRuntimeQueueError.invalidRecord }
        try Self.validateFrozenProfile(maskingProfile)
        self.ordinal = ordinal
        self.siteId = siteId
        self.captureProtocolGeneration = captureProtocolGeneration
        self.prepared = prepared
        self.maskingProfile = maskingProfile
    }
    /// Both closed profiles are retained descriptions, never admission authority.
    /// The native branch accepts only the two exact shared native documents.
    private static func validateFrozenProfile(_ data: Data) throws {
        if (try? EluNativeMaskingProfile.parse(data)) != nil {
            return
        }
        let root = try EluV1FlagJSON.parse(data, maximumBytes: 16_384)
        let names = Set(["schemaVersion", "targetDialect", "textRule", "inputRule", "imageRule", "secureInputsMasked", "platformFallbackApplied", "resolvedMaskSelectors", "resolvedBlockSelectors"].map { Array($0.utf16) })
        guard let members = root.objectMembers, Set(members.map(\.name)) == names,
              root.property("schemaVersion")?.safeIntegerValue == 1,
              root.property("targetDialect")?.stringValue == "elu-css-selector-v1",
              ["all", "sensitive"].contains(root.property("textRule")?.stringValue ?? ""),
              ["all", "sensitive"].contains(root.property("inputRule")?.stringValue ?? ""),
              ["block", "allow"].contains(root.property("imageRule")?.stringValue ?? ""),
              root.property("secureInputsMasked") == .bool(true),
              case .bool? = root.property("platformFallbackApplied") else { throw EluRuntimeQueueError.invalidRecord }
        for key in ["resolvedMaskSelectors", "resolvedBlockSelectors"] {
            guard case let .array(values)? = root.property(key), values.count <= 128 else { throw EluRuntimeQueueError.invalidRecord }
            var previous: [UInt16]?
            for value in values {
                guard let units = value.stringUnits, !units.isEmpty, String(decoding: units, as: UTF16.self).unicodeScalars.count <= 512,
                      previous.map({ $0.lexicographicallyPrecedes(units) }) ?? true else { throw EluRuntimeQueueError.invalidRecord }
                previous = units
            }
        }
    }
}

/// An exact source/config CAS witness; it does not grant replay permission.
struct EluV2ReplayConfigWitness: Equatable, Sendable {
    let issuedAt: EluV1Timestamp
    let semanticHash: String
}

struct EluV2ReplayQueueInventory: Equatable, Sendable {
    let replayCount: Int64
    let replayBytes: Int64
    let aggregateCount: Int64
    let aggregateBytes: Int64
}

enum EluV2ReplayAppendResult: Equatable, Sendable {
    case inserted(EluV2ReplayStoredChunk)
    case duplicate(EluV2ReplayStoredChunk)
}

/// Swift String equality folds canonical Unicode equivalents; wire witnesses do not.
enum EluV2ReplayText {
    static func equal(_ first: String?, _ second: String?) -> Bool {
        switch (first, second) {
        case let (first?, second?): return first.utf8.elementsEqual(second.utf8)
        case (nil, nil): return true
        default: return false
        }
    }
}
