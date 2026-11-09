//
//  SettingsViewControllerTests.swift
//

import AppKit
import XCTest

@testable import time_scramble

final class SettingsViewControllerTests: XCTestCase {
    private func makeController(_ harness: Harness) -> (ScramblingService, SettingsViewController) {
        let service = harness.makeService()
        let controller = SettingsViewController(service: service)
        _ = controller.view
        return (service, controller)
    }

    func test_interval_isPrefilledWithSavedValue() throws {
        let harness = Harness(test: self)
        try harness.repository.save(AppState(intervalMinutes: 17, sessionState: .stopped, realTimeSnapshot: nil))

        let (_, controller) = makeController(harness)

        XCTAssertEqual(controller.intervalField.stringValue, "17")
        XCTAssertTrue(controller.errorLabel.isHidden)
        XCTAssertTrue(controller.startButton.isEnabled)
    }

    func test_invalidInput_showsMessage_andDoesNotStart() {
        let harness = Harness(test: self)
        let (service, controller) = makeController(harness)

        for text in ["0", "-5", "abc", "200"] {
            controller.intervalField.stringValue = text

            controller.startScrambling()

            XCTAssertFalse(controller.errorLabel.isHidden, text)
            XCTAssertTrue(controller.errorLabel.stringValue.contains("1 to 120"), text)
        }
        XCTAssertNil(controller.lastAction)
        XCTAssertTrue(harness.helper.calls.isEmpty)
        XCTAssertEqual(service.state, .initial)
    }

    func test_save_persistsValidInterval_andClearsMessage() {
        let harness = Harness(test: self)
        let (_, controller) = makeController(harness)
        controller.intervalField.stringValue = "abc"
        controller.save()

        controller.intervalField.stringValue = "45"
        controller.save()

        XCTAssertTrue(controller.errorLabel.isHidden)
        XCTAssertEqual(harness.savedState()?.intervalMinutes, 45)
    }

    func test_start_savesIntervalAndStartsScrambling() async {
        let harness = Harness(test: self)
        let (service, controller) = makeController(harness)
        controller.intervalField.stringValue = "2"

        controller.startScrambling()
        await controller.lastAction?.value

        XCTAssertEqual(service.state.sessionState, .active)
        XCTAssertEqual(harness.scheduler.intervals, [120])
        XCTAssertFalse(controller.startButton.isEnabled)
    }

    func test_start_whenHelperUnreachable_showsMessage() async {
        let harness = Harness(test: self)
        harness.helper.failures[.disable] = HelperError.connectionInterrupted
        let (service, controller) = makeController(harness)

        controller.startScrambling()
        await controller.lastAction?.value

        XCTAssertTrue(controller.errorLabel.stringValue.hasPrefix("Unable to contact system helper"))
        XCTAssertEqual(service.state.sessionState, .stopped)
    }
}
