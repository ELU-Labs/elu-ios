import Foundation
import XCTest
@testable import EluAnalytics

/// The provider-free facade constructs one owned runtime and retains its
/// original ordered initialization, closed readiness and callback semantics.
final class EluRuntimeSelectorTests: XCTestCase {
    private struct SelectorFailure: Error {}

    // Any port on the loopback interface that refuses immediately: setup
    // always starts a config request, and no test here wants one to leave.
    private let inertConfigHost = URL(string: "http://127.0.0.1:9")!

    func testSelectorDefaultsToTheOwnedRuntime() {
        XCTAssertEqual(EluSetupOptions().runtimeSelection, .standalone)
        XCTAssertEqual(
            EluSetupOptions(configHost: inertConfigHost).runtimeSelection,
            .standalone
        )
    }

    func testConsentBeforeSetupIsRetainedOutsideTheBoundedEventBuffer() throws {
        let factory = SelectorSpy()
        let core = EluCore(backendFactory: factory.factory)
        core.setConsent(optedOut: true)
        core.setup(siteKey: uniqueSiteKey(), options: EluSetupOptions(configHost: inertConfigHost))
        for index in 0 ..< 150 { core.dispatch(.capture(event: "private-\(index)", properties: nil)) }
        XCTAssertTrue(core.isOptedOut())
        let backend = try XCTUnwrap(core.backendForTesting() as? SelectorBackend)
        XCTAssertEqual(backend.recordedCalls(), ["optOut"])
        backend.announceConfigurationReady()
        drain(core)
        XCTAssertEqual(backend.recordedCalls(), ["optOut", "activate"])
        core.reset()
        drain(core)
        XCTAssertTrue(core.isOptedOut())
        XCTAssertEqual(backend.recordedCalls().last, "reset")
    }

    func testRepeatedSetupKeepsTheOriginalBackendAndBufferedCalls() throws {
        let factory = SelectorSpy()
        let core = EluCore(backendFactory: factory.factory)
        core.setup(siteKey: uniqueSiteKey(), options: EluSetupOptions(configHost: inertConfigHost))
        core.dispatch(.capture(event: "original", properties: nil))
        let original = try XCTUnwrap(core.backendForTesting())
        core.setup(siteKey: uniqueSiteKey(), options: EluSetupOptions(configHost: inertConfigHost))
        XCTAssertTrue(core.backendForTesting() === original)
        XCTAssertEqual(factory.requestedSelections(), [.standalone])
        try activate(core)
        XCTAssertEqual(factory.backend(for: .standalone)?.recordedCalls(), ["capture(original)", "activate"])
    }

    func testEveryFacadeMethodReachesTheOwnedRuntimeInOrder() throws {
        let factory = SelectorSpy()
        let core = try runningCore(selection: .standalone, factory: factory)

        exerciseEveryMethod(on: core)

        XCTAssertEqual(factory.requestedSelections(), [.standalone])
        let backend = try XCTUnwrap(factory.backend(for: .standalone))
        XCTAssertEqual(backend.recordedCalls(), Self.everyMethodInCallOrder)
    }

    func testDefaultFactoryBuildsTheOwnedRuntimeForTheStandaloneSelection() throws {
        let context = try context(siteKey: "elu_pk_selector_owned")
        let backend = try XCTUnwrap(
            EluCore.defaultBackendFactory.make(.standalone, context)
        )
        XCTAssertTrue(backend is EluStandaloneFacadeRuntime)
        XCTAssertEqual(backend.selection, .standalone)
        // Native capture uses its owned authority/occupancy lane; this legacy
        // unguarded replay-control seam is never supplied.
        XCTAssertNil(backend.replayControl)
        backend.shutDown()
    }

