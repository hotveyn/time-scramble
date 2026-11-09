//
//  main.swift
//  Privileged helper entry: launchd starts it on demand for the Mach service.
//

import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Same requirement SMJobBless checked at install; no requirement means no client is trusted.
        guard let clients = Bundle.main.object(forInfoDictionaryKey: "SMAuthorizedClients") as? [String],
            !clients.isEmpty
        else { return false }
        connection.setCodeSigningRequirement(clients.map { "(\($0))" }.joined(separator: " or "))
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = TimeManager(
            setClock: TimeManager.systemSetClock, launchctl: TimeManager.runLaunchctl)
        connection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperService.label)
listener.delegate = delegate
listener.resume()
dispatchMain()
