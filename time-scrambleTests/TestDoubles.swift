//
//  TestDoubles.swift
//  Nothing here touches the real clock, launchd or ~/Library.
//

import Foundation
import XCTest

@testable import time_scramble

final class FakeHelper: HelperClient {
    enum Call: Equatable {
        case set(Double)
        case restore(Double)
        case disable
        case enable
    }

    enum Kind {
        case set, restore, disable, enable
    }

    private(set) var calls: [Call] = []
    var failures: [Kind: Error] = [:]
    var onCall: ((Call) -> Void)?
    /// When true, the next call suspends until `release()`.
    var suspendNext = false
    private(set) var suspended: CheckedContinuation<Void, Never>?

    func setSystemTime(to timestamp: Double) async throws { try await record(.set(timestamp), .set) }
    func restoreSystemTime(to timestamp: Double) async throws { try await record(.restore(timestamp), .restore) }
    func disableNTPSync() async throws { try await record(.disable, .disable) }
    func enableNTPSync() async throws { try await record(.enable, .enable) }

    func release() {
        suspended?.resume()
        suspended = nil
    }

    private func record(_ call: Call, _ kind: Kind) async throws {
        calls.append(call)
        onCall?(call)
        if suspendNext {
            suspendNext = false
            await withCheckedContinuation { suspended = $0 }
        }
        if let error = failures[kind] { throw error }
    }
}

final class FakeScheduler {
    private(set) var intervals: [TimeInterval] = []
    private(set) var tick: (() -> Void)?
    private(set) var cancelCount = 0

    func schedule(_ interval: TimeInterval, _ tick: @escaping () -> Void) -> () -> Void {
        intervals.append(interval)
        self.tick = tick
        return { [weak self] in
            self?.cancelCount += 1
            self?.tick = nil
        }
    }
}

nonisolated final class FakeClock: @unchecked Sendable {
    /// 2026-06-21T05:00:00Z, which is still 2026-06-20 in Los Angeles.
    var now: Double = 1_782_018_000
    var monotonic: UInt64 = 5_000_000_000
    var boot = "boot-A"

    var sessionClock: SessionClock {
        SessionClock(now: { self.now }, monotonicNanos: { self.monotonic }, bootSessionID: { self.boot })
    }

    /// Real time passes; the wall clock is left alone because a scrambled clock says nothing about it.
    func elapse(_ seconds: Double) {
        monotonic += UInt64(seconds * 1_000_000_000)
    }
}

/// Deterministic random: queued fractions of the range, else a new value per call.
final class FakeRandom {
    var fractions: [Double] = []
    private(set) var ranges: [ClosedRange<Double>] = []

    func next(_ range: ClosedRange<Double>) -> Double {
        ranges.append(range)
        guard !fractions.isEmpty else { return range.lowerBound + Double(ranges.count) }
        let fraction = fractions.removeFirst()
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }
}

enum TestError: Error {
    case boom
}

final class Harness {
    let helper = FakeHelper()
    let scheduler = FakeScheduler()
    let clock = FakeClock()
    let random = FakeRandom()
    let notifications = NotificationCenter()
    let directory: URL
    let repository: StateRepository
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    init(test: XCTestCase) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TimeScrambleTests-\(UUID().uuidString)")
        repository = StateRepository(fileURL: directory.appendingPathComponent("state.json"))
        let directory = directory
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    func makeService() -> ScramblingService {
        ScramblingService(
            helper: helper, repository: repository, clock: clock.sessionClock, calendar: calendar,
            schedule: scheduler.schedule, random: random.next, sleepNotifications: notifications)
    }

    func write(_ json: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: repository.fileURL)
    }

    func savedState() -> AppState? {
        if case .loaded(let state) = repository.load() { return state }
        return nil
    }
}
