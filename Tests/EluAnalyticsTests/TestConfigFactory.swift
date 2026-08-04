import Foundation
@testable import EluAnalytics

enum TestConfigFactory {
    static func make(enabled: Bool = true, blockEu: Bool = false) throws -> EluRemoteConfig {
        let json: String
        if enabled {
            json = """
            {
              "v": 1,
              "enabled": true,
              "publicToken": "fixture-token",
              "host": "https://ingest.example.test",
              "privacy": {
                "blockEu": \(blockEu),
                "maskTextInputs": true,
                "maskAllText": false,
                "maskImages": false,
                "replayNewUsersOnly": false,
                "replayMaxMinutes": 0
              }
            }
            """
        } else {
            json = """
            { "v": 1, "enabled": false }
            """
        }
        return try EluRemoteConfig.parse(Data(json.utf8))
    }
}
