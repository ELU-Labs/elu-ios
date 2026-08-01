import Foundation

/// Device-local markers backing `replayNewUsersOnly` and `replayMaxMinutes`.
/// UserDefaults is the storage (declared CA92.1 in PrivacyInfo.xcprivacy).
enum EluDeviceMarkers {
    static let firstLaunchKey = "elu.firstLaunchAt"
    static let budgetKeyPrefix = "elu.recBudget."
    static let budgetStampLimit = 5

    /// Records the first-launch marker if absent. Returns true when the marker
    /// was absent at this call — the device is "new" for `replayNewUsersOnly`.
    static func recordFirstLaunchIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: firstLaunchKey) != nil {
            return false
        }
        defaults.set(Date().timeIntervalSince1970 * 1000, forKey: firstLaunchKey)
        return true
    }

    /// Returns the replay-start stamp (ms epoch) for a PostHog session id,
    /// creating it if absent, and prunes to the most recent 5 stamps. The
    /// surviving stamp means a relaunch within the same PostHog session
    /// resumes the REMAINING budget rather than granting a fresh one.
    static func budgetStamp(sessionId: String, defaults: UserDefaults = .standard) -> Double {
        let key = budgetKeyPrefix + sessionId
        if let existing = defaults.object(forKey: key) as? Double {
            return existing
        }
        let now = Date().timeIntervalSince1970 * 1000
        defaults.set(now, forKey: key)
        pruneBudgetStamps(defaults: defaults)
        return now
    }

    static func pruneBudgetStamps(defaults: UserDefaults = .standard) {
        let stamps = defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix(budgetKeyPrefix) }
            .compactMap { key, value -> (String, Double)? in
                guard let ms = value as? Double else { return nil }
                return (key, ms)
            }
            .sorted { $0.1 > $1.1 }
        guard stamps.count > budgetStampLimit else { return }
        for (key, _) in stamps.dropFirst(budgetStampLimit) {
            defaults.removeObject(forKey: key)
        }
    }
}