    func testInvalidOriginalReadinessKeepsBufferClosedAndCurrentReadinessActivatesOnce() throws {
        let factory = SelectorSpy()
        let core = EluCore(backendFactory: factory.factory)
        core.setup(siteKey: uniqueSiteKey(), options: EluSetupOptions(configHost: inertConfigHost))
        core.dispatch(.identify(distinctId: "held", userProperties: nil))
        let backend = try XCTUnwrap(core.backendForTesting() as? SelectorBackend)
        backend.announceConfigurationReady(ifCurrent: { false })
        drain(core)
        XCTAssertEqual(backend.recordedCalls(), [])
        XCTAssertNil(core.distinctId())
        backend.announceConfigurationReady()
        backend.announceConfigurationReady()
        drain(core)
        XCTAssertEqual(backend.recordedCalls(), ["identify(held)", "activate"])
    }

    func testPreConfigCallsReplayInCallOrderOnceTheRuntimeIsSelected() throws {
        let factory = SelectorSpy()
        let core = EluCore(backendFactory: factory.factory)
        core.setup(
            siteKey: uniqueSiteKey(),
            options: options(selection: .standalone)
        )

        core.dispatch(.capture(event: "before-one", properties: nil))
        core.dispatch(.identify(distinctId: "user-1", userProperties: nil))
        core.reset()
        core.dispatch(.capture(event: "before-two", properties: nil))
        // The owned source can start, but calls remain in the capped initial
        // buffer until its first original, live document settles.
        XCTAssertNotNil(core.backendForTesting())
        XCTAssertEqual(factory.requestedSelections(), [.standalone])
        XCTAssertEqual(factory.backend(for: .standalone)?.recordedCalls(), [])

        try activate(core)
        let backend = try XCTUnwrap(factory.backend(for: .standalone))
        XCTAssertEqual(
            backend.recordedCalls(),
            [
                "capture(before-one)",
                "identify(user-1)",
                "reset",
                "capture(before-two)",
                "activate",
            ]
        )
    }

    func testPreConfigBufferKeepsTheNewestCallsAtItsCapAndCountsTheRest() throws {
        let factory = SelectorSpy()
        let core = EluCore(backendFactory: factory.factory)
        core.setup(
            siteKey: uniqueSiteKey(),
            options: options(selection: .standalone)
        )

        let overflow = 25
        let total = EluEventBuffer.capacity + overflow
        for index in 0 ..< total {
            core.dispatch(.capture(event: "event-\(index)", properties: nil))
        }
        XCTAssertEqual(core.bufferDropCountForTesting(), overflow)

        try activate(core)
        let backend = try XCTUnwrap(factory.backend(for: .standalone))
        let replayed = backend.recordedCalls().filter { $0.hasPrefix("capture(") }
        XCTAssertEqual(replayed.count, EluEventBuffer.capacity)
        XCTAssertEqual(replayed.first, "capture(event-\(overflow))")
        XCTAssertEqual(replayed.last, "capture(event-\(total - 1))")
    }

    func testPendingOwnedRuntimeDoesNotExposeGettersOrFlushBeforeReadiness() throws {
        let factory = SelectorSpy()
        let core = EluCore(backendFactory: factory.factory)
        core.setup(siteKey: uniqueSiteKey(), options: EluSetupOptions(configHost: inertConfigHost))
        let backend = try XCTUnwrap(core.backendForTesting() as? SelectorBackend)
        backend.stubbedDistinctId = "not-yet-published"
        backend.stubbedFlags = ["variant": "hidden"]
        XCTAssertNil(core.distinctId())
        XCTAssertNil(core.getFeatureFlag("variant"))
        XCTAssertNil(core.getFeatureFlagPayload("variant"))
        XCTAssertFalse(core.isFeatureEnabled("variant"))
        core.flush()
        drain(core)
        XCTAssertEqual(backend.recordedCalls(), [])
    }

