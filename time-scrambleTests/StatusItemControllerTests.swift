//
//  StatusItemControllerTests.swift
//

import AppKit
import XCTest

@testable import time_scramble

final class StatusItemControllerTests: XCTestCase {
    private struct Fixture {
        let harness: Harness
        let service: ScramblingService
        let controller: StatusItemController
        let events: Events
    }

    private final class Events {
        var reported: [Error] = []
        var settingsOpened = 0
        var terminated = 0
    }

    private func makeFixture() -> Fixture {
        let harness = Harness(test: self)
        let service = harness.makeService()
        let events = Events()
        let statusBar = NSStatusBar.system
        let controller = StatusItemController(
            service: service, statusBar: statusBar,
            openSettings: { events.settingsOpened += 1 },
            report: { events.reported.append($0) },
            terminate: { events.terminated += 1 })
        addTeardownBlock { statusBar.removeStatusItem(controller.statusItem) }
        return Fixture(harness: harness, service: service, controller: controller, events: events)
    }

    private func icon(_ controller: StatusItemController) -> String? {
        controller.statusItem.button?.image?.accessibilityDescription
    }

    func test_stopped_offersStartOnly() {
        let fixture = makeFixture()
        let controller = fixture.controller

        XCTAssertEqual(icon(controller), "Time Scramble: Stopped")
        XCTAssertTrue(controller.startItem.isEnabled)
        XCTAssertFalse(controller.pauseItem.isEnabled)
        XCTAssertFalse(controller.stopItem.isEnabled)
        XCTAssertEqual(
            controller.statusItem.menu?.items.map(\.title),
            ["Start", "Pause", "Stop", "", "Open Settings…", "", "Quit Time Scramble"])
    }

    func test_start_showsActiveIconAndOffersPauseAndStop() async {
        let fixture = makeFixture()

        fixture.controller.start()
        await fixture.controller.lastAction?.value

        XCTAssertEqual(fixture.service.state.sessionState, .active)
        XCTAssertEqual(icon(fixture.controller), "Time Scramble: Active")
        XCTAssertFalse(fixture.controller.startItem.isEnabled)
        XCTAssertEqual(fixture.controller.pauseItem.title, "Pause")
        XCTAssertTrue(fixture.controller.pauseItem.isEnabled)
        XCTAssertTrue(fixture.controller.stopItem.isEnabled)
    }

    func test_pauseItem_togglesBetweenPausedAndActive() async {
        let fixture = makeFixture()
        fixture.controller.start()
        await fixture.controller.lastAction?.value

        fixture.controller.togglePause()
        await fixture.controller.lastAction?.value
        XCTAssertEqual(icon(fixture.controller), "Time Scramble: Paused")
        XCTAssertEqual(fixture.controller.pauseItem.title, "Resume")

        fixture.controller.togglePause()
        await fixture.controller.lastAction?.value
        XCTAssertEqual(fixture.service.state.sessionState, .active)
        XCTAssertEqual(fixture.controller.pauseItem.title, "Pause")
    }

    func test_stop_returnsToStopped() async {
        let fixture = makeFixture()
        fixture.controller.start()
        await fixture.controller.lastAction?.value

        fixture.controller.stop()
        await fixture.controller.lastAction?.value

        XCTAssertEqual(fixture.service.state.sessionState, .stopped)
        XCTAssertEqual(icon(fixture.controller), "Time Scramble: Stopped")
    }

    func test_failedAction_isReported() async {
        let fixture = makeFixture()
        fixture.harness.helper.failures[.disable] = HelperError.connectionInterrupted

        fixture.controller.start()
        await fixture.controller.lastAction?.value

        XCTAssertEqual(fixture.events.reported.first as? HelperError, .connectionInterrupted)
        XCTAssertEqual(icon(fixture.controller), "Time Scramble: Stopped")
    }

    func test_openSettings_callsThrough() {
        let fixture = makeFixture()

        fixture.controller.openSettings()

        XCTAssertEqual(fixture.events.settingsOpened, 1)
    }

    func test_quit_whileActive_restoresRealTimeBeforeTerminating() async {
        let fixture = makeFixture()
        fixture.controller.start()
        await fixture.controller.lastAction?.value

        fixture.controller.quit()
        await fixture.controller.lastAction?.value

        XCTAssertEqual(fixture.service.state.sessionState, .stopped)
        XCTAssertEqual(fixture.harness.helper.calls.last, .enable)
        XCTAssertEqual(fixture.events.terminated, 1)
    }

    func test_menuNeedsUpdate_reflectsCurrentState() throws {
        let fixture = makeFixture()
        let menu = try XCTUnwrap(fixture.controller.statusItem.menu)
        fixture.controller.startItem.isEnabled = false

        fixture.controller.menuNeedsUpdate(menu)

        XCTAssertTrue(fixture.controller.startItem.isEnabled)
    }
}
