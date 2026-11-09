//
//  SettingsView.swift
//  Interval panel: pre-filled with the saved interval, rejects input outside 1–120.
//

import AppKit

final class SettingsViewController: NSViewController {
    let intervalField = NSTextField()
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let startButton = NSButton(title: "Start", target: nil, action: nil)
    /// The last Start's work; tests await it.
    private(set) var lastAction: Task<Void, Never>?

    private let service: ScramblingService

    init(service: ScramblingService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        intervalField.stringValue = String(service.state.intervalMinutes)
        intervalField.placeholderString = "1–120"
        intervalField.setAccessibilityLabel("Interval in minutes")
        intervalField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        startButton.target = self
        startButton.action = #selector(startScrambling)
        startButton.keyEquivalent = "\r"
        let row = NSStackView(views: [
            NSTextField(labelWithString: "Change the clock every"), intervalField,
            NSTextField(labelWithString: "minutes"),
        ])
        let stack = NSStackView(views: [row, errorLabel, NSStackView(views: [saveButton, startButton])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view = stack
        service.observe { [weak self] _ in self?.refresh() }
        refresh()
    }

    @objc func save() {
        _ = applyInterval()
    }

    /// Saves the interval, then starts and closes the panel so no window stays on screen.
    @objc func startScrambling() {
        guard applyInterval() else { return }
        lastAction = Task {
            do {
                try await service.start()
                view.window?.close()
            } catch {
                show(error)
            }
        }
    }

    private func applyInterval() -> Bool {
        do {
            try service.updateInterval(AppState.parseInterval(intervalField.stringValue))
            show(nil)
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func refresh() {
        startButton.isEnabled = service.state.sessionState == .stopped
    }

    private func show(_ error: Error?) {
        errorLabel.stringValue = error?.localizedDescription ?? ""
        errorLabel.isHidden = error == nil
        guard let message = error?.localizedDescription else { return }
        NSAccessibility.post(
            element: errorLabel, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
