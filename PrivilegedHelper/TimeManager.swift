//
//  TimeManager.swift
//  Runs as root. No file I/O, no network; the only processes it starts are launchctl.
//

import Foundation
import os

final class TimeManager: NSObject, HelperXPCProtocol {
    static let timedService = "system/com.apple.timed"
    static let timedPlist = "/System/Library/LaunchDaemons/com.apple.timed.plist"

    /// Sets the system clock; returns false when the kernel refuses.
    private let setClock: (Double) -> Bool
    /// Runs launchctl with the arguments; returns its exit status.
    private let launchctl: ([String]) -> Int32
    private let log = Logger(subsystem: HelperService.label, category: "TimeManager")

    init(setClock: @escaping (Double) -> Bool, launchctl: @escaping ([String]) -> Int32) {
        self.setClock = setClock
        self.launchctl = launchctl
    }

    func setSystemTime(to timestamp: Double, withReply reply: @escaping (Error?) -> Void) {
        reply(apply(timestamp))
    }

    func restoreSystemTime(to timestamp: Double, withReply reply: @escaping (Error?) -> Void) {
        reply(apply(timestamp))
    }

    func disableNTPSync(withReply reply: @escaping (Error?) -> Void) {
        guard isTimedLoaded() else { return reply(nil) }
        reply(run(["bootout", Self.timedService]))
    }

    func enableNTPSync(withReply reply: @escaping (Error?) -> Void) {
        guard !isTimedLoaded() else { return reply(nil) }
        reply(run(["bootstrap", "system", Self.timedPlist]))
    }

    private func apply(_ timestamp: Double) -> HelperError? {
        // Int(exactly:) also rejects values too large for time_t, which would otherwise trap.
        guard timestamp.isFinite, timestamp > 0, Int(exactly: timestamp.rounded(.down)) != nil else {
            log.error("rejected timestamp \(timestamp, privacy: .public)")
            return .invalidTimestamp
        }
        guard setClock(timestamp) else {
            log.error("settimeofday failed, errno \(errno, privacy: .public)")
            return .syscallFailed
        }
        return nil
    }

    // `print` makes enable/disable idempotent: bootout and bootstrap fail when already in the target state.
    private func isTimedLoaded() -> Bool {
        launchctl(["print", Self.timedService]) == 0
    }

    private func run(_ arguments: [String]) -> HelperError? {
        let status = launchctl(arguments)
        guard status == 0 else {
            log.error("launchctl \(arguments, privacy: .public) exited \(status, privacy: .public)")
            return .launchctlFailed
        }
        return nil
    }

    static func systemSetClock(_ timestamp: Double) -> Bool {
        let seconds = timestamp.rounded(.down)
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((timestamp - seconds) * 1_000_000))
        return settimeofday(&value, nil) == 0
    }

    static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
