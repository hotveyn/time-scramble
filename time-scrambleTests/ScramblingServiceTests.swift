//
//  ScramblingServiceTests.swift
//

import AppKit
import XCTest

@testable import time_scramble

final class ScramblingServiceTests: XCTestCase {
    /// Local day of FakeClock's start (2026-06-20, Los Angeles) in UTC seconds.
    private let localDayStart: Double = 1_781_938_800
    private let localDayLastSecond: Double = 1_782_025_199

    private func startedService(_ harness: Harness) async throws -> ScramblingService {
        let service = harness.makeService()
        try await service.start()
        return service
    }

    // MARK: Launch

    func test_launch_withoutStateFile_savesDefaultsAndIsReady() {
        let harness = Harness(test: self)

        let service = harness.makeService()

        XCTAssertEqual(service.launchCheck, .ready)
        XCTAssertEqual(service.state, .initial)
        XCTAssertEqual(harness.savedState(), .initial)
    }

    func test_launch_withPausedFile_isReadyAndKeepsPaused() throws {
        let harness = Harness(test: self)
        let paused = AppState(
            intervalMinutes: 5, sessionState: .paused,
            realTimeSnapshot: RealTimeSnapshot(capturedAt: "x", unixTimestamp: 1_782_000_000))
        try harness.repository.save(paused)

        let service = harness.makeService()

        XCTAssertEqual(service.launchCheck, .ready)
        XCTAssertEqual(service.state, paused)
    }

    func test_launch_withCorruptFile_promptsFreshStart_whichResetsAndReenablesNTP() async throws {
        let harness = Harness(test: self)
        try harness.write("{ broken")
        let service = harness.makeService()
        XCTAssertEqual(service.launchCheck, .corruptState)

        try await service.freshStart()

        XCTAssertEqual(service.launchCheck, .ready)
        XCTAssertEqual(harness.savedState(), .initial)
        XCTAssertEqual(harness.helper.calls, [.enable])
    }

    func test_freshStart_whenHelperUnreachable_stillResetsStateAndThrows() async throws {
        let harness = Harness(test: self)
        try harness.write("{ broken")
        harness.helper.failures[.enable] = HelperError.connectionInterrupted
        let service = harness.makeService()

        await XCTAssertThrowsErrorAsync(try await service.freshStart())

        XCTAssertEqual(harness.savedState(), .initial)
    }

    func test_launch_afterCrashWhileActive_offersRestore_andStopRestoresSnapshotPlusElapsed() async throws {
        let harness = Harness(test: self)
        let crashed = try await startedService(harness)
        let snapshot = try XCTUnwrap(crashed.state.realTimeSnapshot)
        harness.clock.now = 42  // scrambled wall clock must not matter
        harness.clock.elapse(900)
        let relaunched = harness.makeService()
        XCTAssertEqual(relaunched.launchCheck, .interruptedSession)
        XCTAssertFalse(relaunched.isScrambling)

        try await relaunched.stop()

        XCTAssertEqual(Array(harness.helper.calls.suffix(2)), [.restore(snapshot.unixTimestamp + 900), .enable])
        XCTAssertEqual(harness.savedState()?.sessionState, .stopped)
        XCTAssertNil(harness.savedState()?.realTimeSnapshot)
    }

    func test_restore_withSnapshotFromAnotherBoot_leavesCorrectionToNTP() async throws {
        let harness = Harness(test: self)
        _ = try await startedService(harness)
        harness.clock.boot = "boot-B"
        let relaunched = harness.makeService()

        try await relaunched.stop()

        XCTAssertEqual(harness.helper.calls.last, .enable)
        XCTAssertFalse(harness.helper.calls.contains { if case .restore = $0 { true } else { false } })
        XCTAssertEqual(relaunched.state.sessionState, .stopped)
    }

    func test_restore_withHandWrittenSnapshotWithoutAnchor_leavesCorrectionToNTP() async throws {
        let harness = Harness(test: self)
        try harness.write(
            #"{ "intervalMinutes": 30, "sessionState": "active", "realTimeSnapshot": { "capturedAt": "x", "unixTimestamp": 1750500000.0 } }"#
        )
        let service = harness.makeService()

        try await service.stop()

        XCTAssertEqual(harness.helper.calls, [.enable])
    }

