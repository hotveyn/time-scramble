//
//  AppState.swift
//  The one document in state.json; written on start, pause, resume, stop and interval changes only.
//

import Foundation

nonisolated enum SessionState: String, Codable {
    case stopped
    case active
    case paused
}

nonisolated struct RealTimeSnapshot: Codable, Equatable {
    /// ISO 8601, for manual inspection after a crash.
    var capturedAt: String
    var unixTimestamp: Double
    /// Monotonic clock (counts sleep, ignores settimeofday) and boot session at capture,
    /// so a relaunch after a crash can still compute the elapsed time. Absent in hand-written files.
    var monotonicNanos: UInt64?
    var bootSessionID: String?

    var isValid: Bool { unixTimestamp.isFinite && unixTimestamp > 0 }
}

nonisolated struct AppState: Codable, Equatable {
    static let intervalRange = 1...120
    static let initial = AppState(intervalMinutes: 30, sessionState: .stopped, realTimeSnapshot: nil)

    var intervalMinutes: Int
    var sessionState: SessionState
    /// Non-null in `active` and `paused`; null after `stopped`.
    var realTimeSnapshot: RealTimeSnapshot?

    /// Data-model rules; a decoded file that breaks them is treated as corrupt.
    var isValid: Bool {
        Self.intervalRange.contains(intervalMinutes)
            && (realTimeSnapshot?.isValid ?? (sessionState == .stopped))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intervalMinutes, forKey: .intervalMinutes)
        try container.encode(sessionState, forKey: .sessionState)
        // Explicit null when stopped, as in the documented file format.
        try container.encode(realTimeSnapshot, forKey: .realTimeSnapshot)
    }

    nonisolated enum IntervalError: LocalizedError {
        case notAWholeNumber
        case outOfRange

        var errorDescription: String? {
            switch self {
            case .notAWholeNumber: "Enter the interval as a whole number of minutes, from 1 to 120."
            case .outOfRange: "The interval must be from 1 to 120 minutes."
            }
        }
    }

    static func parseInterval(_ text: String) throws -> Int {
        guard let minutes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw IntervalError.notAWholeNumber
        }
        try validateInterval(minutes)
        return minutes
    }

    static func validateInterval(_ minutes: Int) throws {
        guard intervalRange.contains(minutes) else { throw IntervalError.outOfRange }
    }
}
