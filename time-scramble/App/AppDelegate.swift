//
//  AppDelegate.swift
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var service: ScramblingService?
    private(set) var statusController: StatusItemController?
    private(set) var settingsWindow: NSWindow?
    /// Seams for tests; the defaults show modal alerts and quit the app.
    var ask: (_ message: String, _ detail: String, _ confirm: String, _ cancel: String) -> Bool = AppDelegate.runAlert
    var present: (Error) -> Void = AppDelegate.presentAlert
    var terminate: () -> Void = { NSApp.terminate(nil) }

    /// Unit tests are hosted in this app; they must never install the helper or touch the real state.json.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        do {
            try HelperInstaller.installIfNeeded()
        } catch {
            present(error)
        }
        launch(with: ScramblingService(helper: HelperProxy(), repository: StateRepository()))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// Puts the menu-bar item up, then handles a crashed or corrupt previous session.
    /// Returns the recovery work, if any, so tests can await it.
    @discardableResult
    func launch(with service: ScramblingService, statusBar: NSStatusBar = .system) -> Task<Void, Never>? {
        service.onError = { [weak self] in self?.present($0) }
        self.service = service
        statusController = StatusItemController(
            service: service,
            statusBar: statusBar,
            openSettings: { [weak self] in self?.openSettings() },
            report: { [weak self] in self?.present($0) },
            terminate: { [weak self] in self?.terminate() }
        )
        switch service.launchCheck {
        case .ready:
            if service.state.sessionState == .stopped { openSettings() }
            return nil
        case .interruptedSession:
            guard
                ask(
                    "A previous session was interrupted. Restore real time now?",
                    "The clock may still show a scrambled time.", "Restore Real Time", "Not Now")
            else { return nil }
            return Task {
                do {
                    try await service.stop()
                } catch {
                    present(error)
                }
            }
        case .corruptState:
            guard
                ask(
                    "Saved settings are unreadable.",
                    "Start fresh with default settings? Time Scramble will turn automatic time back on so macOS corrects the clock. Quit to inspect ~/Library/Application Support/FocusTimeScrambler/state.json first.",
                    "Start Fresh", "Quit")
            else {
                terminate()
                return nil
            }
            return Task {
                do {
                    try await service.freshStart()
                } catch {
                    present(error)
                }
                openSettings()
            }
        }
    }

    func openSettings() {
        guard let service else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: SettingsViewController(service: service))
            window.title = "Time Scramble"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // nonisolated so they can be stored-property defaults; only ever called on the main thread.
    private nonisolated static func runAlert(message: String, detail: String, confirm: String, cancel: String) -> Bool {
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.addButton(withTitle: confirm)
            alert.addButton(withTitle: cancel)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private nonisolated static func presentAlert(_ error: Error) {
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Time Scramble"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
