import Foundation
import XCTest
@testable import EluAnalytics
#if canImport(UIKit)
import UIKit
#endif

final class EluEventContextTests: XCTestCase {
    private func lib() throws -> EluVersionComponent { try .init(name: "elu-ios", version: "0.2.0") }

    func testPropertiesUseTheMobileAndWebNames() throws {
        let context = EluEventContext(lib: try lib(), osName: "iOS", osVersion: "26.3.1", deviceType: "Mobile",
            deviceModel: "iPhone18,1", isEmulator: false, appName: "Shop", appVersion: "4.2", appBuild: "512",
            appNamespace: "com.example.shop", screenWidth: 402, screenHeight: 874, locale: "en-US",
            timeZone: "America/New_York")
        XCTAssertEqual(context.properties, [
            "$lib": .string("elu-ios"), "$lib_version": .string("0.2.0"),
            "$os": .string("iOS"), "$os_name": .string("iOS"), "$os_version": .string("26.3.1"),
            "$device_type": .string("Mobile"), "$device_model": .string("iPhone18,1"),
            "$device_manufacturer": .string("Apple"), "$is_emulator": .bool(false),
            "$app_name": .string("Shop"), "$app_version": .string("4.2"), "$app_build": .string("512"),
            "$app_namespace": .string("com.example.shop"),
            "$screen_width": .integer(402), "$screen_height": .integer(874),
            "$locale": .string("en-US"), "$timezone": .string("America/New_York"),
        ])
    }

    func testUnknownEmptyOrPartialValuesAreOmitted() throws {
        let context = EluEventContext(lib: try lib(), osName: "", deviceModel: nil, isEmulator: true, appName: "",
            appVersion: nil, screenWidth: 402, screenHeight: 0)
        XCTAssertEqual(context.properties, [
            "$lib": .string("elu-ios"), "$lib_version": .string("0.2.0"),
            "$device_manufacturer": .string("Apple"), "$is_emulator": .bool(true),
        ])
    }

    @MainActor
    func testCurrentReadsOnlyNonIdentifyingDeviceAndAppFacts() throws {
        let allowed: Set<String> = ["$lib", "$lib_version", "$os", "$os_name", "$os_version", "$device_type",
            "$device_model", "$device_manufacturer", "$is_emulator", "$app_name", "$app_version", "$app_build",
            "$app_namespace", "$screen_width", "$screen_height", "$locale", "$timezone"]
        let properties = EluEventContext.current(lib: try lib()).properties
        XCTAssertTrue(Set(properties.keys).isSubset(of: allowed), "\(Set(properties.keys).subtracting(allowed))")
        XCTAssertEqual(properties["$lib"], .string("elu-ios"))
        #if canImport(UIKit)
        XCTAssertEqual(properties["$os_version"], .string(UIDevice.current.systemVersion))
        #endif
    }

    #if canImport(UIKit)
    func testDeviceTypeFollowsTheInterfaceIdiom() {
        XCTAssertEqual(EluEventContext.deviceType(.phone), "Mobile")
        XCTAssertEqual(EluEventContext.deviceType(.pad), "Tablet")
        if #available(iOS 14.0, *) { XCTAssertEqual(EluEventContext.deviceType(.mac), "Desktop") }
        XCTAssertNil(EluEventContext.deviceType(.unspecified))
    }
    #endif
}
