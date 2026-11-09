//
//  SMJobBlessHelperInstaller.swift
//  SMJobBless is deprecated since the macOS 13 SDK; kept on purpose (research R-001).
//

import Foundation
import Security
import ServiceManagement
import os

enum HelperInstaller {
    enum InstallError: LocalizedError {
        case failed

        var errorDescription: String? {
            "Could not install the system helper. Time Scramble needs an administrator password once to change the clock; restart the app to try again."
        }
    }

    static let installedURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(HelperService.label)")
    private static let log = Logger(subsystem: "scramble.time-scramble", category: "HelperInstaller")

    /// Shows the macOS authorization dialog when the helper is missing or differs from the bundled one.
    static func installIfNeeded(bundle: Bundle = .main) throws {
        guard needsInstall(installed: installedURL, bundled: bundledHelperURL(in: bundle)) else { return }
        try install()
    }

    static func bundledHelperURL(in bundle: Bundle) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(HelperService.label)")
    }

    /// Compares CFBundleVersion embedded in both executables; bump it whenever the helper changes.
    static func needsInstall(installed: URL, bundled: URL) -> Bool {
        guard let installedVersion = version(at: installed) else { return true }
        return installedVersion != version(at: bundled)
    }

    private static func version(at url: URL) -> String? {
        (CFBundleCopyInfoDictionaryForURL(url as CFURL) as? [String: Any])?["CFBundleVersion"] as? String
    }

    private static func install() throws {
        var authorization: AuthorizationRef?
        let status = kSMRightBlessPrivilegedHelper.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items in
                var rights = AuthorizationRights(count: 1, items: items)
                return AuthorizationCreate(
                    &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], &authorization)
            }
        }
        guard status == errAuthorizationSuccess, let authorization else {
            log.error("authorization failed: \(status, privacy: .public)")
            throw InstallError.failed
        }
        defer { AuthorizationFree(authorization, []) }
        var error: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, HelperService.label as CFString, authorization, &error) else {
            log.error("SMJobBless failed: \(String(describing: error?.takeRetainedValue()), privacy: .public)")
            throw InstallError.failed
        }
    }
}
