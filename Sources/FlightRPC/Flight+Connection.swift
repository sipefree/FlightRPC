//
//  File.swift
//  
//
//  Created by Simon Free on 2020-03-08.
//

import Combine
import Foundation
import Network
import os

extension Flight {
    
    // MARK: - Connection Publisher/Subscriber
    
    /// A connctable publisher and subscriber wrapping a network connection.
    public class Connection:
        ConnectablePublisher,
        Subscriber
    {
        
        // MARK: - Typealiases
        
        /// The connection accepts raw data as input.
        public typealias Input = Data
        
        /// The connection publishes raw data as output.
        public typealias Output = Data
        
        /// The connection never completes with errors.
        public typealias Failure = Never
        
        
        // MARK: - Initialization
        
        /// Initializes the connection for a unix file socket.
        public convenience init(
            unixSocketPath: String,
            name: String
        ) {
            self.init(to: .unix(path: unixSocketPath), using: .init(), name: name)
        }
        
        /// Initializes the connection for a given network endpoint.
        public convenience init(
            to endpoint: NWEndpoint,
            using params: NWParameters,
            name: String
        ) {
            self.init(connection: NWConnection(to: endpoint, using: params), name: name)
        }
        
        /// Initializes the connection with its network connection.
        public init(connection: NWConnection, name: String) {
            self.connection = connection
            self.name = name
            self.log = OSLog(subsystem: "Flight", category: name)
            
            self.queue = DispatchQueue(
                label: "FlightRPC-Transport-\(name)",
                qos: .userInitiated,
                attributes: [],
                autoreleaseFrequency: .workItem,
                target: nil
            )
            
            self._state = State(
                enabled: false,
                connectionReady: false,
                sending: false,
                receiving: false,
                hasIncoming: false,
                hasOutgoing: false,
                incomingDemand: false,
                outgoingDemand: false
            )
            
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                self.connectionStateChanged(to: state)
            }
            
            queue.setSpecific(key: Self.queueKey, value: queueContext)
        }
        
        
        // MARK: - Private API
        
        /// The underlying network connection.
        private let connection: NWConnection
        
        /// The identifying name of the connection.
        private let name: String
        
        /// The log for this connection.
        private let log: OSLog
        
        /// The queue that processes network events.
        private let queue: DispatchQueue
        
        private static let queueKey = DispatchSpecificKey<Int>()
        
        private lazy var queueContext: Int = unsafeBitCast(self, to: Int.self)
        
        private func sync(_ block: () -> Void) {
            if DispatchQueue.getSpecific(key: Self.queueKey) == queueContext {
                block()
            } else {
                queue.sync(execute: block)
            }
        }
        
        /// Handles state changes for the underlying connection.
        private func connectionStateChanged(to nwState: NWConnection.State) {
            state.connectionReady = nwState == .ready
        }
        
        /// Sends data on the network connection.
        private func sendData(_ data: Data) {
            guard state.sendAllowed else { return }
            
            state.sending = true
            
            connection.send(content: data, completion: .contentProcessed({ [weak self] (error) in
                guard let self = self else { return }
                
                if let error = error {
                    Swift.print("Error: \(error)")
                }
                
                self.state.sending = false
            }))
        }
        
        private func scheduleReceiveData() {
            state.receiving = true
            connection.receive(minimumIncompleteLength: 0, maximumLength: 1024) { [weak self] (data, context, finished, error) in
                guard let self = self else { return }
                
                defer { self.state.receiving = false }
                
                guard let data = data, error == nil else {
                    if let error = error {
                        Swift.print("Receive error: \(error)")
                    }
                    return
                }
                
                self.didReceiveData(data)
            }
        }
        
        private func didReceiveData(_ data: Data) {
            var demandChanged: Bool = false
            
            for sub in downstreamIncomingSubs where sub.pendingDemand > .max(0) {
                let demand = sub.downstream.receive(data)
                
                if sub.pendingDemand != .unlimited {
                    let oldDemand = sub.pendingDemand
                    if demand == .unlimited {
                        sub.pendingDemand = demand
                    } else {
                        let updatedDemand = sub.pendingDemand + (demand - 1)
                        sub.pendingDemand = updatedDemand
                    }
                    demandChanged = oldDemand != sub.pendingDemand
                }
            }
            
            if demandChanged {
                demandDidChange()
            }
        }
        
        /// Called when downstream demand changes.
        fileprivate func demandDidChange() {
            state.setIncomingDemand(with: downstreamIncomingSubs.map { $0.pendingDemand })
        }
        
        /// Upstream outgoing data publisher.
        private var upstreamOutgoing: UpstreamSubscription? {
            didSet {
                state.hasOutgoing = upstreamOutgoing != nil
            }
        }
        
        /// Downstream incoming data subscribers.
        private var downstreamIncomingSubs = Set<DownstreamSubcription>() {
            didSet {
                state.hasIncoming = downstreamIncomingSubs.count > 0
            }
        }
        
        private struct State: Equatable {
            var enabled: Bool
            var connectionReady: Bool
            
