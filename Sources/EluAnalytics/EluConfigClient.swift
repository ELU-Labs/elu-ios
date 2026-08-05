import Foundation

/// Fetches `GET <configHost>/v1/<siteKey>/config` and mirrors the loader's
/// stale-while-revalidate philosophy: the last successful response is
/// persisted verbatim and stays valid indefinitely — better to run on
/// yesterday's config than to run dark.
///
/// All callbacks fire on the owner's serial queue. Fetch failures back off
/// exponentially, at most 3 attempts per foreground, and never surface to the
/// caller.
final class EluConfigClient {
    static let requestTimeout: TimeInterval = 10
    static let foregroundRefreshAge: TimeInterval = 15 * 60
    static let maxAttemptsPerForeground = 3

    private let siteKey: String
    private let configHost: URL
    private let queue: DispatchQueue
    private let session: URLSession

    /// Invoked on `queue` after every successful fetch+parse (already persisted).
    var onConfig: ((EluRemoteConfig) -> Void)?

    private var lastSuccessAt: Date?
    private var attemptsThisForeground = 0
    private var inFlight = false

    init(siteKey: String, configHost: URL, queue: DispatchQueue) {
        self.siteKey = siteKey
        self.configHost = configHost
        self.queue = queue
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Self.requestTimeout
        session = URLSession(configuration: cfg)
    }

    /// Builds the v1 config URL with the site key as exactly one path component.
    static func requestURL(configHost: URL, siteKey: String) -> URL? {
        guard !siteKey.isEmpty,
              var components = URLComponents(url: configHost, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        guard let encodedSiteKey = siteKey.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = [basePath, "v1", encodedSiteKey, "config"].filter { !$0.isEmpty }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        return components.url
    }

    static func cacheFileName(siteKey: String) -> String {
        let safeKey = siteKey.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        }
        return "config-\(String(safeKey)).json"
    }

    // MARK: - Disk cache (Application Support, verbatim bytes)

    private var cacheFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("EluAnalytics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Self.cacheFileName(siteKey: siteKey))
    }

    func loadCached() -> EluRemoteConfig? {
        guard let url = cacheFileURL,
              let data = try? Data(contentsOf: url),
              let cfg = try? EluRemoteConfig.parse(data)
        else {
            return nil
        }
        return cfg
    }

    private func persist(_ data: Data) {
        guard let url = cacheFileURL else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Fetch

    /// Cold-start / setup fetch: resets the per-foreground attempt budget.
    func fetchNow() {
        attemptsThisForeground = 0
        startAttempt()
    }

    /// App came to foreground: refresh only if the last success is stale.
    func handleForeground() {
        attemptsThisForeground = 0
        if let last = lastSuccessAt, Date().timeIntervalSince(last) < Self.foregroundRefreshAge {
            return
        }
        startAttempt()
    }

    private func startAttempt() {
        guard !inFlight, attemptsThisForeground < Self.maxAttemptsPerForeground else { return }
        attemptsThisForeground += 1
        guard let url = Self.requestURL(configHost: configHost, siteKey: siteKey) else { return }
        inFlight = true

        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                self.inFlight = false
                guard error == nil,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let cfg = try? EluRemoteConfig.parse(data)
                else {
                    // Malformed body == fetch failure: keep cache, back off.
                    self.scheduleRetry()
                    return
                }
                self.lastSuccessAt = Date()
                self.persist(data)
                self.onConfig?(cfg)
            }
        }
        task.resume()
    }

    private func scheduleRetry() {
        guard attemptsThisForeground < Self.maxAttemptsPerForeground else { return }
        let delay = pow(2.0, Double(attemptsThisForeground)) // 2s, 4s
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startAttempt()
        }
    }
}
