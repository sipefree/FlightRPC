//
//  File.swift
//  
//
//  Created by Simon Free on 2020-03-08.
//

import Network
import Combine
import Foundation

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
        return try Flight.listen(
            atUnixSocketPath: path,
            name: String(describing: type(of: local))
        ) { (connection) in
            let proxy = Self.init(connection: connection, exporting: local)
            newConnection(proxy)
        }
    }
    
    public static func listen(
        exporting local: ExportedObject,
        using parameters: NWParameters,
        on port: NWEndpoint.Port = .any,
        newConnection: @escaping (Self) -> Void
    ) throws -> AnyCancellable {
        return try Flight.listen(
            using: parameters,
            on: port,
            name: String(describing: type(of: local))
        ) { (connection) in
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
        atUnixSocketPath path: String,
        name: String,
        newConnection: @escaping (NWConnection) -> Void
    ) throws -> AnyCancellable {
        let (_, parameters) = parametersForUnixSocket(at: path)
        
        return try listen(using: parameters, name: name, newConnection: newConnection)
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
            
            listener.stateUpdateHandler = { newState in }
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
