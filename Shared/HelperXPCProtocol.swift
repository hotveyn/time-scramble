//
//  HelperXPCProtocol.swift
//  Compiled into both the app and the privileged helper; keep it out of a framework.
//

import Foundation

nonisolated enum HelperService {
    /// launchd label, Mach service name and executable name of the privileged helper.
    static let label = "com.focustimescrambler.helper"
}

/// The whole privileged surface: four calls, each answered exactly once.
@objc(HelperXPCProtocol)
nonisolated protocol HelperXPCProtocol {
    func setSystemTime(to timestamp: Double, withReply reply: @escaping (Error?) -> Void)
    /// timestamp = snapshot + elapsed Δt, computed by the caller
    func restoreSystemTime(to timestamp: Double, withReply reply: @escaping (Error?) -> Void)
    func disableNTPSync(withReply reply: @escaping (Error?) -> Void)  // idempotent
    func enableNTPSync(withReply reply: @escaping (Error?) -> Void)  // idempotent
}

/// Error codes of the helper contract; the messages are the only text the user sees (T002).
nonisolated enum HelperError: Int, CustomNSError, LocalizedError {
    case syscallFailed = 1001
    case launchctlFailed = 1002
    case invalidTimestamp = 1003
    case connectionInterrupted = 1004

    static let errorDomain = "com.focustimescrambler.helper"

    var errorCode: Int { rawValue }

    var errorDescription: String? {
        switch self {
        case .syscallFailed:
            "macOS did not accept the clock change, so the clock was not changed. Try again; if it keeps failing, restart your Mac."
        case .launchctlFailed:
            "Could not switch automatic time on or off. Open System Settings › General › Date & Time and check “Set time automatically”."
        case .invalidTimestamp:
            "The saved real time is invalid, so the clock was not changed. Turn on “Set time automatically” in System Settings › General › Date & Time to correct the clock."
        case .connectionInterrupted:
            "Unable to contact system helper. Connection to system helper lost — please restart the app."
        }
    }
}
