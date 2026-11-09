//
//  HelperProxyTests.swift
//  Contract tests (T018): a real in-process XPC round trip to a helper double over an anonymous listener.
//  No root, no launchd, no clock changes.
//

import Foundation
import XCTest

@testable import time_scramble

nonisolated final class XPCHelperDouble: NSObject, HelperXPCProtocol, @unchecked Sendable {
    enum Behavior {
        case succeed
        case fail(Error)
        /// Invalidate the connection instead of replying, like a helper that dies mid-call.
        case dropConnection
    }

    private let lock = NSLock()
    private var _behavior = Behavior.succeed
    private var _received: [String] = []

    var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }

    var received: [String] { lock.withLock { _received } }

    func setSystemTime(to timestamp: Double, withReply reply: @escaping (Error?) -> Void) {
        handle("set \(timestamp)", reply)
    }

    func restoreSystemTime(to timestamp: Double, withReply reply: @escaping (Error?) -> Void) {
        handle("restore \(timestamp)", reply)
    }

    func disableNTPSync(withReply reply: @escaping (Error?) -> Void) {
        handle("disable", reply)
    }

    func enableNTPSync(withReply reply: @escaping (Error?) -> Void) {
        handle("enable", reply)
    }

    private func handle(_ call: String, _ reply: (Error?) -> Void) {
        lock.withLock { _received.append(call) }
        switch behavior {
        case .succeed: reply(nil)
        case .fail(let error): reply(error)
        case .dropConnection: NSXPCConnection.current()?.invalidate()
        }
    }
}

nonisolated final class XPCListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let exported: XPCHelperDouble

    init(exported: XPCHelperDouble) {
        self.exported = exported
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = exported
        connection.resume()
        return true
    }
}

final class HelperProxyTests: XCTestCase {
    private struct Fixture {
        let double: XPCHelperDouble
        let proxy: HelperProxy
        let connections: () -> Int
    }

    private func makeFixture() -> Fixture {
        let double = XPCHelperDouble()
        let delegate = XPCListenerDelegate(exported: double)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        var made = 0
        let proxy = HelperProxy {
            made += 1
            return NSXPCConnection(listenerEndpoint: listener.endpoint)
        }
        addTeardownBlock {
            withExtendedLifetime(delegate) { listener.invalidate() }
        }
        return Fixture(double: double, proxy: proxy, connections: { made })
    }

    func test_allFourOperations_reachTheHelperInCallOrder() async throws {
        let fixture = makeFixture()

        try await fixture.proxy.disableNTPSync()
        try await fixture.proxy.setSystemTime(to: 1_782_000_000.5)
        try await fixture.proxy.restoreSystemTime(to: 1_782_018_600)
        try await fixture.proxy.enableNTPSync()

        XCTAssertEqual(
            fixture.double.received, ["disable", "set 1782000000.5", "restore 1782018600.0", "enable"])
        XCTAssertEqual(fixture.connections(), 1)
    }

    func test_helperErrorCodes_arriveAsHelperErrors() async {
        let fixture = makeFixture()

        for expected in [HelperError.syscallFailed, .launchctlFailed, .invalidTimestamp, .connectionInterrupted] {
            fixture.double.behavior = .fail(expected)

            await XCTAssertThrowsErrorAsync(try await fixture.proxy.setSystemTime(to: 1)) {
                XCTAssertEqual($0 as? HelperError, expected)
                XCTAssertEqual(($0 as NSError).domain, "com.focustimescrambler.helper")
                XCTAssertEqual(($0 as NSError).code, expected.rawValue)
            }
        }
    }

    func test_eachOperation_mapsHelperErrors() async {
        let fixture = makeFixture()
        fixture.double.behavior = .fail(HelperError.launchctlFailed)

        await XCTAssertThrowsErrorAsync(try await fixture.proxy.disableNTPSync()) {
            XCTAssertEqual($0 as? HelperError, .launchctlFailed)
        }
        await XCTAssertThrowsErrorAsync(try await fixture.proxy.enableNTPSync()) {
            XCTAssertEqual($0 as? HelperError, .launchctlFailed)
        }
        fixture.double.behavior = .fail(HelperError.invalidTimestamp)
        await XCTAssertThrowsErrorAsync(try await fixture.proxy.restoreSystemTime(to: -1)) {
            XCTAssertEqual($0 as? HelperError, .invalidTimestamp)
        }
    }

    func test_connectionLostBeforeReply_throws1004_andNextCallReconnects() async throws {
        let fixture = makeFixture()
        fixture.double.behavior = .dropConnection

        await XCTAssertThrowsErrorAsync(try await fixture.proxy.restoreSystemTime(to: 1)) {
            XCTAssertEqual($0 as? HelperError, .connectionInterrupted)
            XCTAssertEqual(($0 as NSError).code, 1004)
        }
        fixture.double.behavior = .succeed
        try await fixture.proxy.enableNTPSync()

        XCTAssertEqual(fixture.connections(), 2)
        XCTAssertEqual(fixture.double.received.last, "enable")
    }

    func test_unknownErrors_passThroughUnchanged() async {
        let fixture = makeFixture()
        fixture.double.behavior = .fail(NSError(domain: "other", code: 7))

        await XCTAssertThrowsErrorAsync(try await fixture.proxy.disableNTPSync()) {
            XCTAssertEqual(($0 as NSError).domain, "other")
            XCTAssertEqual(($0 as NSError).code, 7)
        }
        XCTAssertEqual(fixture.connections(), 1)
    }

    func test_errorMessages_areHumanReadableWithoutCodes() {
        for error in [HelperError.syscallFailed, .launchctlFailed, .invalidTimestamp, .connectionInterrupted] {
            let message = error.localizedDescription

            XCTAssertFalse(message.contains(String(error.rawValue)), message)
            XCTAssertFalse(message.contains("com.focustimescrambler"), message)
        }
        XCTAssertTrue(HelperError.connectionInterrupted.localizedDescription.hasPrefix("Unable to contact system helper"))
        XCTAssertTrue(
            HelperError.connectionInterrupted.localizedDescription.contains(
                "Connection to system helper lost — please restart the app"))
    }
}
