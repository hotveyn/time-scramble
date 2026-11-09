//
//  StateRepositoryTests.swift
//

import Foundation
import XCTest

@testable import time_scramble

final class StateRepositoryTests: XCTestCase {
    private let active = AppState(
        intervalMinutes: 15, sessionState: .active,
        realTimeSnapshot: RealTimeSnapshot(
            capturedAt: "2026-06-21T05:00:00Z", unixTimestamp: 1_782_018_000, monotonicNanos: 9, bootSessionID: "b"))

    func test_load_withoutFile_isMissing() {
        XCTAssertEqual(Harness(test: self).repository.load(), .missing)
    }

    func test_save_createsDirectory_andLoadReturnsSameState() throws {
        let harness = Harness(test: self)

        try harness.repository.save(active)

        XCTAssertEqual(harness.repository.load(), .loaded(active))
    }

    func test_save_writesPrettyPrintedJSON() throws {
        let harness = Harness(test: self)

        try harness.repository.save(.initial)

        let text = try String(contentsOf: harness.repository.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"))
        XCTAssertTrue(text.contains("\"realTimeSnapshot\" : null"))
    }

    func test_save_replacesFileAtomically_leavingNoTemporaryFiles() throws {
        let harness = Harness(test: self)

        try harness.repository.save(.initial)
        try harness.repository.save(active)

        XCTAssertEqual(harness.repository.load(), .loaded(active))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path), ["state.json"])
    }

    func test_save_whenDirectoryCannotBeCreated_throws() throws {
        let harness = Harness(test: self)
        try FileManager.default.createDirectory(at: harness.directory, withIntermediateDirectories: true)
        let blocker = harness.directory.appendingPathComponent("file")
        try Data().write(to: blocker)
        let repository = StateRepository(fileURL: blocker.appendingPathComponent("state.json"))

        XCTAssertThrowsError(try repository.save(.initial))
    }

    func test_load_corruptFiles_promptFreshStart() throws {
        let corrupt = [
            "not json",
            #"{ "intervalMinutes": 30, "sessionState": "running", "realTimeSnapshot": null }"#,
            #"{ "sessionState": "stopped", "realTimeSnapshot": null }"#,
            #"{ "intervalMinutes": "30", "sessionState": "stopped", "realTimeSnapshot": null }"#,
            #"{ "intervalMinutes": 500, "sessionState": "stopped", "realTimeSnapshot": null }"#,
            #"{ "intervalMinutes": 30, "sessionState": "active", "realTimeSnapshot": null }"#,
            #"{ "intervalMinutes": 30, "sessionState": "active", "realTimeSnapshot": { "capturedAt": "x", "unixTimestamp": 0 } }"#,
            #"{ "intervalMinutes": 30, "sessionState": "paused", "realTimeSnapshot": { "capturedAt": "x", "unixTimestamp": -5 } }"#,
        ]
        let harness = Harness(test: self)

        for json in corrupt {
            try harness.write(json)

            XCTAssertEqual(harness.repository.load(), .corrupt, json)
        }
    }

    func test_load_unreadableFile_isCorrupt() throws {
        let harness = Harness(test: self)
        try FileManager.default.createDirectory(at: harness.repository.fileURL, withIntermediateDirectories: true)

        XCTAssertEqual(harness.repository.load(), .corrupt)
    }

    func test_defaultLocation_isApplicationSupport() {
        XCTAssertTrue(
            StateRepository.defaultURL.path.hasSuffix("Library/Application Support/FocusTimeScrambler/state.json"))
    }
}
