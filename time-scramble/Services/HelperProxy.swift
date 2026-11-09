//
//  HelperProxy.swift
//

import Foundation

/// The helper's four operations as async calls. `HelperProxy` implements it over XPC; tests use a fake.
protocol HelperClient: AnyObject {
    func setSystemTime(to timestamp: Double) async throws
    func restoreSystemTime(to timestamp: Double) async throws
    func disableNTPSync() async throws
    func enableNTPSync() async throws
}

final class HelperProxy: HelperClient {
    private let makeConnection: () -> NSXPCConnection
    private var connection: NSXPCConnection?

    init(
        makeConnection: @escaping () -> NSXPCConnection = {
            NSXPCConnection(machServiceName: HelperService.label, options: .privileged)
        }
    ) {
        self.makeConnection = makeConnection
    }

    func setSystemTime(to timestamp: Double) async throws {
        try await call { $0.setSystemTime(to: timestamp, withReply: $1) }
    }

    func restoreSystemTime(to timestamp: Double) async throws {
        try await call { $0.restoreSystemTime(to: timestamp, withReply: $1) }
    }

    func disableNTPSync() async throws {
        try await call { $0.disableNTPSync(withReply: $1) }
    }

    func enableNTPSync() async throws {
        try await call { $0.enableNTPSync(withReply: $1) }
    }

    /// Sends one message synchronously on the caller's actor, so messages leave in call order.
    private func call(_ send: (HelperXPCProtocol, @escaping @Sendable (Error?) -> Void) -> Void) async throws {
        let connection = currentConnection()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
                    once.resume(throwing: HelperError.connectionInterrupted)
                }
                guard let helper = proxy as? HelperXPCProtocol else {
                    return once.resume(throwing: HelperError.connectionInterrupted)
                }
                send(helper) { @Sendable error in once.resume(throwing: error.map(Self.map)) }
            }
        } catch HelperError.connectionInterrupted {
            // Reconnect on the next call; an invalidated connection never recovers.
            if self.connection === connection {
                self.connection = nil
                connection.invalidate()
            }
            throw HelperError.connectionInterrupted
        }
    }

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.resume()
        self.connection = connection
        return connection
    }

    /// NSError from the helper process → `HelperError`; anything else passes through.
    nonisolated static func map(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == HelperError.errorDomain, let known = HelperError(rawValue: nsError.code) else {
            return error
        }
        return known
    }
}

/// XPC may call both the reply and the error handler; the continuation must resume once.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(throwing error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume()
        }
    }
}
