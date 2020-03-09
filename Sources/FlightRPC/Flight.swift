//
//  Flight.swift
//
//
//  Created by Simon Free on 2020-03-05.
//

import Combine
import Foundation
import Network
import os

// MARK: FlightProtocol

/// Inherit this protocol on your RPC protocols.
public protocol FlightProtocol {  }


// MARK: - FlightRPC

/// A namespace for `FlightRPC` types and APIs.
public enum Flight {
    
    public enum FlightError: Error, LocalizedError {
        
    }
}
