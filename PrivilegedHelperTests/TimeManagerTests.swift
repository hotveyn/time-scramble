//
//  TimeManagerTests.swift
//  TimeManager with injected clock and launchctl; the real settimeofday and launchctl never run here.
//

import Foundation
import XCTest

final class TimeManagerTests: XCTestCase {
    private final class Recorder {
        var clockCalls: [Double] = []
        var clockSucceeds = true
        var launchctlCalls: [[String]] = []
        var timedLoaded = true
        var commandStatus: Int32 = 0
    }

    private func makeManager(_ recorder: Recorder) -> TimeManager {
        TimeManager(
            setClock: {
                recorder.clockCalls.append($0)
                return recorder.clockSucceeds
            },
            launchctl: {
                recorder.launchctlCalls.append($0)
                if $0.first == "print" { return recorder.timedLoaded ? 0 : 113 }
                return recorder.commandStatus
            })
    }

    private func reply(_ call: (@escaping (Error?) -> Void) -> Void) -> Error? {
        var result: Error?
        var replied = 0
        call {
            result = $0
            replied += 1
        }
        XCTAssertEqual(replied, 1, "exactly one reply")
        return result
    }

    func test_setAndRestore_passTimestampToClock() {
        let recorder = Recorder()
        let manager = makeManager(recorder)

        XCTAssertNil(reply { manager.setSystemTime(to: 1_782_000_000.25, withReply: $0) })
        XCTAssertNil(reply { manager.restoreSystemTime(to: 1_782_018_600, withReply: $0) })

        XCTAssertEqual(recorder.clockCalls, [1_782_000_000.25, 1_782_018_600])
    }

    func test_invalidTimestamps_reply1003_withoutTouchingClock() {
        let recorder = Recorder()
        let manager = makeManager(recorder)

        for bad in [0, -1, Double.nan, Double.infinity, -Double.infinity, 1e300] {
            let error = reply { manager.restoreSystemTime(to: bad, withReply: $0) } as NSError?

            XCTAssertEqual(error?.domain, "com.focustimescrambler.helper", "\(bad)")
            XCTAssertEqual(error?.code, 1003, "\(bad)")
        }
        XCTAssertTrue(recorder.clockCalls.isEmpty)
    }

    func test_clockRefused_replies1001() {
        let recorder = Recorder()
        recorder.clockSucceeds = false
        let manager = makeManager(recorder)

        let error = reply { manager.setSystemTime(to: 1_782_000_000, withReply: $0) } as NSError?

        XCTAssertEqual(error?.code, 1001)
    }

    func test_disableNTP_bootsOutTimed_whenLoaded() {
        let recorder = Recorder()
        let manager = makeManager(recorder)

        XCTAssertNil(reply { manager.disableNTPSync(withReply: $0) })

        XCTAssertEqual(recorder.launchctlCalls, [["print", "system/com.apple.timed"], ["bootout", "system/com.apple.timed"]])
    }

    func test_disableNTP_isIdempotent_whenAlreadyOff() {
        let recorder = Recorder()
        recorder.timedLoaded = false
        let manager = makeManager(recorder)

        XCTAssertNil(reply { manager.disableNTPSync(withReply: $0) })

        XCTAssertEqual(recorder.launchctlCalls, [["print", "system/com.apple.timed"]])
    }

    func test_enableNTP_bootstrapsTimed_whenNotLoaded() {
        let recorder = Recorder()
        recorder.timedLoaded = false
        let manager = makeManager(recorder)

        XCTAssertNil(reply { manager.enableNTPSync(withReply: $0) })

        XCTAssertEqual(
            recorder.launchctlCalls.last, ["bootstrap", "system", "/System/Library/LaunchDaemons/com.apple.timed.plist"])
    }

    func test_enableNTP_isIdempotent_whenAlreadyOn() {
        let recorder = Recorder()
        let manager = makeManager(recorder)

        XCTAssertNil(reply { manager.enableNTPSync(withReply: $0) })

        XCTAssertEqual(recorder.launchctlCalls, [["print", "system/com.apple.timed"]])
    }

    func test_launchctlFailure_replies1002() {
        let recorder = Recorder()
        recorder.commandStatus = 5
        let manager = makeManager(recorder)

        XCTAssertEqual((reply { manager.disableNTPSync(withReply: $0) } as NSError?)?.code, 1002)
        recorder.timedLoaded = false
        XCTAssertEqual((reply { manager.enableNTPSync(withReply: $0) } as NSError?)?.code, 1002)
    }
}
