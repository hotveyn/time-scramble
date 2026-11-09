//
//  SessionClock.swift
//

import Foundation

/// Wall-clock and monotonic time sources; tests replace them.
nonisolated struct SessionClock {
    var now: @Sendable () -> Double
    var monotonicNanos: @Sendable () -> UInt64
    var bootSessionID: @Sendable () -> String

    static let system = SessionClock(
        now: { Date().timeIntervalSince1970 },
        // CLOCK_MONOTONIC_RAW (mach_continuous_time) keeps counting in sleep and ignores settimeofday().
        monotonicNanos: { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) },
        bootSessionID: { readBootSessionUUID() }
    )

    /// Call only while the clock shows real time: before the first scramble of a start or resume.
    func snapshot() -> RealTimeSnapshot {
        let now = now()
        return RealTimeSnapshot(
            capturedAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: now)),
            unixTimestamp: now,
            monotonicNanos: monotonicNanos(),
            bootSessionID: bootSessionID()
        )
    }

    /// Real time now = snapshot + elapsed monotonic time. Nil when the snapshot has no anchor or comes from another boot.
    func realNow(since snapshot: RealTimeSnapshot) -> Double? {
        guard let anchor = snapshot.monotonicNanos, snapshot.bootSessionID == bootSessionID() else { return nil }
        let current = monotonicNanos()
        guard current >= anchor else { return nil }
        return snapshot.unixTimestamp + Double(current - anchor) / 1_000_000_000
    }

    private static func readBootSessionUUID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
