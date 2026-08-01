import Foundation

/// Timezone heuristic identical to the ELU web loader.
///
/// FAIL-CLOSED: an empty/unreadable zone blocks. Coverage is a deliberate
/// superset of EU/EEA (`Europe/` prefix over-blocks UK/CH/TR — web parity;
/// the server-side GeoIP drop remains the ingest backstop).
enum EluEuGuard {
    /// EU/EEA territories whose IANA timezone is not under the `Europe/` prefix.
    static let euTzExtras: Set<String> = [
        "Asia/Nicosia",
        "Asia/Famagusta",
        "Atlantic/Canary",
        "Atlantic/Madeira",
        "Atlantic/Azores",
        "Atlantic/Reykjavik",
        "Atlantic/Faroe",
        "Africa/Ceuta",
        "America/Cayenne",
        "America/Guadeloupe",
        "America/Martinique",
        "Indian/Reunion",
        "Indian/Mayotte",
    ]

    static func isEuTimezone(_ identifier: String?) -> Bool {
        guard let tz = identifier, !tz.isEmpty else { return true }
        return tz.hasPrefix("Europe/") || euTzExtras.contains(tz)
    }

    static func deviceIsInEu() -> Bool {
        isEuTimezone(TimeZone.current.identifier)
    }
}