    func testARuntimeThatCannotBeCreatedLeavesTheFacadeDisabled() throws {
        let core = EluCore(
            backendFactory: EluRuntimeBackendFactory { _, _ in nil }
        )
        core.setup(siteKey: uniqueSiteKey(), options: options(selection: .standalone))
        core.dispatch(.capture(event: "held", properties: nil))
        try activate(core)

        XCTAssertNil(core.backendForTesting())
        XCTAssertNil(core.distinctId())
        XCTAssertNil(core.getFeatureFlag("variant"))
        XCTAssertFalse(core.isFeatureEnabled("variant"))

        // Later calls are silent no-ops rather than a running state with
        // nothing behind it.
        core.dispatch(.capture(event: "after", properties: nil))
        core.flush()
        drain(core)
    }

    func testOwnedGettersFollowTheOriginalReadyBackend() throws {
        let factory = SelectorSpy()
        let core = try runningCore(selection: .standalone, factory: factory)
        let backend = try XCTUnwrap(factory.backend(for: .standalone))
        backend.stubbedDistinctId = "anon_owned"
        backend.stubbedFlags = ["variant": "variant-a"]
        XCTAssertEqual(core.distinctId(), "anon_owned")
        XCTAssertEqual(core.getFeatureFlag("variant") as? String, "variant-a")
        XCTAssertTrue(core.isFeatureEnabled("variant"))
        XCTAssertFalse(core.isFeatureEnabled("absent"))
    }

    func testFlagCallbacksRunInRegistrationOrderOnTheMainQueue() throws {
        let factory = SelectorSpy()
        let core = try runningCore(selection: .standalone, factory: factory)
        let backend = try XCTUnwrap(factory.backend(for: .standalone))

        let order = CallOrderRecorder()
        let fired = expectation(description: "both callbacks")
        fired.expectedFulfillmentCount = 2
        core.onFeatureFlagsLoaded {
            XCTAssertTrue(Thread.isMainThread)
            order.append("first")
            fired.fulfill()
        }
        core.onFeatureFlagsLoaded {
            XCTAssertTrue(Thread.isMainThread)
            order.append("second")
            fired.fulfill()
        }
        drain(core)

        backend.announceFlagsLoaded()
        wait(for: [fired], timeout: 5)
        XCTAssertEqual(order.values(), ["first", "second"])
    }

    func testLateListenerFiresImmediatelyOnceTheOwnedRuntimeHasLoadedFlags() throws {
        let factory = SelectorSpy()
        let core = try runningCore(selection: .standalone, factory: factory)
        let backend = try XCTUnwrap(factory.backend(for: .standalone))
        backend.flagsAreLoaded = true

        let fired = expectation(description: "late listener")
        core.onFeatureFlagsLoaded {
            XCTAssertTrue(Thread.isMainThread)
            fired.fulfill()
        }
        wait(for: [fired], timeout: 5)
    }

    func testReloadCompletionRunsOnceOnTheMainQueueBeforeARuntimeExists() throws {
        let core = EluCore(backendFactory: SelectorSpy().factory)
        core.setup(siteKey: uniqueSiteKey(), options: options(selection: .standalone))

        let fired = expectation(description: "reload completion")
        core.reloadFeatureFlags {
            XCTAssertTrue(Thread.isMainThread)
            fired.fulfill()
        }
        wait(for: [fired], timeout: 5)
    }

    // MARK: - Helpers

    private static let everyMethodInCallOrder = [
        // Activation is the first thing a freshly selected runtime is told:
        // the pre-config buffer (empty here) has been replayed.
        "activate",
        "capture(checkout)",
        "screen(Cart)",
        "captureException",
        "identify(user-1)",
        "alias(alias-1)",
        "register",
        "unregister(plan)",
        "group(company/acme)",
        "setPersonProperties",
        "setPersonPropertiesForFlags",
        "setGroupPropertiesForFlags(company)",
        "reset",
        "flush",
        "distinctId",
        "featureFlag(variant)",
        "featureFlagPayload(variant)",
        "isFeatureEnabled(variant)",
        "reloadFeatureFlags",
    ]

