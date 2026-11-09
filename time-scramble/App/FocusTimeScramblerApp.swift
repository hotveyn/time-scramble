//
//  FocusTimeScramblerApp.swift
//

import AppKit

@main
enum FocusTimeScramblerApp {
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
}
