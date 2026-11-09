//
//  AppDelegateTests.swift
//  Launch flow with stubbed alerts; a fresh AppDelegate, never the test host's own.
//

import AppKit
import XCTest

@testable import time_scramble

final class AppDelegateTests: XCTestCase {
    private final class Events {
        var questions: [String] = []
        var answer = true
        var presented: [Error] = []
        var terminated = 0
    }

    private func makeDelegate() -> (AppDelegate, Events) {
        let delegate = AppDelegate()
        let events = Events()
        delegate.ask = { message, _, _, _ in
            events.questions.append(message)
            return events.answer
        }
        delegate.present = { events.presented.append($0) }
        delegate.terminate = { events.terminated += 1 }
        addTeardownBlock {
            delegate.settingsWindow?.close()
            if let item = delegate.statusController?.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        return (delegate, events)
    }

    private func writeActiveSession(_ harness: Harness) async throws {
        _ = try await harness.makeService().start()
        harness.clock.elapse(120)
    }

    /// Guards the test host: no SMJobBless dialog, no XPC, no read of the real state.json.
    func test_hostedTests_skipHelperInstallAndBootstrap() throws {
        let hostDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)

        XCTAssertTrue(AppDelegate.isRunningTests)
        XCTAssertNil(hostDelegate.service)
    }

    func test_launch_whenStopped_showsMenuBarItemAndSettings() {
        let harness = Harness(test: self)
        let (delegate, events) = makeDelegate()

        let recovery = delegate.launch(with: harness.makeService())

        XCTAssertNil(recovery)
        XCTAssertNotNil(delegate.statusController)
        XCTAssertEqual(delegate.settingsWindow?.isVisible, true)
        XCTAssertTrue(events.questions.isEmpty)
    }

    func test_launch_whenPaused_staysInMenuBarOnly() throws {
        let harness = Harness(test: self)
        try harness.repository.save(
            AppState(
                intervalMinutes: 5, sessionState: .paused,
                realTimeSnapshot: RealTimeSnapshot(capturedAt: "x", unixTimestamp: 1_782_000_000)))
        let (delegate, _) = makeDelegate()

        delegate.launch(with: harness.makeService())

        XCTAssertNil(delegate.settingsWindow)
    }

    func test_launch_afterCrash_offersRestore_andRestoresWhenAccepted() async throws {
        let harness = Harness(test: self)
        try await writeActiveSession(harness)
        let (delegate, events) = makeDelegate()

        await delegate.launch(with: harness.makeService())?.value

        XCTAssertEqual(events.questions, ["A previous session was interrupted. Restore real time now?"])
        XCTAssertEqual(Array(harness.helper.calls.suffix(2)), [.restore(1_782_018_120), .enable])
        XCTAssertEqual(harness.savedState()?.sessionState, .stopped)
    }

    func test_launch_afterCrash_leavesSessionWhenDeclined() async throws {
        let harness = Harness(test: self)
        try await writeActiveSession(harness)
        let (delegate, events) = makeDelegate()
        events.answer = false
        let callsBefore = harness.helper.calls.count

        let recovery = delegate.launch(with: harness.makeService())

        XCTAssertNil(recovery)
        XCTAssertEqual(harness.helper.calls.count, callsBefore)
        XCTAssertEqual(harness.savedState()?.sessionState, .active)
    }

    func test_launch_afterCrash_reportsRestoreFailure() async throws {
        let harness = Harness(test: self)
        try await writeActiveSession(harness)
        harness.helper.failures[.restore] = HelperError.connectionInterrupted
        let (delegate, events) = makeDelegate()

        await delegate.launch(with: harness.makeService())?.value

        XCTAssertEqual(events.presented.first as? HelperError, .connectionInterrupted)
    }

    func test_launch_withCorruptState_startsFreshWhenAccepted() async throws {
        let harness = Harness(test: self)
        try harness.write("garbage")
        let (delegate, events) = makeDelegate()

        await delegate.launch(with: harness.makeService())?.value

        XCTAssertEqual(events.questions, ["Saved settings are unreadable."])
        XCTAssertEqual(harness.helper.calls, [.enable])
        XCTAssertEqual(harness.savedState(), .initial)
        XCTAssertEqual(delegate.settingsWindow?.isVisible, true)
    }

    func test_launch_withCorruptState_reportsHelperFailure_andStillOpensSettings() async throws {
        let harness = Harness(test: self)
        try harness.write("garbage")
        harness.helper.failures[.enable] = HelperError.connectionInterrupted
        let (delegate, events) = makeDelegate()

        await delegate.launch(with: harness.makeService())?.value

        XCTAssertEqual(events.presented.count, 1)
        XCTAssertEqual(delegate.settingsWindow?.isVisible, true)
    }

    func test_launch_withCorruptState_quitsWithoutTouchingTheFileWhenDeclined() throws {
        let harness = Harness(test: self)
        try harness.write("garbage")
        let (delegate, events) = makeDelegate()
        events.answer = false

        delegate.launch(with: harness.makeService())

        XCTAssertEqual(events.terminated, 1)
        XCTAssertTrue(harness.helper.calls.isEmpty)
        XCTAssertEqual(try String(contentsOf: harness.repository.fileURL, encoding: .utf8), "garbage")
    }

    func test_backgroundErrorsAndMenuActions_reachTheDelegate() async {
        let harness = Harness(test: self)
        let (delegate, events) = makeDelegate()
        let service = harness.makeService()
        delegate.launch(with: service)
        delegate.settingsWindow?.close()

        service.onError?(TestError.boom)
        delegate.statusController?.openSettings()
        XCTAssertEqual(delegate.settingsWindow?.isVisible, true)
        harness.helper.failures[.disable] = HelperError.launchctlFailed
        delegate.statusController?.start()
        await delegate.statusController?.lastAction?.value
        delegate.statusController?.quit()
        await delegate.statusController?.lastAction?.value

        XCTAssertEqual(events.presented.count, 2)
        XCTAssertEqual(events.terminated, 1)
    }

    func test_reopen_showsSettings() {
        let harness = Harness(test: self)
        let (delegate, _) = makeDelegate()
        delegate.launch(with: harness.makeService())
        delegate.settingsWindow?.close()

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))

        XCTAssertEqual(delegate.settingsWindow?.isVisible, true)
    }

    func test_openSettings_beforeLaunch_doesNothing() {
        let (delegate, _) = makeDelegate()

        delegate.openSettings()

        XCTAssertNil(delegate.settingsWindow)
    }
}
