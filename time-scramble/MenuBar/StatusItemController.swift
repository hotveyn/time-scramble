//
//  StatusItemController.swift
//

import AppKit

final class StatusItemController: NSObject, NSMenuDelegate {
    let statusItem: NSStatusItem
    let startItem = NSMenuItem(title: "Start", action: #selector(start), keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    let stopItem = NSMenuItem(title: "Stop", action: #selector(stop), keyEquivalent: "")
    /// The last menu action's work; tests await it.
    private(set) var lastAction: Task<Void, Never>?

    private let service: ScramblingService
    private let report: (Error) -> Void
    private let openSettingsAction: () -> Void
    private let terminate: () -> Void

    init(
        service: ScramblingService,
        statusBar: NSStatusBar = .system,
        openSettings: @escaping () -> Void,
        report: @escaping (Error) -> Void,
        terminate: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.service = service
        self.report = report
        self.openSettingsAction = openSettings
        self.terminate = terminate
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let settingsItem = NSMenuItem(title: "Open Settings…", action: #selector(StatusItemController.openSettings), keyEquivalent: ",")
        let quitItem = NSMenuItem(title: "Quit Time Scramble", action: #selector(quit), keyEquivalent: "q")
        for item in [startItem, pauseItem, stopItem, .separator(), settingsItem, .separator(), quitItem] {
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        service.observe { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        let session = service.state.sessionState
        let (symbol, label) =
            switch session {
            case .stopped: ("clock", "Stopped")
            case .active: ("shuffle", "Active")
            case .paused: ("pause.circle", "Paused")
            }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Time Scramble: \(label)")
        statusItem.button?.toolTip = "Time Scramble: \(label)"
        let idle = !service.isTransitioning
        startItem.isEnabled = idle && session == .stopped
        pauseItem.title = session == .paused ? "Resume" : "Pause"
        pauseItem.isEnabled = idle && session != .stopped
        stopItem.isEnabled = idle && session != .stopped
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    @objc func start() {
        run { try await $0.start() }
    }

    @objc func togglePause() {
        run { service in
            if service.state.sessionState == .paused {
                try await service.resume()
            } else {
                try await service.pause()
            }
        }
    }

    @objc func stop() {
        run { try await $0.stop() }
    }

    @objc func openSettings() {
        openSettingsAction()
    }

    /// Stops first so quitting never leaves the clock scrambled; a failed stop is recovered on next launch.
    @objc func quit() {
        lastAction = Task { [service, terminate] in
            try? await service.stop()
            terminate()
        }
    }

    private func run(_ action: @escaping (ScramblingService) async throws -> Void) {
        lastAction = Task { [weak self, service, report] in
            do {
                try await action(service)
            } catch {
                report(error)
            }
            self?.refresh()  // items were disabled while the transition ran
        }
    }
}