    func test_restore_whenMonotonicClockWentBackwards_leavesCorrectionToNTP() async throws {
        let harness = Harness(test: self)
        _ = try await startedService(harness)
        harness.clock.monotonic = 1
        let relaunched = harness.makeService()

        try await relaunched.stop()

        XCTAssertEqual(harness.helper.calls.last, .enable)
        XCTAssertEqual(harness.helper.calls.count, 3)  // disable, set, enable
    }

    // MARK: Start

    func test_start_disablesNTP_thenSnapshots_thenWritesActive_beforeFirstScramble() async throws {
        let harness = Harness(test: self)
        let service = harness.makeService()
        var stateOnDiskAtSet: AppState?
        harness.helper.onCall = { if case .set = $0 { stateOnDiskAtSet = harness.savedState() } }

        try await service.start()

        XCTAssertEqual(harness.helper.calls.count, 2)
        XCTAssertEqual(harness.helper.calls.first, .disable)
        let snapshot = try XCTUnwrap(service.state.realTimeSnapshot)
        XCTAssertEqual(snapshot.unixTimestamp, 1_782_018_000)
        XCTAssertEqual(snapshot.capturedAt, "2026-06-21T05:00:00Z")
        XCTAssertEqual(snapshot.monotonicNanos, 5_000_000_000)
        XCTAssertEqual(snapshot.bootSessionID, "boot-A")
        XCTAssertEqual(stateOnDiskAtSet?.sessionState, .active)
        XCTAssertEqual(stateOnDiskAtSet?.realTimeSnapshot, snapshot)
        XCTAssertEqual(service.state.sessionState, .active)
        XCTAssertEqual(harness.scheduler.intervals, [30 * 60])
        XCTAssertTrue(service.isScrambling)
    }

