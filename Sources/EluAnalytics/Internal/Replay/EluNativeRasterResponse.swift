#if canImport(SwiftUI) && canImport(UIKit)
import Foundation

enum EluNativeRasterConflictScope: String, Equatable, Sendable {
    case request, chunk, sequence
}

enum EluNativeRasterResponseOutcome: Equatable, Sendable {
    case accepted
    case identityConflict(scope: EluNativeRasterConflictScope)
    case rejectedTooLarge
    case retry(afterSeconds: TimeInterval)
    case endpointCooldown(seconds: TimeInterval)
    case credentialBlocked(status: Int)
    case protocolBlocked
}

/// Classifies the response for one original schema3 request. Neither an ACK nor
/// a validated permanent conflict consumes a queue claim or deletes any bytes.
/// The original delivery owner must still join physical completion and SQL.
enum EluNativeRasterResponse {
    static let maximumBytes = 65_536
    static let maximumDelaySeconds: TimeInterval = 86_400

    static func classify(_ response: EluV1BatchHTTPResponse,
                         request: EluNativeRasterPreparedRequest,
                         now: Date) -> EluNativeRasterResponseOutcome {
        // Keep original credential-refusal precedence over unreadable bodies
        // and ambiguous headers. Physical refusal preservation remains upstream.
        if response.status == 401 || response.status == 403 {
            return .credentialBlocked(status: response.status)
        }
        guard response.body.count <= maximumBytes else { return .protocolBlocked }
        let retries = response.headers.filter { $0.key.lowercased() == "retry-after" }
        guard retries.count <= 1 else { return .protocolBlocked }
        let retry = retries.first?.value
        do {
            let document = try EluV1StrictCanonicalJSON.parse(response.body)
            if response.status == 200 {
                let object = try RasterResponseJSON.object(document.value,
                    required: ["schemaVersion", "requestId", "replayId", "chunkId", "sequence", "result"])
                guard retry == nil,
                      try RasterResponseJSON.integer(object["schemaVersion"]) == 3,
                      try RasterResponseJSON.integer(object["sequence"]) == request.sequence,
                      EluV2ReplayText.equal(RasterResponseJSON.string(object["requestId"]), request.requestId),
                      EluV2ReplayText.equal(RasterResponseJSON.string(object["replayId"]), request.replayId),
                      EluV2ReplayText.equal(RasterResponseJSON.string(object["chunkId"]), request.chunkId),
                      RasterResponseJSON.string(object["result"]) == "accepted" else { return .protocolBlocked }
                return .accepted
            }
            if response.status == 409 {
                let object = try RasterResponseJSON.object(document.value,
                    required: ["schemaVersion", "requestId", "status", "code", "disposition", "conflictScope"])
                guard retry == nil,
                      try RasterResponseJSON.integer(object["schemaVersion"]) == 3,
                      try RasterResponseJSON.integer(object["status"]) == 409,
                      EluV2ReplayText.equal(RasterResponseJSON.string(object["requestId"]), request.requestId),
                      RasterResponseJSON.string(object["code"]) == "replay-identity-conflict",
                      RasterResponseJSON.string(object["disposition"]) == "permanent",
                      let text = RasterResponseJSON.string(object["conflictScope"]),
                      let scope = EluNativeRasterConflictScope(rawValue: text) else { return .protocolBlocked }
                return .identityConflict(scope: scope)
            }
            guard response.status == 413 || response.status == 429 || (500...599).contains(response.status) else {
                return .protocolBlocked
            }
            let object = try RasterResponseJSON.object(document.value,
                required: ["schemaVersion", "status", "code", "disposition", "message"], optional: ["requestId"])
            guard try RasterResponseJSON.integer(object["schemaVersion"]) == 1,
                  try RasterResponseJSON.integer(object["status"]) == Int64(response.status),
                  let code = RasterResponseJSON.string(object["code"]),
                  code.range(of: #"\A[a-z][a-z0-9-]{0,63}\z"#, options: .regularExpression) != nil,
                  let message = RasterResponseJSON.string(object["message"]), (1...256).contains(message.unicodeScalars.count),
                  object["requestId"] == nil || EluV2ReplayText.equal(RasterResponseJSON.string(object["requestId"]), request.requestId),
                  RasterResponseJSON.string(object["disposition"]) == (response.status == 413 ? "retry-after-reduction" : "retryable") else {
                return .protocolBlocked
            }
            if response.status == 413 { return retry == nil ? .rejectedTooLarge : .protocolBlocked }
            let delay: TimeInterval
            if let retry {
                guard let parsed = EluV1BatchDeliveryCoordinator.parseRetryAfter(retry, now: now) else { return .protocolBlocked }
                delay = min(max(0, parsed), maximumDelaySeconds)
            } else {
                guard response.status != 429 else { return .protocolBlocked }
                delay = 0
            }
            return response.status == 429 ? .endpointCooldown(seconds: delay) : .retry(afterSeconds: delay)
        } catch { return .protocolBlocked }
    }
}

private enum RasterResponseJSON {
    private enum Failure: Error { case invalid }
    typealias Value = EluV1StrictCanonicalJSON.Value

    static func object(_ value: Value, required: Set<String>, optional: Set<String> = []) throws -> [String: Value] {
        guard case let .object(members) = value else { throw Failure.invalid }
        let names = Set(members.map(\.name)), requiredNames = Set(required.map { Array($0.utf16) })
        guard requiredNames.isSubset(of: names), names.isSubset(of: requiredNames.union(optional.map { Array($0.utf16) })),
              names.count == members.count else { throw Failure.invalid }
        return Dictionary(uniqueKeysWithValues: members.map { (String(decoding: $0.name, as: UTF16.self), $0.value) })
    }
    static func string(_ value: Value?) -> String? {
        guard case let .string(units)? = value else { return nil }
        return String(decoding: units, as: UTF16.self)
    }
    static func integer(_ value: Value?) throws -> Int64 {
        guard let value, case .number = value,
              let number = Int64(String(decoding: try EluV1StrictCanonicalJSON.canonicalData(for: value), as: UTF8.self)),
              (0...9_007_199_254_740_991).contains(number) else { throw Failure.invalid }
        return number
    }
}
#endif