    private func exerciseEveryMethod(on core: EluCore) {
        core.dispatch(.capture(event: "checkout", properties: ["amount": 42]))
        core.dispatch(.screen(name: "Cart", properties: nil))
        core.dispatch(.captureException(SelectorFailure(), properties: nil))
        core.dispatch(.identify(distinctId: "user-1", userProperties: ["plan": "pro"]))
        core.dispatch(.alias("alias-1"))
        core.dispatch(.register(["plan": "pro"]))
        core.dispatch(.unregister("plan"))
        core.dispatch(.group(type: "company", key: "acme", properties: nil))
        core.dispatch(.setPersonProperties(["plan": "pro"]))
        core.dispatch(.setPersonPropertiesForFlags(["plan": "pro"]))
        core.dispatch(.setGroupPropertiesForFlags(type: "company", properties: ["tier": "gold"]))
        core.reset()
        core.flush()
        _ = core.distinctId()
        _ = core.getFeatureFlag("variant")
        _ = core.getFeatureFlagPayload("variant")
        _ = core.isFeatureEnabled("variant")

        let reloaded = expectation(description: "reload")
        core.reloadFeatureFlags { reloaded.fulfill() }
        wait(for: [reloaded], timeout: 5)
    }

    private func runningCore(
        selection: EluRuntimeSelection,
        factory: SelectorSpy
    ) throws -> EluCore {
        let core = EluCore(backendFactory: factory.factory)
        core.setup(siteKey: uniqueSiteKey(), options: options(selection: selection))
        try activate(core)
        XCTAssertNotNil(core.backendForTesting())
        return core
    }

    /// Delivers an enabled configuration exactly as a successful fetch would.
    /// `blockEu` is off so the region policy cannot change the outcome with
    /// the machine running the test.
    private func activate(_ core: EluCore) throws {
        (core.backendForTesting() as? SelectorBackend)?.announceConfigurationReady()
        drain(core)
    }

    /// The state machine runs on its own serial queue. Reading a value that
    /// never touches the selected runtime returns only once everything queued
    /// ahead of it has been applied, without recording a call of its own.
    private func drain(_ core: EluCore) {
        _ = core.bufferDropCountForTesting()
    }

    private func options(selection: EluRuntimeSelection) -> EluSetupOptions {
        var options = EluSetupOptions(configHost: inertConfigHost)
        options.runtimeSelection = selection
        return options
    }

    private func context(
        siteKey: String,
        replayNewUsersOnly: Bool = false
    ) throws -> EluRuntimeBackendContext {
        let json = """
        {
          "v": 1,
          "enabled": true,
          "publicToken": "fixture-token",
          "host": "https://ingest.example.test",
          "privacy": {
            "blockEu": false,
            "maskTextInputs": true,
            "maskAllText": false,
            "maskImages": false,
            "replayNewUsersOnly": \(replayNewUsersOnly),
            "replayMaxMinutes": 0
          }
        }
        """
        return EluRuntimeBackendContext(
            siteKey: siteKey,
            config: try EluRemoteConfig.parse(Data(json.utf8)),
            configDocument: Data(json.utf8),
            isNewUser: false,
            flagsDidLoad: {},
            configHost: inertConfigHost
        )
    }

    private func uniqueSiteKey() -> String {
        "elu_pk_selector_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }


}

/// Records which selection the facade asked for and every call the runtime it
/// returned received. One instance can hand out at most one runtime per
/// selection, so a test can assert that the other one was never built.
final class SelectorSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [EluRuntimeSelection] = []
    private var backends: [EluRuntimeSelection: SelectorBackend] = [:]

    var factory: EluRuntimeBackendFactory {
        EluRuntimeBackendFactory { [self] selection, context in
            lock.lock()
            requested.append(selection)
            let backend = SelectorBackend(
                selection: selection,
                flagsDidLoad: context.flagsDidLoad,
                configurationReady: context.initialConfigurationReady
            )
            backends[selection] = backend
            lock.unlock()
            return backend
        }
    }

