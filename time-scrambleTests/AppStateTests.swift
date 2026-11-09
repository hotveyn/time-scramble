//
//  AppStateTests.swift
//

import Foundation
import XCTest

@testable import time_scramble

final class AppStateTests: XCTestCase {
    private let activeExample = """
        {
          "intervalMinutes": 30,
          "sessionState": "active",
          "realTimeSnapshot": { "capturedAt": "2026-06-21T09:00:00Z", "unixTimestamp": 1750500000.0 }
        }
        """

    func test_decodesDocumentedActiveExample() throws {
        let state = try JSONDecoder().decode(AppState.self, from: Data(activeExample.utf8))

        XCTAssertEqual(state.intervalMinutes, 30)
        XCTAssertEqual(state.sessionState, .active)
        XCTAssertEqual(
            state.realTimeSnapshot, RealTimeSnapshot(capturedAt: "2026-06-21T09:00:00Z", unixTimestamp: 1_750_500_000))
        XCTAssertTrue(state.isValid)
    }

    func test_decodesDocumentedStoppedExampleWithNullSnapshot() throws {
        let json = #"{ "intervalMinutes": 30, "sessionState": "stopped", "realTimeSnapshot": null }"#

        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))

        XCTAssertEqual(state, .initial)
    }

    func test_encodingStoppedState_writesExplicitNullSnapshot() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppState.initial)) as? [String: Any]

        XCTAssertEqual(object?["intervalMinutes"] as? Int, 30)
        XCTAssertEqual(object?["sessionState"] as? String, "stopped")
        XCTAssertTrue(object?["realTimeSnapshot"] is NSNull)
    }

    func test_encodingSnapshotWithoutAnchor_matchesDocumentedShape() throws {
        let state = try JSONDecoder().decode(AppState.self, from: Data(activeExample.utf8))

        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        let snapshot = object?["realTimeSnapshot"] as? [String: Any]

        XCTAssertEqual(Set(snapshot?.keys.map { $0 } ?? []), ["capturedAt", "unixTimestamp"])
    }

    func test_roundTripKeepsMonotonicAnchor() throws {
        let state = AppState(
            intervalMinutes: 7, sessionState: .paused,
            realTimeSnapshot: RealTimeSnapshot(
                capturedAt: "x", unixTimestamp: 1, monotonicNanos: 42, bootSessionID: "boot"))

        XCTAssertEqual(try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state)), state)
    }

    func test_unknownSessionState_failsToDecode() {
        let json = #"{ "intervalMinutes": 30, "sessionState": "running", "realTimeSnapshot": null }"#

        XCTAssertThrowsError(try JSONDecoder().decode(AppState.self, from: Data(json.utf8)))
    }

    func test_validation_rejectsIntervalOutsideOneToOneHundredTwenty() {
        XCTAssertFalse(AppState(intervalMinutes: 0, sessionState: .stopped, realTimeSnapshot: nil).isValid)
        XCTAssertFalse(AppState(intervalMinutes: 121, sessionState: .stopped, realTimeSnapshot: nil).isValid)
        XCTAssertTrue(AppState(intervalMinutes: 1, sessionState: .stopped, realTimeSnapshot: nil).isValid)
        XCTAssertTrue(AppState(intervalMinutes: 120, sessionState: .stopped, realTimeSnapshot: nil).isValid)
    }

    func test_validation_requiresSnapshotWhileActiveOrPaused() {
        let snapshot = RealTimeSnapshot(capturedAt: "x", unixTimestamp: 1)

        XCTAssertFalse(AppState(intervalMinutes: 30, sessionState: .active, realTimeSnapshot: nil).isValid)
        XCTAssertFalse(AppState(intervalMinutes: 30, sessionState: .paused, realTimeSnapshot: nil).isValid)
        XCTAssertTrue(AppState(intervalMinutes: 30, sessionState: .paused, realTimeSnapshot: snapshot).isValid)
    }

    func test_validation_rejectsNonPositiveOrNonFiniteTimestamps() {
        for bad in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            let snapshot = RealTimeSnapshot(capturedAt: "x", unixTimestamp: bad)

            XCTAssertFalse(snapshot.isValid, "\(bad)")
            XCTAssertFalse(AppState(intervalMinutes: 30, sessionState: .active, realTimeSnapshot: snapshot).isValid)
        }
    }

    func test_parseInterval_acceptsWholeMinutesFromOneToOneHundredTwenty() throws {
        XCTAssertEqual(try AppState.parseInterval("1"), 1)
        XCTAssertEqual(try AppState.parseInterval(" 45 "), 45)
        XCTAssertEqual(try AppState.parseInterval("120"), 120)
    }

    func test_parseInterval_rejectsZeroNegativeAndTooLarge() {
        for text in ["0", "-5", "121", "200"] {
            XCTAssertThrowsError(try AppState.parseInterval(text)) {
                XCTAssertEqual($0 as? AppState.IntervalError, .outOfRange, text)
            }
        }
    }

    func test_parseInterval_rejectsNonNumericInput() {
        for text in ["abc", "1.5", "", "10 min"] {
            XCTAssertThrowsError(try AppState.parseInterval(text)) {
                XCTAssertEqual($0 as? AppState.IntervalError, .notAWholeNumber, text)
            }
        }
    }

    func test_intervalErrors_areHumanReadable() {
        XCTAssertEqual(
            AppState.IntervalError.outOfRange.localizedDescription, "The interval must be from 1 to 120 minutes.")
        XCTAssertEqual(
            AppState.IntervalError.notAWholeNumber.localizedDescription,
            "Enter the interval as a whole number of minutes, from 1 to 120.")
    }
}
