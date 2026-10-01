import Foundation
import XCTest
@testable import EluAnalytics

final class EluFacadeConcurrencyTests: XCTestCase {
    private struct FixtureError: Error {}

    func testDeclaredRegionReplayDefaultsOffForEveryExistingSetupInitializer() {
        let host = URL(string: "https://elu.dev")!
        for options in [EluSetupOptions(), EluSetupOptions(configHost: host),
                        EluSetupOptions(configHost: host, apiHost: nil),
                        EluSetupOptions(configHost: host, performance: .init(enabled: true))] {
            XCTAssertFalse(options.declaredRegionReplayEnabled)
        }
        XCTAssertFalse(EluRuntimeBackendContext(siteKey: "unused", isNewUser: false,
                                               flagsDidLoad: {}).declaredRegionReplayEnabled)
    }

    func testDeclaredRegionSelectionIsCopiedOnceAndSecondSetupCannotReplaceIt() throws {
        for selected in [false, true] {
            let observed = DeclaredSetupObservations()
            let core = EluCore(backendFactory: observed.factory)
            var options = EluSetupOptions()
            options.persistence = .memory
            options.declaredRegionReplayEnabled = selected
            let siteKey = "elu_pk_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            core.setup(siteKey: siteKey, options: options)
            // Mutation and another setup occur before the first async setup is
            // necessarily executed. Neither can replace its copied value.
            options.declaredRegionReplayEnabled = !selected
            core.setup(siteKey: "replacement", options: options)
            let backend = try XCTUnwrap(core.backendForTesting() as? SelectorBackend)
            let values = observed.read()
            XCTAssertEqual(values.count, 1)
            let first = try XCTUnwrap(values.first)
            XCTAssertEqual(first.siteKey, siteKey)
            XCTAssertEqual(first.declaredRegionReplayEnabled, selected)
            XCTAssertEqual(backend.selection, .standalone)
            XCTAssertFalse(core.sessionRecordingStarted(), "Local opt-in cannot announce capture")
        }
    }

    func testDeclaredRegionOptInPreservesOriginalPreSetupConsentAndPendingState() throws {
        let observed = DeclaredSetupObservations()
        let core = EluCore(backendFactory: observed.factory)
        core.setConsent(optedOut: true)
        var options = EluSetupOptions()
        options.persistence = .memory
        options.declaredRegionReplayEnabled = true
        core.setup(siteKey: "elu_pk_test_" + String(repeating: "a", count: 22), options: options)
        let backend = try XCTUnwrap(core.backendForTesting() as? SelectorBackend)
        let context = try XCTUnwrap(observed.read().first)
        XCTAssertTrue(context.declaredRegionReplayEnabled)
        XCTAssertEqual(context.initialConsent?.optedOut, true)
        XCTAssertEqual(backend.recordedCalls(), ["optOut"])
        XCTAssertTrue(core.isOptedOut())
        XCTAssertFalse(core.sessionRecordingStarted())
    }

    func testFacadeDefaultsAreSafeBeforeSetup() {
        XCTAssertNil(Elu.distinctId())
        XCTAssertNil(Elu.getFeatureFlag("missing"))
        XCTAssertNil(Elu.getFeatureFlagPayload("missing"))
        XCTAssertFalse(Elu.isFeatureEnabled("missing"))
        XCTAssertNil(Elu.getFeatureFlag("missing", options: .init(sendEvent: false)))
        XCTAssertNil(Elu.getFeatureFlagResult("missing", options: .init(fresh: true)))
        XCTAssertNil(Elu.isFeatureEnabled("missing", options: .init()))
        XCTAssertEqual(Elu.isFeatureEnabled("missing", options: .init(), defaultValue: true), true)
        XCTAssertEqual(Elu.isFeatureEnabled("missing", options: .init(), defaultValue: false), false)
    }

    func testPreSetupCallsFromConcurrentQueuesDoNotThrowOrBlock() {
        let completed = expectation(description: "concurrent facade calls")
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                Elu.capture("event-\(index)", properties: ["index": index])
                Elu.identify("user-\(index)")
                Elu.screen("screen-\(index)")
                Elu.alias("alias-\(index)")
                Elu.register(["index": index])
                Elu.unregister("index")
                Elu.group("company", key: "company-\(index)")
                Elu.setPersonProperties(["index": index])
                Elu.setPersonPropertiesForFlags(["index": index])
                Elu.setGroupPropertiesForFlags("company", properties: ["index": index])
                Elu.captureException(FixtureError())
                Elu.reset()
                Elu.flush()
            }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 5)
        XCTAssertNil(Elu.distinctId())
    }

    func testReloadCompletionBeforeSetupIsDeliveredOnceOnMainQueue() {
        let completed = expectation(description: "reload completion")
        var callCount = 0

        Elu.reloadFeatureFlags {
            XCTAssertTrue(Thread.isMainThread)
            callCount += 1
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(callCount, 1)
    }
}

private final class DeclaredSetupObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [EluRuntimeBackendContext] = []
    var factory: EluRuntimeBackendFactory {
        .init { [self] selection, context in
            lock.lock(); contexts.append(context); lock.unlock()
            return SelectorBackend(selection: selection, flagsDidLoad: context.flagsDidLoad,
                                   configurationReady: context.initialConfigurationReady)
        }
    }
    func read() -> [EluRuntimeBackendContext] {
        lock.lock(); defer { lock.unlock() }; return contexts
    }
}