    func requestedSelections() -> [EluRuntimeSelection] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func backend(for selection: EluRuntimeSelection) -> SelectorBackend? {
        lock.lock()
        defer { lock.unlock() }
        return backends[selection]
    }
}

/// A runtime that records what it was asked to do instead of doing it.
final class SelectorBackend: EluRuntimeBackend, @unchecked Sendable {
    let selection: EluRuntimeSelection
    let replayControl: (any EluReplayControl)? = nil

    private let lock = NSLock()
    private let flagsDidLoad: () -> Void
    private let configurationReady: (@escaping @Sendable () -> Bool) -> Void
    private var calls: [String] = []
    private var shutDowns = 0
    private var loaded = false
    private var distinctIdValue: String?
    private var flags: [String: String] = [:]

    init(selection: EluRuntimeSelection, flagsDidLoad: @escaping () -> Void,
         configurationReady: @escaping (@escaping @Sendable () -> Bool) -> Void = { _ in }) {
        self.selection = selection
        self.flagsDidLoad = flagsDidLoad
        self.configurationReady = configurationReady
    }

    func announceConfigurationReady(ifCurrent: @escaping @Sendable () -> Bool = { true }) {
        configurationReady(ifCurrent)
    }

    var flagsAreLoaded: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return loaded
        }
        set {
            lock.lock()
            loaded = newValue
            lock.unlock()
        }
    }

    var stubbedDistinctId: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return distinctIdValue
        }
        set {
            lock.lock()
            distinctIdValue = newValue
            lock.unlock()
        }
    }

    var stubbedFlags: [String: String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return flags
        }
        set {
            lock.lock()
            flags = newValue
            lock.unlock()
        }
    }

    func execute(_ op: EluBufferedOp) {
        switch op {
        case let .capture(event, _): record("capture(\(event))")
        case let .screen(name, _): record("screen(\(name))")
        case .captureException: record("captureException")
        case let .identify(distinctId, _, _): record("identify(\(distinctId))")
        case let .alias(alias): record("alias(\(alias))")
        case .register: record("register")
        case .registerOnce: record("registerOnce")
        case let .consent(operation): record(operation.optedOut ? "optOut" : "optIn")
        case let .unregister(key): record("unregister(\(key))")
        case let .group(type, key, _): record("group(\(type)/\(key))")
        case .setPersonProperties: record("setPersonProperties")
        case .setPersonPropertiesForFlags: record("setPersonPropertiesForFlags")
        case let .setGroupPropertiesForFlags(type, _):
            record("setGroupPropertiesForFlags(\(type))")
        case .reset: record("reset")
        case .resetGroups: record("resetGroups")
        case .resetPersonPropertiesForFlags: record("resetPersonPropertiesForFlags")
        case .resetGroupPropertiesForFlags: record("resetGroupPropertiesForFlags")
        }
    }

    func activate() { record("activate") }

    func distinctId() -> String? {
        record("distinctId")
        return stubbedDistinctId
    }

    func featureFlag(_ key: String) -> Any? {
        record("featureFlag(\(key))")
        return stubbedFlags[key]
    }

    func featureFlagPayload(_ key: String) -> Any? {
        record("featureFlagPayload(\(key))")
        return nil
    }

    func isFeatureEnabled(_ key: String) -> Bool {
        record("isFeatureEnabled(\(key))")
        return stubbedFlags[key] != nil
    }

    func reloadFeatureFlags(_ completion: (() -> Void)?) {
        record("reloadFeatureFlags")
        if let completion { DispatchQueue.main.async(execute: completion) }
    }

    func flush() { record("flush") }

    func shutDown() {
        lock.lock()
        shutDowns += 1
        lock.unlock()
    }

    func recordedCalls() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func shutDownCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return shutDowns
    }

    /// Announces a flag load the way the selected runtime does.
    func announceFlagsLoaded() {
        flagsAreLoaded = true
        flagsDidLoad()
    }

    private func record(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }
}

/// Registration-order recorder for callbacks delivered on the main queue.
final class CallOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
