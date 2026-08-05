import EluAnalytics
import Foundation
import SwiftUI
import SystemConfiguration
import UIKit

private enum UpgradeBuild: String {
    case source
    case candidate
}

private struct UpgradeResult: Codable {
    let build: String
    let identityCheck: Bool
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: UpgradeEvidenceView())
        window.makeKeyAndVisible()
        self.window = window
        UpgradeProbe.start()
        return true
    }
}

private struct UpgradeEvidenceView: View {
    var body: some View {
        Text("SDK upgrade evidence")
    }
}

private enum UpgradeProbe {
    private static let identityKey = "elu.upgrade-evidence.expected-identity"
    private static let sourceMarker = "elu_sdk_upgrade_source"
    private static let candidateMarker = "elu_sdk_upgrade_candidate"
    private static let timeoutSeconds: TimeInterval = 20
    private static let flushRetryCount = 5
    private static let flushRetryInterval: TimeInterval = 1
    private static let networkProbeTimeout: TimeInterval = 10
    private static let networkProbeURL = URL(string: "https://github.com/favicon.ico")!
    private static let reachabilityProbeTimeout: TimeInterval = 10
    private static let reachabilityProbeInterval: TimeInterval = 0.2
    private static let requiredReachabilitySamples = 2

    static func start() {
        let environment = ProcessInfo.processInfo.environment
        guard let buildValue = environment["ELU_UPGRADE_BUILD"],
              let build = UpgradeBuild(rawValue: buildValue),
              let originValue = environment["ELU_UPGRADE_ORIGIN"],
              let origin = URL(string: originValue)
        else {
            write(build: "invalid", identityCheck: false)
            return
        }

        probeNetwork { ready in
            guard ready else {
                write(build: "network-unready", identityCheck: false)
                return
            }
            waitForSystemReachability(
                deadline: Date().addingTimeInterval(reachabilityProbeTimeout)
            ) { reachable in
                guard reachable else {
                    write(build: "network-unready", identityCheck: false)
                    return
                }
                begin(build: build, origin: origin)
            }
        }
    }

    private static func probeNetwork(completion: @escaping (Bool) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = networkProbeTimeout
        configuration.timeoutIntervalForResource = networkProbeTimeout
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: networkProbeURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = networkProbeTimeout
        let task = session.dataTask(with: request) { _, response, _ in
            let ready = response is HTTPURLResponse
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                completion(ready)
            }
        }
        task.resume()
    }

    private static func waitForSystemReachability(
        deadline: Date,
        reachableSamples: Int = 0,
        completion: @escaping (Bool) -> Void
    ) {
        let nextReachableSamples = systemNetworkIsReachable() ? reachableSamples + 1 : 0
        if nextReachableSamples >= requiredReachabilitySamples {
            completion(true)
            return
        }
        guard Date() < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + reachabilityProbeInterval) {
            waitForSystemReachability(
                deadline: deadline,
                reachableSamples: nextReachableSamples,
                completion: completion
            )
        }
    }

    private static func systemNetworkIsReachable() -> Bool {
        var zeroAddress = sockaddr()
        zeroAddress.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        zeroAddress.sa_family = sa_family_t(AF_INET)
        guard let reachability = SCNetworkReachabilityCreateWithAddress(nil, &zeroAddress) else {
            return false
        }
        var flags = SCNetworkReachabilityFlags()
        return SCNetworkReachabilityGetFlags(reachability, &flags) && flags.contains(.reachable)
    }

    private static func begin(build: UpgradeBuild, origin: URL) {
        let defaults = UserDefaults.standard
        let expectedIdentity: String
        switch build {
        case .source:
            expectedIdentity = UUID().uuidString
            defaults.set(expectedIdentity, forKey: identityKey)
            defaults.synchronize()
        case .candidate:
            guard let stored = defaults.string(forKey: identityKey), !stored.isEmpty else {
                write(build: build.rawValue, identityCheck: false)
                return
            }
            expectedIdentity = stored
        }

        Elu.setup(siteKey: "upgrade-evidence", options: EluSetupOptions(configHost: origin))
        if build == .source {
            Elu.identify(expectedIdentity)
        }
        waitForIdentity(build: build, expectedIdentity: expectedIdentity, deadline: Date().addingTimeInterval(timeoutSeconds))
    }

    private static func waitForIdentity(build: UpgradeBuild, expectedIdentity: String, deadline: Date) {
        guard Date() < deadline else {
            write(build: build.rawValue, identityCheck: false)
            return
        }
        if Elu.distinctId() == expectedIdentity {
            Elu.capture(build == .source ? sourceMarker : candidateMarker)
            flushMarker(retriesRemaining: flushRetryCount)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                write(build: build.rawValue, identityCheck: true)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            waitForIdentity(build: build, expectedIdentity: expectedIdentity, deadline: deadline)
        }
    }

    private static func flushMarker(retriesRemaining: Int) {
        Elu.flush()
        guard retriesRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + flushRetryInterval) {
            flushMarker(retriesRemaining: retriesRemaining - 1)
        }
    }

    private static func write(build: String, identityCheck: Bool) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder().encode(UpgradeResult(build: build, identityCheck: identityCheck))
        else { return }
        let output = documents.appendingPathComponent("elu-upgrade-\(build)-result.json")
        try? data.write(to: output, options: .atomic)
    }
}
