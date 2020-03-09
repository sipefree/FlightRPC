//
//  File.swift
//  
//
//  Created by Simon Free on 2020-03-08.
//

import Network
import Combine
import Foundation
import os

public protocol FlightListener: Flight.RemoteProxy {
    
    associatedtype ExportedObject: AnyObject
    
    init(connection: NWConnection?, exporting local: ExportedObject)
    
    static func listen(
        exporting local: ExportedObject,
        atUnixSocketPath path: String,
        newConnection: @escaping (Self) -> Void
    ) throws -> AnyCancellable
    
    static func listen(
        exporting local: ExportedObject,
        using parameters: NWParameters,
        on port: NWEndpoint.Port,
        newConnection: @escaping (Self) -> Void
    ) throws -> AnyCancellable
    
}

extension FlightListener {
    
    public init(atUnixSocketPath path: String, exporting local: ExportedObject) {
        let (endpoint, params) = Flight.parametersForUnixSocket(at: path)
        self.init(endpoint: endpoint, parameters: params, exporting: local)
    }
    
    public init(endpoint: NWEndpoint, parameters: NWParameters, exporting local: ExportedObject) {
        let connection = NWConnection(to: endpoint, using: parameters)
        self.init(connection: connection, exporting: local)
    }
    
    public static func listen(
        exporting local: ExportedObject,
        atUnixSocketPath path: String,
        newConnection: @escaping (Self) -> Void
    ) throws -> AnyCancellable {
        let (_, parameters) = Flight.parametersForUnixSocket(at: path)
        return try Self.listen(exporting: local, using: parameters, newConnection: newConnection)
    }
    
    public static func listen(
        exporting local: ExportedObject,
        using parameters: NWParameters,
        on port: NWEndpoint.Port = .any,
        newConnection: @escaping (Self) -> Void
    ) throws -> AnyCancellable {
        let name = String(describing: type(of: local))
        
        return try Flight.listen(
            using: parameters,
            on: port,
            name: name
        ) { (connection) in
            //os_log(.debug, log: Flight.listenerLog, "(%@) New Connection: 0x%x", name, Flight.logDesc(connection))
            
            let proxy = Self.init(connection: connection, exporting: local)
            newConnection(proxy)
        }
    }
}

extension Flight {
    
    fileprivate static func parametersForUnixSocket(at path: String) -> (NWEndpoint, NWParameters) {
        let endpoint = NWEndpoint.unix(path: path)
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        parameters.requiredLocalEndpoint = endpoint
        return (endpoint, parameters)
    }
    
    public static func listen(
        using parameters: NWParameters,
        on port: NWEndpoint.Port = .any,
        name: String,
        newConnection: @escaping (NWConnection) -> Void
    ) throws -> AnyCancellable {
        let listener = try Flight.Listener(
            using: parameters,
            on: port,
            name: name,
            newConnection: newConnection
        )
        
        return AnyCancellable { listener.cancel() }
    }
    
    internal class Listener: Cancellable {
        
        init(
            using parameters: NWParameters,
            on port: NWEndpoint.Port = .any,
            name: String,
            newConnection: @escaping (NWConnection) -> Void
        ) throws {
            listener = try NWListener(using: parameters, on: port)
            queue = DispatchQueue(label: "FlightRPC-Listener-\(name)")
            
            listener.stateUpdateHandler = { newState in
                //os_log(.debug, log: Flight.listenerLog, "%@ (%@) State: %@", Flight.logDesc(self), name, String(describing: newState))
            }
            listener.newConnectionHandler = newConnection
            listener.start(queue: queue)
        }
        
        let listener: NWListener
        
        let queue: DispatchQueue
        
        func cancel() {
            listener.cancel()
        }
        
    }
    
}

private var log: OSLog { Flight.listenerLog }
