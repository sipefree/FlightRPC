//
//  Flight+RemoteProxy.swift
//  
//
//  Created by Simon Free on 2020-03-08.
//

import Combine
import Foundation
import Network
import os

extension Flight {
    
    open class RemoteProxy {
        
        public convenience init(
            at endpoint: NWEndpoint,
            using parameters: NWParameters
        ) {
            self.init(connection: NWConnection(to: endpoint, using: parameters))
        }
        
        public init(connection: NWConnection?) {
            let name = String(String(describing: type(of: self)).split(separator: "<")[0])
            
            
            let flightConnection = connection.map { Flight.Connection(connection: $0, name: name) }
            
            channel = Channel(connection: flightConnection, name: name)
            registerIncomingMethods(cancellables: &cancellables)
            channel.connect()
        }
        
        public let channel: Channel
        
        private var cancellables = Set<AnyCancellable>()
        
        open func registerIncomingMethods(cancellables: inout Set<AnyCancellable>) {
            fatalError("Subclasses must override this method.")
        }
        
    }
    
}
