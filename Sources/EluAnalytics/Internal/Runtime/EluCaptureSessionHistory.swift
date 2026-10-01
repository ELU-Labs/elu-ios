import Foundation

/// Installation history, independent of identity and replay start accounting.
/// An old store with no history cannot prove that its current session is first.
struct EluCaptureSessionHistory: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case unknown, unseen, recorded }
    let status: Status
    let sessionId: String?
    let sessionStartedAt: String?

    static let unknown = Self(status: .unknown, sessionId: nil, sessionStartedAt: nil)
    static let unseen = Self(status: .unseen, sessionId: nil, sessionStartedAt: nil)
    static let maximumBytes = 2_048

    func observing(_ session: EluSessionState) -> Self {
        guard status == .unseen else { return self }
        return Self(status: .recorded, sessionId: session.id,
                    sessionStartedAt: EluRFC3339.string(from: session.startedAt))
    }

    func permits(_ session: EluSessionState) -> Bool {
        status == .recorded
            && sessionId?.utf8.elementsEqual(session.id.utf8) == true
            && sessionStartedAt?.utf8.elementsEqual(EluRFC3339.string(from: session.startedAt).utf8) == true
    }

    func encoded() throws -> Data {
        try validate()
        let value: [String: Any] = ["status": status.rawValue,
            "sessionId": sessionId as Any? ?? NSNull(),
            "sessionStartedAt": sessionStartedAt as Any? ?? NSNull()]
        return try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: value)).canonicalData
    }

    static func decode(_ data: Data) throws -> Self {
        guard (1...maximumBytes).contains(data.count) else { throw EluRuntimeQueueError.corruptStorage }
        let parsed = try EluV1StrictCanonicalJSON.parse(data)
        guard parsed.canonicalData == data, case let .object(fields) = parsed.value,
              Set(fields.map { String(decoding: $0.name, as: UTF16.self) }) == ["status", "sessionId", "sessionStartedAt"]
        else { throw EluRuntimeQueueError.corruptStorage }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    private func validate() throws {
        if status == .recorded {
            guard let sessionId, EluIdentityState.valid(sessionId, maximumLength: 256),
                  let sessionStartedAt, let timestamp = try? EluV1Timestamp(sessionStartedAt),
                  !timestamp.storageIsLeapSecond
            else { throw EluRuntimeQueueError.corruptStorage }
        } else if sessionId != nil || sessionStartedAt != nil {
            throw EluRuntimeQueueError.corruptStorage
        }
    }
}
