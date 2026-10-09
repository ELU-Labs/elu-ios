import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Library, OS, device and app context for every new event, read once on the
/// main actor when the runtime opens. It sits under registered super
/// properties and the call's own properties, and the event filter may replace
/// or remove any of it.
///
/// Names keep the 0.1.0 mobile shape (`$os_name`, `$device_model`,
/// `$app_build`, ...) and add the web's `$os`, so OS, app-version and device
/// breakdowns read the same across platforms. No advertising or vendor
/// identifier, user-assigned device name or account name is read.
struct EluEventContext: Equatable, Sendable {
    var lib: EluVersionComponent
    var osName: String?
    var osVersion: String?
    var deviceType: String?
    var deviceModel: String?
    var isEmulator: Bool
    var appName: String?
    var appVersion: String?
    var appBuild: String?
    var appNamespace: String?
    var screenWidth: Int?
    var screenHeight: Int?
    var locale: String?
    var timeZone: String?

    var properties: [String: EluJSONValue] {
        var result: [String: EluJSONValue] = [
            "$lib": .string(lib.name),
            "$lib_version": .string(lib.version),
            "$device_manufacturer": .string("Apple"),
            "$is_emulator": .bool(isEmulator),
        ]
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { result[key] = .string(value) }
        }
        put("$os", osName)
        put("$os_name", osName)
        put("$os_version", osVersion)
        put("$device_type", deviceType)
        put("$device_model", deviceModel)
        put("$app_name", appName)
        put("$app_version", appVersion)
        put("$app_build", appBuild)
        put("$app_namespace", appNamespace)
        put("$locale", locale)
        put("$timezone", timeZone)
        if let screenWidth, let screenHeight, screenWidth > 0, screenHeight > 0 {
            result["$screen_width"] = .integer(Int64(screenWidth))
            result["$screen_height"] = .integer(Int64(screenHeight))
        }
        return result
    }

    @MainActor
    static func current(lib: EluVersionComponent, bundle: Bundle = .main) -> EluEventContext {
        let info = bundle.infoDictionary ?? [:]
        func text(_ key: String) -> String? {
            (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var context = EluEventContext(
            lib: lib,
            deviceModel: machineIdentifier(),
            isEmulator: isSimulator,
            appName: text("CFBundleDisplayName") ?? text("CFBundleName"),
            appVersion: text("CFBundleShortVersionString"),
            appBuild: text("CFBundleVersion"),
            appNamespace: bundle.bundleIdentifier,
            locale: Locale.preferredLanguages.first,
            timeZone: TimeZone.current.identifier
        )
        #if canImport(UIKit)
        let device = UIDevice.current
        context.osName = device.systemName
        context.osVersion = device.systemVersion
        context.deviceType = deviceType(device.userInterfaceIdiom)
        // Portrait-up points, so the value does not depend on launch orientation.
        let screen = UIScreen.main.fixedCoordinateSpace.bounds.size
        context.screenWidth = Int(screen.width.rounded())
        context.screenHeight = Int(screen.height.rounded())
        #endif
        return context
    }

    #if canImport(UIKit)
    static func deviceType(_ idiom: UIUserInterfaceIdiom) -> String? {
        switch idiom {
        case .phone: return "Mobile"
        case .pad: return "Tablet"
        default:
            if #available(iOS 14.0, *), idiom == .mac { return "Desktop" }
            return nil
        }
    }
    #endif

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The hardware model identifier, such as `iPhone17,1`. A simulator
    /// reports the model it simulates rather than the host architecture.
    private static func machineIdentifier() -> String? {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !model.isEmpty {
            return model
        }
        #endif
        var system = utsname()
        guard uname(&system) == 0 else { return nil }
        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
    }
}
