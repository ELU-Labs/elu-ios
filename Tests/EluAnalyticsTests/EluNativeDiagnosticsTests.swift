import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeDiagnosticsTests: XCTestCase {
    private let beginning = Date(timeIntervalSince1970: 1_785_888_000)
    private func summary(begin: Date? = nil, end: Date? = nil, count: Int64 = 1) throws -> EluNativeDiagnosticSummary {
        try .init(kind: .diagnostic, begin: begin ?? beginning, end: end ?? beginning.addingTimeInterval(10),
                  fields: ["$crash_count": .integer(count)])
    }

    func testEpochPersistsOrdinaryObservationButIdentityOptionAndWithdrawalRestartCoverage() throws {
        let open = EluNativeDiagnosticsState.closed.reconciled(at: beginning, identityRevision: 1, mayOpen: true, launchSummaries: false)
        let epoch = try XCTUnwrap(open.epoch)
        let same = open.reconciled(at: beginning.addingTimeInterval(20), identityRevision: 1, mayOpen: true, launchSummaries: false)
        XCTAssertEqual(same.epoch, epoch)
        XCTAssertEqual(try EluNativeDiagnosticsState.decode(same.encoded()), same)
        let account = same.reconciled(at: beginning.addingTimeInterval(30), identityRevision: 2, mayOpen: true, launchSummaries: false)
        XCTAssertNotEqual(account.epoch?.id, epoch.id)
        XCTAssertNil(try account.accepting(summary(), at: beginning.addingTimeInterval(40), identityRevision: 2))
        let options = same.reconciled(at: beginning.addingTimeInterval(30), identityRevision: 1, mayOpen: true, launchSummaries: true)
        XCTAssertNotEqual(options.epoch?.id, epoch.id)
        XCTAssertNil(same.closing().epoch)
        XCTAssertNil(same.reconciled(at: beginning.addingTimeInterval(-1), identityRevision: 1, mayOpen: true, launchSummaries: false).epoch)
    }

    func testEntireOSIntervalMustFitOneKnownEpochAndCurrentClock() throws {
        let state = EluNativeDiagnosticsState.closed.reconciled(at: beginning, identityRevision: 1, mayOpen: true, launchSummaries: false)
        let now = beginning.addingTimeInterval(20)
        XCTAssertNotNil(try state.accepting(summary(), at: now, identityRevision: 1))
        XCTAssertNil(try state.accepting(summary(begin: beginning.addingTimeInterval(-1)), at: now, identityRevision: 1))
        XCTAssertNil(try state.accepting(summary(end: beginning.addingTimeInterval(21)), at: now, identityRevision: 1))
        XCTAssertNil(try state.accepting(summary(), at: now, identityRevision: 2))
        XCTAssertNil(try EluNativeDiagnosticsState.closed.accepting(summary(), at: now, identityRevision: 1))
        let launch = try EluNativeDiagnosticSummary(kind: .launch, begin: beginning, end: now,
            fields: ["$launch_first_draw_count": .integer(1), "$launch_first_draw_lower_bound_ms": .number(10), "$launch_first_draw_upper_bound_ms": .number(20)])
        XCTAssertNil(try state.accepting(launch, at: now, identityRevision: 1))
    }

    func testDeduplicationIsBoundedAndNewOSIntervalCanProgress() throws {
        var state = EluNativeDiagnosticsState.closed.reconciled(at: beginning, identityRevision: 1, mayOpen: true, launchSummaries: false)
        let now = beginning.addingTimeInterval(20)
        for count in 1...32 { state = try XCTUnwrap(state.accepting(summary(count: Int64(count)), at: now, identityRevision: 1)) }
        XCTAssertNil(try state.accepting(summary(count: 33), at: now, identityRevision: 1))
        XCTAssertNil(try state.accepting(summary(count: 1), at: now, identityRevision: 1))
        state = try XCTUnwrap(state.accepting(summary(end: beginning.addingTimeInterval(15)), at: now, identityRevision: 1))
        XCTAssertEqual(state.diagnostic?.fingerprints.count, 1)
        XCTAssertNil(try state.accepting(summary(count: 1), at: now, identityRevision: 1), "Older OS intervals cannot reappear after dedupe eviction")
    }

    func testRawTextMalformedIntervalsAndNonNumericFieldsCannotEnterSummary() throws {
        let cases: [[String: EluJSONValue]] = [[:], ["$crash_count": .integer(0)], ["$crash_count": .integer(-1)],
            ["$crash_count": .number(1)], ["$crash_count": .integer(1), "message": .string("private")],
            ["$crash_count": .integer(1), "$hang_duration_total_ms": .number(.infinity)],
            ["$crash_count": .integer(1), "$hang_duration_total_ms": .number(1)],
            ["$hang_count": .integer(1)],
            ["$hang_count": .integer(1), "$hang_duration_total_ms": .number(1), "$hang_duration_max_ms": .number(2)]]
        for fields in cases {
            XCTAssertThrowsError(try EluNativeDiagnosticSummary(kind: .diagnostic, begin: beginning,
                end: beginning.addingTimeInterval(10), fields: fields))
        }
        XCTAssertThrowsError(try summary(end: beginning))
        XCTAssertThrowsError(try summary(begin: Date(timeIntervalSince1970: .nan)))
        XCTAssertThrowsError(try EluNativeDiagnosticsState.decode(Data("{\"unknown\":true}".utf8)))
        XCTAssertThrowsError(try EluNativeDiagnosticsState.decode(Data("{\"epoch\":{}}".utf8)))
        XCTAssertEqual(try EluNativeDiagnosticsState.decode(EluNativeDiagnosticsState.closed.encoded()), .closed)
    }

    func testEveryConsentIntentKeepsGateClosedUntilItsOwnSettlement() throws {
        let gate = EluNativeDiagnosticsGate()
        let before = try XCTUnwrap(gate.token()), first = gate.begin(), second = gate.begin()
        XCTAssertFalse(gate.isCurrent(before)); XCTAssertNil(gate.token())
        gate.finish(second); XCTAssertNil(gate.token(), "A later grant cannot overtake an unsettled prior denial")
        gate.finish(first); let after = try XCTUnwrap(gate.token()); XCTAssertTrue(gate.isCurrent(after))
        XCTAssertNotEqual(before, after)
        gate.close(); XCTAssertFalse(gate.isCurrent(after)); XCTAssertNil(gate.token())
    }
    func testConsentSettlementClosesSupersededIntentsButNeverNewerAcceptance() throws {
        let gate = EluNativeDiagnosticsGate(), denial = UUID(), grant = UUID(), later = UUID()
        gate.beginConsent(denial); gate.beginConsent(grant)
        let committedIntents = gate.consentIntents()
        XCTAssertEqual(committedIntents, [denial, grant]); XCTAssertNil(gate.token())
        gate.beginConsent(later)
        gate.finishConsent(committedIntents)
        XCTAssertEqual(gate.consentIntents(), [later]); XCTAssertNil(gate.token())
        gate.finishConsent(gate.consentIntents())
        XCTAssertNotNil(gate.token())
    }

}
