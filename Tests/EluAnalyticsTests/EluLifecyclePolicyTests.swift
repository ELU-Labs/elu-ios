import XCTest
@testable import EluAnalytics

final class EluLifecyclePolicyTests: XCTestCase {
    func testNoCacheStartsPending() {
        let decision = EluLifecyclePolicy.initial(cached: nil, deviceInEu: false)

        XCTAssertEqual(decision, EluStateDecision(state: .pending, disabledReason: nil))
    }

    func testDisabledCacheFailsClosed() throws {
        let config = try TestConfigFactory.make(enabled: false)
        let decision = EluLifecyclePolicy.initial(cached: config, deviceInEu: false)

        XCTAssertEqual(decision, EluStateDecision(state: .disabled, disabledReason: .remoteDisabled))
    }

    func testEuDeviceIsBlockedWhenPolicyRequiresIt() throws {
        let config = try TestConfigFactory.make(enabled: true, blockEu: true)
        let decision = EluLifecyclePolicy.activation(for: config, deviceInEu: true)

        XCTAssertEqual(decision, EluStateDecision(state: .disabled, disabledReason: .euBlocked))
    }

    func testEnabledNonEuDeviceRuns() throws {
        let config = try TestConfigFactory.make(enabled: true, blockEu: true)
        let decision = EluLifecyclePolicy.activation(for: config, deviceInEu: false)

        XCTAssertEqual(decision, EluStateDecision(state: .running, disabledReason: nil))
    }

    func testOnlyNeverInitializedRemoteDisableCanReactivate() throws {
        let enabled = try TestConfigFactory.make(enabled: true, blockEu: false)

        XCTAssertTrue(
            EluLifecyclePolicy.shouldReactivate(
                disabledReason: .remoteDisabled,
                runtimeWasInitialized: false,
                config: enabled,
                deviceInEu: false
            )
        )
        XCTAssertFalse(
            EluLifecyclePolicy.shouldReactivate(
                disabledReason: .remoteDisabled,
                runtimeWasInitialized: true,
                config: enabled,
                deviceInEu: false
            )
        )
        XCTAssertFalse(
            EluLifecyclePolicy.shouldReactivate(
                disabledReason: .killSwitch,
                runtimeWasInitialized: true,
                config: enabled,
                deviceInEu: false
            )
        )
    }
}
