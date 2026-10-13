import Foundation

enum EluV2ReplayResponseOutcome: Equatable, Sendable {
    case accepted
    case rejectedTooLarge
    case retry(afterSeconds: TimeInterval)
    case endpointCooldown(seconds: TimeInterval)
    case credentialBlocked(status: Int)
    case protocolBlocked
}

/// Classifies only the response associated with one exact immutable request.
/// This value alone never permits a row deletion: the queue must consume its claim.
enum EluV2ReplayResponse {
    static let maximumBytes = 65_536
    static let maximumDelaySeconds: TimeInterval = 86_400

    /// Physical cleanup may reveal an original credential refusal after a local
    /// cancellation/size failure. Only that exact transport fact supersedes one.
    static func preservingRefusal(_ incoming: Result<EluV1BatchHTTPResponse, Error>,
        over current: Result<EluV1BatchHTTPResponse, Error>?) -> Result<EluV1BatchHTTPResponse, Error> {
        guard let current else { return incoming }
        if case let .success(response) = current, response.status == 401 || response.status == 403 { return current }
        if case let .success(response) = incoming, response.status == 401 || response.status == 403 { return incoming }
        return current
    }

    static func classify(_ response: EluV1BatchHTTPResponse, request: EluV2ReplayPreparedRequest, now: Date) -> EluV2ReplayResponseOutcome {
        // Refusal status survives unreadable, oversized, or malformed error bodies.
        if response.status == 401 || response.status == 403 { return .credentialBlocked(status: response.status) }
        guard response.body.count <= maximumBytes else { return .protocolBlocked }
        let retries = response.headers.filter { $0.key.lowercased() == "retry-after" }
        guard retries.count <= 1 else { return .protocolBlocked }
        let retry = retries.first?.value
        do {
            let document = try EluV1StrictCanonicalJSON.parse(response.body)
            if (200...299).contains(response.status) {
                let object = try ReplayResponseJSON.object(document.value, required: ["schemaVersion", "requestId", "replayId", "chunkId", "sequence", "result"])
                guard retry == nil, try ReplayResponseJSON.integer(object["schemaVersion"]) == 2,
                      try ReplayResponseJSON.integer(object["sequence"]) == request.sequence,
                      EluV2ReplayText.equal(ReplayResponseJSON.string(object["requestId"]), request.requestId),
                      EluV2ReplayText.equal(ReplayResponseJSON.string(object["replayId"]), request.replayId),
                      EluV2ReplayText.equal(ReplayResponseJSON.string(object["chunkId"]), request.chunkId),
                      ReplayResponseJSON.string(object["result"]) == "accepted" else { return .protocolBlocked }
                return .accepted
            }
            // The v2 identity-conflict schema is a permanent protocol refusal;
            // no deletion or special retry follows even a valid conflict body.
            guard response.status == 413 || response.status == 429 || (500...599).contains(response.status) else { return .protocolBlocked }
            let object = try ReplayResponseJSON.object(document.value, required: ["schemaVersion", "status", "code", "disposition", "message"], optional: ["requestId"])
            guard try ReplayResponseJSON.integer(object["schemaVersion"]) == 1,
                  try ReplayResponseJSON.integer(object["status"]) == Int64(response.status),
                  let code = ReplayResponseJSON.string(object["code"]),
                  code.range(of: #"\A[a-z][a-z0-9-]{0,63}\z"#, options: .regularExpression) != nil,
                  let message = ReplayResponseJSON.string(object["message"]), (1...256).contains(message.unicodeScalars.count),
                  object["requestId"] == nil || EluV2ReplayText.equal(ReplayResponseJSON.string(object["requestId"]), request.requestId),
                  ReplayResponseJSON.string(object["disposition"]) == (response.status == 413 ? "retry-after-reduction" : "retryable") else { return .protocolBlocked }
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

private enum ReplayResponseJSON {
    typealias Value = EluV1StrictCanonicalJSON.Value
    static func object(_ value: Value, required: Set<String>, optional: Set<String> = []) throws -> [String: Value] {
        guard case let .object(members) = value else { throw EluRuntimeQueueError.invalidRecord }
        let names = Set(members.map(\.name)), requiredNames = Set(required.map { Array($0.utf16) })
        guard requiredNames.isSubset(of: names), names.isSubset(of: requiredNames.union(optional.map { Array($0.utf16) })), names.count == members.count else { throw EluRuntimeQueueError.invalidRecord }
        return Dictionary(uniqueKeysWithValues: members.map { (String(decoding: $0.name, as: UTF16.self), $0.value) })
    }
    static func string(_ value: Value?) -> String? {
        guard case let .string(units)? = value else { return nil }; return String(decoding: units, as: UTF16.self)
    }
    static func integer(_ value: Value?) throws -> Int64 {
        guard let value, case .number = value,
              let number = Int64(String(decoding: try EluV1StrictCanonicalJSON.canonicalData(for: value), as: UTF8.self)),
              (0...9_007_199_254_740_991).contains(number) else { throw EluRuntimeQueueError.invalidRecord }
        return number
    }
}