            var sending: Bool
            var receiving: Bool
            
            var hasIncoming: Bool
            var hasOutgoing: Bool
            
            var incomingDemand: Bool
            var outgoingDemand: Bool
            
            var connectionAllowed: Bool {
                enabled && hasIncoming && hasOutgoing
            }
            
            var shouldStartConnection: Bool {
                !connectionReady && connectionAllowed
            }
            
            var shouldCancelConnection: Bool {
                connectionReady && !connectionAllowed
            }
            
            var outgoingDemandAllowed: Bool {
                enabled && connectionReady && !sending
            }
            
            var shouldStartOutgoingDemand: Bool {
                !outgoingDemand && outgoingDemandAllowed
            }
            
            var shouldStopOutgoingDemand: Bool {
                outgoingDemand && !outgoingDemandAllowed
            }
            
            var receiveAllowed: Bool {
                enabled && connectionReady && incomingDemand
            }
            
            var shouldReceive: Bool {
                !receiving && receiveAllowed
            }
            
            var sendAllowed: Bool {
                enabled && connectionReady && !sending
            }
            
            mutating func setIncomingDemand(with demands: [Subscribers.Demand]) {
                incomingDemand = (demands.max() ?? .max(0)) > .max(0)
            }
        }
        
        /// Private storage for state.
        private var _state: State
        
        /// The state of the connection.
        /// - note: Changes in state cause network connection
        ///         changes and backpressure updates.
        private var state: State {
            get { _state }
            set(newState) {
                guard newState != _state else { return }
                
                _state = newState
                
                if _state.shouldStartConnection {
                    connection.start(queue: queue)
                } else if _state.shouldCancelConnection {
                    connection.cancel()
                }
                
                if _state.shouldStartOutgoingDemand {
                    upstreamOutgoing?.request(.max(1))
                    _state.outgoingDemand = true
                } else if _state.shouldStopOutgoingDemand {
                    _state.outgoingDemand = false
                }
                
                if _state.shouldReceive {
                    scheduleReceiveData()
                }
            }
        }
        
        
        // MARK: - <ConnectablePublisher>
        
        /// Connects the underlying network connection if there are
        /// upstream or downstream publishers or subscribers.
        public func connect() -> Cancellable {
            state.enabled = true
            return AnyCancellable { [weak self] in
                self?.state.enabled = false
            }
        }
        
        // MARK: - <Subscriber>
        
        public func receive(_ input: Data) -> Subscribers.Demand {
            sync {
                guard state.outgoingDemand else { return }
                self.sendData(input)
            }
            
            return .max(0)
        }
        
        public func receive(completion: Subscribers.Completion<Never>) {
            sync {
                state.enabled = false
                
                for sub in downstreamIncomingSubs {
                    sub.downstream.receive(completion: completion)
                }
            }
        }
        
        public func receive(subscription: Subscription) {
            let upstream = UpstreamSubscription(subscription: subscription)
            sync {
                if let existing = upstreamOutgoing {
                    existing.cancel()
                }
                
                upstreamOutgoing = upstream
            }
            
            if state.outgoingDemandAllowed {
                upstream.request(.max(1))
            }
        }
        
        
        // MARK: - <Publisher>
        
        public func receive<S>(subscriber: S)
        where
            S : Subscriber,
            Failure == S.Failure,
            Output == S.Input
        {
            let downstream = DownstreamSubcription(downstream: subscriber, parent: self)
            sync {
                let _ = downstreamIncomingSubs.insert(downstream)
            }
            subscriber.receive(subscription: downstream)
        }
        
        private final class UpstreamSubscription: Subscription, Cancellable, Hashable {
            
            init(subscription: Subscription) {
                self.subscription = subscription
            }
            
            private let subscription: Subscription
            
            func request(_ demand: Subscribers.Demand) {
                subscription.request(demand)
            }
            
            func cancel() {
                subscription.cancel()
            }
            
            static func == (lhs: UpstreamSubscription, rhs: UpstreamSubscription) -> Bool {
                lhs === rhs
            }
            
            func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
        }
        
        private final class DownstreamSubcription: Subscription, Cancellable, Hashable {
            
            init<S>(downstream: S, parent: Connection)
            where
                S : Subscriber,
                Failure == S.Failure,
                Output == S.Input
            {
                self.downstream = AnySubscriber(downstream)
                self.parent = parent
            }
            
            let downstream: AnySubscriber<Data,Never>
            
            weak var parent: Connection?
            
            var pendingDemand: Subscribers.Demand = .max(0)
            
            func request(_ demand: Subscribers.Demand) {
                guard let parent = parent else { return }
                parent.sync {
                    pendingDemand = demand
                    parent.demandDidChange()
                }
            }
            
            func cancel() {
                guard let parent = parent else { return }
                parent.sync {
                    parent.downstreamIncomingSubs.remove(self)
                    parent.demandDidChange()
                }
            }
            
            static func == (lhs: DownstreamSubcription, rhs: DownstreamSubcription) -> Bool {
                lhs === rhs
            }
            
            func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
            
        }
        
        
    }
    
}
