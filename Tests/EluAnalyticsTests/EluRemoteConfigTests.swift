import XCTest
@testable import EluAnalytics

final class EluRemoteConfigTests: XCTestCase {
    func testParsesSupportedEnabledConfig() throws {
        let config = try TestConfigFactory.make(enabled: true, blockEu: false)

        XCTAssertEqual(config.schemaVersion, 1)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.publicToken, "fixture-token")
        XCTAssertEqual(config.host, "https://ingest.example.test")
        XCTAssertFalse(config.privacy.blockEu)
    }

    func testParsesSupportedDisabledConfigWithoutRuntimeFields() throws {
        let config = try TestConfigFactory.make(enabled: false)

        XCTAssertEqual(config.schemaVersion, 1)
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.publicToken, "")
        XCTAssertEqual(config.host, "")
        XCTAssertEqual(config.privacy, .webDefaults)
    }

    func testRejectsMissingOrUnsupportedSchemaVersion() {
        XCTAssertThrowsError(try EluRemoteConfig.parse(Data(#"{"enabled":false}"#.utf8)))
        XCTAssertThrowsError(try EluRemoteConfig.parse(Data(#"{"v":2,"enabled":false}"#.utf8)))
        XCTAssertThrowsError(try EluRemoteConfig.parse(Data(#"{"v":0,"enabled":false}"#.utf8)))
    }

    func testEnabledConfigRequiresTokenAndAbsoluteHost() {
        XCTAssertThrowsError(
            try EluRemoteConfig.parse(Data(#"{"v":1,"enabled":true,"host":"https://ingest.example.test"}"#.utf8))
        )
        XCTAssertThrowsError(
            try EluRemoteConfig.parse(Data(#"{"v":1,"enabled":true,"publicToken":"token"}"#.utf8))
        )
    }

    func testPrivacyFieldsDecodeIndependentlyWithFailClosedDefaults() throws {
        let data = Data(
            #"{"v":1,"enabled":true,"publicToken":"token","host":"https://ingest.example.test","privacy":{"blockEu":"wrong","maskTextInputs":false,"maskImages":true,"replayMaxMinutes":2.9}}"#.utf8
        )
        let config = try EluRemoteConfig.parse(data)

        XCTAssertTrue(config.privacy.blockEu)
        XCTAssertFalse(config.privacy.maskTextInputs)
        XCTAssertFalse(config.privacy.maskAllText)
        XCTAssertTrue(config.privacy.maskImages)
        XCTAssertEqual(config.privacy.replayMaxMinutes, 2)
    }

    func testReplayMinuteRangeUsesUnlimitedSentinel() {
        XCTAssertEqual(EluPrivacyConfig.clampMinutes(nil), 0)
        XCTAssertEqual(EluPrivacyConfig.clampMinutes(.nan), 0)
        XCTAssertEqual(EluPrivacyConfig.clampMinutes(-1), 0)
        XCTAssertEqual(EluPrivacyConfig.clampMinutes(0), 0)
        XCTAssertEqual(EluPrivacyConfig.clampMinutes(1.9), 1)
        XCTAssertEqual(EluPrivacyConfig.clampMinutes(60), 60)
        XCTAssertEqual(EluPrivacyConfig.clampMinutes(61), 0)
    }
}