    func test_start_whenAlreadyActive_doesNothing() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)

        try await service.start()

        XCTAssertEqual(harness.helper.calls.count, 2)
    }

    func test_start_whenNTPCannotBeDisabled_staysStoppedAndChangesNothing() async throws {
        let harness = Harness(test: self)
        harness.helper.failures[.disable] = HelperError.launchctlFailed
        let service = harness.makeService()

        await XCTAssertThrowsErrorAsync(try await service.start()) {
            XCTAssertEqual($0 as? HelperError, .launchctlFailed)
        }

        XCTAssertEqual(harness.helper.calls, [.disable])
        XCTAssertEqual(harness.savedState(), .initial)
        XCTAssertFalse(service.isScrambling)
    }

    func test_start_whenFirstScrambleFails_rollsBackToStopped() async throws {
        let harness = Harness(test: self)
        harness.helper.failures[.set] = HelperError.syscallFailed
        let service = harness.makeService()

        await XCTAssertThrowsErrorAsync(try await service.start())

        XCTAssertEqual(harness.helper.calls.count, 4)
        XCTAssertEqual(Array(harness.helper.calls.suffix(2)), [.restore(1_782_018_000), .enable])
        XCTAssertEqual(service.state, .initial)
        XCTAssertEqual(harness.savedState(), .initial)
        XCTAssertFalse(service.isScrambling)
    }

    func test_start_whenScrambleAndRollbackFail_staysActiveSoStopCanRetry() async throws {
        let harness = Harness(test: self)
        harness.helper.failures[.set] = HelperError.connectionInterrupted
        harness.helper.failures[.restore] = HelperError.connectionInterrupted
        let service = harness.makeService()

        await XCTAssertThrowsErrorAsync(try await service.start())

        XCTAssertEqual(service.state.sessionState, .active)
        XCTAssertEqual(harness.savedState()?.sessionState, .active)
        XCTAssertFalse(service.isScrambling)
    }

    func test_start_whenStateCannotBeSaved_reenablesNTPAndStaysStopped() async throws {
        let harness = Harness(test: self)
        try FileManager.default.createDirectory(at: harness.directory, withIntermediateDirectories: true)
        try Data().write(to: harness.directory.appendingPathComponent("file"))
        let service = ScramblingService(
            helper: harness.helper,
            repository: StateRepository(fileURL: harness.directory.appendingPathComponent("file/state.json")),
            clock: harness.clock.sessionClock, schedule: harness.scheduler.schedule,
            sleepNotifications: harness.notifications)

        await XCTAssertThrowsErrorAsync(try await service.start())

        XCTAssertEqual(harness.helper.calls, [.disable, .restore(1_782_018_000), .enable])
        XCTAssertEqual(service.state.sessionState, .stopped)
    }

    func test_transitionInFlight_ignoresOtherRequestsAndTicks() async throws {
        let harness = Harness(test: self)
        let service = harness.makeService()
        harness.helper.suspendNext = true
        let start = Task { try await service.start() }
        while harness.helper.suspended == nil { await Task.yield() }

        try await service.start()
        try await service.stop()
        try await service.pause()
        XCTAssertTrue(service.isTransitioning)
        harness.helper.release()
        try await start.value

        XCTAssertEqual(harness.helper.calls.count, 2)
        XCTAssertFalse(service.isTransitioning)
    }

    // MARK: Random time

    func test_randomTime_staysWithinLocalCalendarDay() async throws {
        let harness = Harness(test: self)
        harness.random.fractions = [0, 1]
        let service = try await startedService(harness)

        harness.scheduler.tick?()
        await service.tickTask?.value

        XCTAssertEqual(harness.random.ranges.first, localDayStart...localDayLastSecond)
        XCTAssertEqual(
            harness.helper.calls.filter { if case .set = $0 { true } else { false } },
            [.set(localDayStart), .set(localDayLastSecond)])
    }

    func test_randomTime_followsRealTimeAcrossMidnight() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        harness.clock.elapse(3 * 3600)  // 01:00 next local day

        harness.scheduler.tick?()
        await service.tickTask?.value

        XCTAssertEqual(harness.random.ranges.last?.lowerBound, localDayStart + 86_400)
    }

    func test_randomTime_onDaylightSavingDay_spansTwentyThreeHours() {
        let harness = Harness(test: self)
        harness.random.fractions = [1]
        let service = harness.makeService()

        // 2026-03-08 12:00 in Los Angeles, the day clocks spring forward.
        let timestamp = service.randomTime(onDayOf: 1_773_000_000)

        XCTAssertEqual(harness.random.ranges.first, 1_772_956_800...1_773_039_599)
        XCTAssertEqual(timestamp, 1_773_039_599)
    }

    func test_randomTime_isWholeSecondAndNeverRepeatsPreviousValue() async throws {
        let harness = Harness(test: self)
        harness.random.fractions = [0.5, 0.5, 0.25]
        let service = try await startedService(harness)

        harness.scheduler.tick?()
        await service.tickTask?.value

        let sets = harness.helper.calls.compactMap { if case .set(let t) = $0 { t } else { nil } }
        XCTAssertEqual(sets.count, 2)
        XCTAssertNotEqual(sets[0], sets[1])
        XCTAssertEqual(sets[0], sets[0].rounded(.down))
        XCTAssertEqual(harness.random.ranges.count, 3)
    }

    // MARK: Ticks

    func test_tick_setsNewRandomTimeWithoutWritingState() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        let modified = try FileManager.default.attributesOfItem(atPath: harness.repository.fileURL.path)[.modificationDate]
        var notified = false
        service.observe { _ in notified = true }

        harness.scheduler.tick?()
        await service.tickTask?.value

        XCTAssertEqual(harness.helper.calls.count, 3)
        XCTAssertFalse(notified)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: harness.repository.fileURL.path)[.modificationDate]
                as? Date, modified as? Date)
    }

    func test_tickError_isReportedAndSessionStaysActive() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        var reported: Error?
        service.onError = { reported = $0 }
        harness.helper.failures[.set] = HelperError.connectionInterrupted

        harness.scheduler.tick?()
        await service.tickTask?.value

        XCTAssertEqual(reported as? HelperError, .connectionInterrupted)
        XCTAssertEqual(service.state.sessionState, .active)
    }

    func test_tick_firingAfterServiceWentAway_doesNothing() async throws {
        let harness = Harness(test: self)
        var service: ScramblingService? = try await startedService(harness)
        let tick = harness.scheduler.tick
        weak let weakService = service
        service = nil

        tick?()

        XCTAssertNil(weakService)
        XCTAssertEqual(harness.helper.calls.count, 2)
    }

    // MARK: Stop

    func test_stop_restoresRealTime_thenReenablesNTP_beforeWritingStopped() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        harness.clock.elapse(600.5)
        var stateOnDiskAtRestore: SessionState?
        harness.helper.onCall = { if case .restore = $0 { stateOnDiskAtRestore = harness.savedState()?.sessionState } }

        try await service.stop()

        XCTAssertEqual(Array(harness.helper.calls.suffix(2)), [.restore(1_782_018_600.5), .enable])
        XCTAssertEqual(stateOnDiskAtRestore, .active)
        XCTAssertEqual(service.state.sessionState, .stopped)
        XCTAssertNil(service.state.realTimeSnapshot)
        XCTAssertEqual(harness.savedState()?.realTimeSnapshot, nil)
        XCTAssertEqual(harness.scheduler.cancelCount, 1)
        XCTAssertFalse(service.isScrambling)
    }

    func test_stop_whenRestoreFails_staysActiveAndKeepsScrambling() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        harness.helper.failures[.restore] = HelperError.syscallFailed

        await XCTAssertThrowsErrorAsync(try await service.stop()) {
            XCTAssertEqual($0 as? HelperError, .syscallFailed)
        }

        XCTAssertEqual(service.state.sessionState, .active)
        XCTAssertEqual(harness.savedState()?.sessionState, .active)
        XCTAssertTrue(service.isScrambling)
        XCTAssertEqual(harness.scheduler.intervals.count, 2)
    }

    func test_stop_whenStopped_doesNothing() async throws {
        let harness = Harness(test: self)
        let service = harness.makeService()

        try await service.stop()

        XCTAssertTrue(harness.helper.calls.isEmpty)
    }

    // MARK: Pause and resume

    func test_pause_restoresRealTime_reenablesNTP_andWritesPausedWithSnapshot() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        let snapshot = service.state.realTimeSnapshot
        harness.clock.elapse(60)

        try await service.pause()

        XCTAssertEqual(Array(harness.helper.calls.suffix(2)), [.restore(1_782_018_060), .enable])
        XCTAssertEqual(harness.savedState()?.sessionState, .paused)
        XCTAssertEqual(harness.savedState()?.realTimeSnapshot, snapshot)
        XCTAssertFalse(service.isScrambling)
    }

    func test_pause_whenStopped_doesNothing() async throws {
        let harness = Harness(test: self)
        let service = harness.makeService()

        try await service.pause()

        XCTAssertTrue(harness.helper.calls.isEmpty)
    }

    func test_resume_disablesNTP_takesFreshSnapshot_andScramblesAgain() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        try await service.pause()
        harness.clock.now = 1_782_020_000
        harness.clock.elapse(300)
        let callsBefore = harness.helper.calls.count

        try await service.resume()

        XCTAssertEqual(harness.helper.calls[callsBefore], .disable)
        XCTAssertEqual(harness.helper.calls.count, callsBefore + 2)
        XCTAssertEqual(service.state.sessionState, .active)
        XCTAssertEqual(harness.savedState()?.realTimeSnapshot?.unixTimestamp, 1_782_020_000)
        XCTAssertTrue(service.isScrambling)
        XCTAssertEqual(harness.scheduler.intervals.count, 2)
    }

    func test_resume_whenScrambleFails_rollsBackToPaused() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        try await service.pause()
        harness.helper.failures[.set] = HelperError.syscallFailed

        await XCTAssertThrowsErrorAsync(try await service.resume())

        XCTAssertEqual(service.state.sessionState, .paused)
        XCTAssertNotNil(harness.savedState()?.realTimeSnapshot)
        XCTAssertFalse(service.isScrambling)
    }

    func test_stop_whilePaused_writesStoppedWithoutHelperCalls() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        try await service.pause()
        let callsBefore = harness.helper.calls.count

        try await service.stop()

        XCTAssertEqual(harness.helper.calls.count, callsBefore)
        XCTAssertEqual(harness.savedState(), AppState(intervalMinutes: 30, sessionState: .stopped, realTimeSnapshot: nil))
    }

    // MARK: Sleep

    func test_systemSleep_whileActive_pauses() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        let paused = expectation(description: "paused")
        service.observe { if $0.sessionState == .paused { paused.fulfill() } }

        harness.notifications.post(name: NSWorkspace.willSleepNotification, object: nil)

        await fulfillment(of: [paused], timeout: 2)
        XCTAssertEqual(Array(harness.helper.calls.suffix(2)), [.restore(1_782_018_000), .enable])
        XCTAssertFalse(service.isScrambling)
    }

    func test_systemSleep_whenPauseFails_reportsError() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)
        harness.helper.failures[.restore] = HelperError.connectionInterrupted
        let reported = expectation(description: "reported")
        service.onError = { _ in reported.fulfill() }

        harness.notifications.post(name: NSWorkspace.willSleepNotification, object: nil)

        await fulfillment(of: [reported], timeout: 2)
        XCTAssertEqual(service.state.sessionState, .active)
    }

    func test_systemSleep_whileStopped_doesNothing() async {
        let harness = Harness(test: self)
        let service = harness.makeService()

        harness.notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()

        XCTAssertTrue(harness.helper.calls.isEmpty)
        XCTAssertEqual(service.state.sessionState, .stopped)
    }

    // MARK: Interval

    func test_updateInterval_whileActive_persistsAndReschedules() async throws {
        let harness = Harness(test: self)
        let service = try await startedService(harness)

        try service.updateInterval(2)

        XCTAssertEqual(harness.savedState()?.intervalMinutes, 2)
        XCTAssertEqual(harness.savedState()?.sessionState, .active)
        XCTAssertEqual(harness.scheduler.intervals, [30 * 60, 2 * 60])
    }

    func test_updateInterval_whileStopped_persistsWithoutScheduling() throws {
        let harness = Harness(test: self)
        let service = harness.makeService()

        try service.updateInterval(120)

        XCTAssertEqual(harness.savedState()?.intervalMinutes, 120)
        XCTAssertTrue(harness.scheduler.intervals.isEmpty)
    }

    func test_updateInterval_outOfRange_throwsAndKeepsSavedValue() {
        let harness = Harness(test: self)
        let service = harness.makeService()

        XCTAssertThrowsError(try service.updateInterval(0))
        XCTAssertThrowsError(try service.updateInterval(121))

        XCTAssertEqual(harness.savedState()?.intervalMinutes, 30)
    }

    // MARK: System sources

    func test_repeatingTimer_firesOnMainRunLoopUntilCancelled() async {
        let fired = expectation(description: "fired")
        fired.assertForOverFulfill = false

        let cancel = ScramblingService.repeatingTimer(interval: 0.05) { fired.fulfill() }

        await fulfillment(of: [fired], timeout: 2)
        cancel()
    }

    func test_systemClock_isMonotonicAndIdentifiesTheBoot() {
        let clock = SessionClock.system
        let snapshot = clock.snapshot()

        XCTAssertFalse(clock.bootSessionID().isEmpty)
        XCTAssertEqual(snapshot.bootSessionID, clock.bootSessionID())
        XCTAssertGreaterThanOrEqual(clock.monotonicNanos(), snapshot.monotonicNanos ?? .max)
        XCTAssertGreaterThanOrEqual(clock.realNow(since: snapshot) ?? 0, snapshot.unixTimestamp)
        XCTAssertTrue(snapshot.isValid)
    }
}

func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
