import Foundation

/// Privacy controls with the exact semantics of `ResolvedPrivacyConfig` on web
/// (the ELU web loader). Every field decodes tolerantly:
/// a missing or wrongly-typed field falls back to the web default, per the
/// contract — never to `false`-for-everything.
struct EluPrivacyConfig: Equatable {
    var blockEu: Bool
    var maskTextInputs: Bool
    var maskAllText: Bool
    var maskImages: Bool
    var replayNewUsersOnly: Bool
    /// 1–60 per-PostHog-session replay budget in minutes; 0 = unlimited.
    var replayMaxMinutes: Int

    static let replayMaxMinutesCap = 60

    /// Web defaults — the fallback for any missing/unparseable privacy field
    /// and for a wholly absent privacy object.
    static let webDefaults = EluPrivacyConfig(
        blockEu: true,
        maskTextInputs: true,
        maskAllText: false,
        maskImages: false,
        replayNewUsersOnly: false,
        replayMaxMinutes: 0
    )

    static func clampMinutes(_ raw: Double?) -> Int {
        guard let raw, raw.isFinite else { return 0 }
        let minutes = Int(raw.rounded(.down))
        // Web parity (privacyConfig.ts): out-of-range means UNLIMITED (0),
        // never a silent clamp to the cap.
        if minutes < 0 || minutes > replayMaxMinutesCap { return 0 }
        return minutes
    }
}

extension EluPrivacyConfig: Decodable {
    private enum CodingKeys: String, CodingKey {
        case blockEu, maskTextInputs, maskAllText, maskImages, replayNewUsersOnly, replayMaxMinutes
    }

    init(from decoder: Decoder) throws {
        let d = Self.webDefaults
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = d
            return
        }
        blockEu = (try? c.decode(Bool.self, forKey: .blockEu)) ?? d.blockEu
        maskTextInputs = (try? c.decode(Bool.self, forKey: .maskTextInputs)) ?? d.maskTextInputs
        maskAllText = (try? c.decode(Bool.self, forKey: .maskAllText)) ?? d.maskAllText
        maskImages = (try? c.decode(Bool.self, forKey: .maskImages)) ?? d.maskImages
        replayNewUsersOnly = (try? c.decode(Bool.self, forKey: .replayNewUsersOnly)) ?? d.replayNewUsersOnly
        replayMaxMinutes = EluPrivacyConfig.clampMinutes(try? c.decode(Double.self, forKey: .replayMaxMinutes))
    }
}

/// Decoded body of `GET /v1/<siteKey>/config`.
///
/// Unknown fields are ignored (forward compatibility). A body that cannot
/// produce a usable value (missing `enabled`, or `enabled:true` without a
/// token/host) throws — the caller treats that as a FETCH FAILURE (keep the
/// cached config / stay pending), never as `enabled:false`.
struct EluRemoteConfig: Decodable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let enabled: Bool
    let publicToken: String
    let host: String
    let privacy: EluPrivacyConfig

    private enum CodingKeys: String, CodingKey {
        case v, enabled, publicToken, host, privacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .v)
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .v,
                in: c,
                debugDescription: "unsupported ELU config schema version \(schemaVersion)"
            )
        }
        enabled = try c.decode(Bool.self, forKey: .enabled)
        let token = (try? c.decode(String.self, forKey: .publicToken)) ?? ""
        let host = (try? c.decode(String.self, forKey: .host)) ?? ""
        if enabled, token.isEmpty || host.isEmpty || URL(string: host) == nil {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: c.codingPath,
                debugDescription: "enabled config missing publicToken/host"
            ))
        }
        publicToken = token
        self.host = host
        privacy = (try? c.decode(EluPrivacyConfig.self, forKey: .privacy)) ?? .webDefaults
    }

    static func parse(_ data: Data) throws -> EluRemoteConfig {
        try JSONDecoder().decode(EluRemoteConfig.self, from: data)
    }
}
