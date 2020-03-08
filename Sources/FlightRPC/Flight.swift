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

// MARK: FlightRPC

/// A namespace for `FlightRPC` types and APIs.
public enum Flight {
    
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
        private init(connection: NWConnection, name: String) {
            self.connection = connection
            self.name = name
            
            self.queue = DispatchQueue(
                label: "FlightRPC-Transport-\(name)",
                qos: .userInitiated,
                attributes: [],
                autoreleaseFrequency: .workItem,
                target: nil
            )
            
            connection.stateUpdateHandler = { [weak self] state in
                self?.connectionStateChanged(to: state)
            }
        }
        
        
        // MARK: - Private API
        
        /// The underlying network connection.
        private let connection: NWConnection
        
        /// The identifying name of the connection.
        private let name: String
        
        /// The queue that processes network events.
        private let queue: DispatchQueue
        
        /// Handles state changes for the underlying connection.
        private func connectionStateChanged(to nwState: NWConnection.State) {
            state.ready = nwState == .ready
        }
        
        fileprivate func demandDidChange() {
            var cumulativeDemand = Subscribers.Demand.max(0)
            
            for downstream in down {
                let demand = downstream.pendingDemand
                
                guard demand != .unlimited else {
                    cumulativeDemand = .unlimited
                    break
                }
                
                cumulativeDemand += demand
            }
            
            guard cumulativeDemand != state.demand else { }
            
            state.demand = cumulativeDemand
        }
        
        private func stopReceiving() {
            up.forEach { $0.request(.none) }
            state.receiving = false
        }
        
        private func startReceiving() {
            up.forEach { $0.request(.unlimited) }
            state.receiving = true
        }
        
        private var up = Set<UpstreamSubscription>()
        private var down = Set<DownstreamSubcription>()
        
        private typealias State = (
            enabled: Bool,
            ready: Bool,
            demand: Subscribers.Demand,
            receiving: Bool
        )
        
        private var state: State {
            didSet {
                
                switch state {
                    
                case (enabled: false, ready: true, demand: _,     receiving: _),
                     (enabled: true,  ready: true, demand: .none, receiving: _):
                    connection.cancel()
                    if state.receiving {
                        stopReceiving()
                    }
                    
                case (enabled: _, ready: false, demand: _, receiving: true):
                    stopReceiving()
                    
                case (enabled: true, ready: true, demand: _, receiving: false):
                    startReceiving()
                    connection.start(queue: queue)
                    
                    
                case (enabled: true, ready: true,  demand: _, receiving: true),
                     (enabled: _,    ready: false, demand: _, receiving: false):
                    break
                }
            }
        }
        
        
        // MARK: - <ConnectablePublisher>
        
        /// Connects the underlying network connection if there are
        /// upstream or downstream publishers or subscribers.
        public func connect() -> Cancellable {
            state.enabled = true
            return AnyCancellable { [weak self]
                self?.state.enabled = false
            }
        }
        
        // MARK: - <Subscriber>
        
        public func receive(_ input: Data) -> Subscribers.Demand {
            guard state.receiving else { return }
            
            var demandChanged: Bool = false
            
            for downstream in down where downstream.pendingDemand > .max(0) {
                let demand = downstream.downstream.receive(input)
                if demand != .unlimited {
                    let updatedDemand = downstream.pendingDemand + (demand - 1)
                    downstream.pendingDemand = updatedDemand
                    demandChanged = true
                }
            }
            
            if demandChanged {
                demandDidChange()
            }
            
            return .max(0)
        }
        
        public func receive(completion: Subscribers.Completion<Never>) {
            
        }
        
        
        // MARK: - <Publisher>
        
        public func receive(subscription: Subscription) {
            let upstream = UpstreamSubscription(subscription: subscription)
            up.insert(upstream)
            
            switch state {
            case (enabled: true, ready: true, demand: _, receiving: true):
                upstream.request(.unlimited)
                
            default:
                upstream.request(.none)
            }
        }
        
        public func receive<S>(subscriber: S)
        where
            S : Subscriber,
            Failure == S.Failure,
            Output == S.Input
        {
            let downstream = DownstreamSubcription(downstream: subscriber, parent: self)
            self.down.insert(downstream)
            subscriber.receive(subscription: downstream)
        }
        
        private class UpstreamSubscription: Subscription, Cancellable {
            
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
            
        }
        
        private class DownstreamSubcription: Subscription, AnyCancellable {
            
            init<S>(downstream: S, parent: Connection)
            where
                S : Subscriber,
                Self.Failure == S.Failure,
                Self.Output == S.Input
            {
                self.downstream = AnySubscriber(downstream)
                self.parent = parent
            }
            
            let downstream: AnySubscriber<Data,Never>
            
            weak var parent: Connection?
            
            var pendingDemand: Subscribers.Demand = .max(0)
            
            func request(_ demand: Subscribers.Demand) {
                pendingDemand = demand
                parent?.demandDidChange()
            }
            
        }
        
        
    }
    
    public class Channel {
        
        public convenience init(
            to endpoint: NWEndpoint,
            using parameters: NWParameters
        ) {
            self.init(connection: NWConnection(to: endpoint, using: parameters), name: "Default")
        }
        
        public init(connection: NWConnection?, name: String) {
            let log = OSLog(subsystem: "FlightRPC", category: name)
            self.log = log
            
            self.connection = connection
            self.name = name
            
            encodingQueue = DispatchQueue(
                label: "FlightRPC-Encoding-\(name)",
                qos: .userInitiated,
                attributes: [],
                autoreleaseFrequency: .workItem
            )
            
            decodingQueue = DispatchQueue(
                label: "FlightRPC-Decoding-\(name)",
                qos: .userInitiated,
                attributes: [],
                autoreleaseFrequency: .workItem
            )
            
            incomingMessagePublisher = incomingDataSubject
                .receive(on: decodingQueue)
                .flatMap { (data: Data) in data.publisher }
                .delimitedReduce(
                    into: Data(capacity: 1024),
                    isDelimiter: { $0 == UInt8(0) },
                    updateResult: { data, byte in data.append(byte) },
                    waitForFirstDelimiter: true
                )
                .decode(type: IncomingMessage.self, decoder: decoder)
                .handleEvents(receiveCompletion: { error in
                    os_log("Decoding error: %@", log: log, String(describing: error))
                })
                .retry(Int.max)
                .assertNoFailure()
                .share()
                .eraseToAnyPublisher()
                
            outgoingDataPublisher = outgoingMessageSubject
                .receive(on: encodingQueue)
                .encode(encoder: encoder)
                .handleEvents(receiveCompletion: { error in
                    os_log("Encoding error: %@", log: log, String(describing: error))
                })
                .retry(Int.max)
                .assertNoFailure()
                .map { (origData: JSONEncoder.Output) -> Data in
                    var data: Data = origData
                    data.append(UInt8(0))
                    return data
                }
                .share()
                .eraseToAnyPublisher()
            
        }
        
        private var name: String
        
        private var log: OSLog
        
        private var connection: NWConnection?
        
        private let encodingQueue: DispatchQueue
        private let decodingQueue: DispatchQueue
        
        private let outgoingMessageSubject = PassthroughSubject<OutgoingMessage, Never>()
        internal let outgoingDataPublisher: AnyPublisher<Data, Never>
        
        internal let incomingDataSubject = PassthroughSubject<Data, Never>()
        private let incomingMessagePublisher: AnyPublisher<IncomingMessage, Never>
        
        private let decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dataDecodingStrategy = .base64
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()
        
        private let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dataEncodingStrategy = .base64
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .withoutEscapingSlashes
            return encoder
        }()
        
        private var cancellables = Set<AnyCancellable>()
        
        private var singleCancellables = [UUID: AnyCancellable]()
        
        public typealias ResponseFulfiller = (@escaping OutgoingMessage.ArgumentEncodeBlock) -> Void
        public typealias IncomingHandler = (inout UnkeyedDecodingContainer, ResponseFulfiller?) throws -> Void
        
        private typealias IncomingMethodCall = (name: String, expectResp: Bool, msg: IncomingMessage)
        
        public func handleIncomingCalls(
            named name: String,
            with handler: @escaping IncomingHandler
        ) -> AnyCancellable {
            return incomingMessagePublisher
                .compactMap { (msg: IncomingMessage) -> IncomingMethodCall? in
                    guard
                        case .methodCall(let methodName, let expectResp) = msg.kind,
                        name == methodName
                    else { return nil }
                    
                    return (methodName, expectResp, msg)
                }
                .sink { [weak self] (call: IncomingMethodCall) in
                    guard let self = self else { return }
                    var responseFulfiller: ResponseFulfiller? = nil
                    
                    if call.expectResp {
                        
                        responseFulfiller = { [weak self] argEncodeBlock in
                            guard let self = self else { return }
                            
                            let responseMsg = OutgoingMessage(
                                kind: .response(call.msg.id),
                                encodeArguments: argEncodeBlock
                            )
                        
                            self.outgoingMessageSubject.send(responseMsg)
                        }
                    }
                    
                    do {
                        var container = call.msg.container
                        try handler(&container, responseFulfiller)
                    } catch {
                        // todo: error?
                    }
                }
        }
        
        public func sendOutgoingCall(
            named name: String,
            with encoder: @escaping OutgoingMessage.ArgumentEncodeBlock,
            response handler: IncomingMessage.ArgumentDecodeBlock? = nil
        ) {
            let outMsg = OutgoingMessage(
                kind: .methodCall(name, expectResponse: handler != nil),
                encodeArguments: encoder
            )
            
            let outMsgID = outMsg.id
            
            if let respHandler = handler {
                
                let cancellable = incomingMessagePublisher
                    .filter { (incMsg: IncomingMessage) -> Bool in
                        guard
                            case .response(let respID) = incMsg.kind,
                            respID == outMsgID
                        else { return false }
                        return true
                    }
                    .sink { [weak self] (incMsg: IncomingMessage) in
                        var container = incMsg.container
                        do {
                            try respHandler(&container)
                        } catch {
                            // todo: error?
                        }
                        
                        self?.singleCancellables[outMsgID] = nil
                    }
                
                singleCancellables[outMsgID] = cancellable
            }
            
            outgoingMessageSubject.send(outMsg)
        }

    }
    
    open class RemoteProxy {
        
        public convenience init(
            at endpoint: NWEndpoint,
            using parameters: NWParameters
        ) {
            self.init(connection: NWConnection(to: endpoint, using: parameters))
        }
        
        public init(connection: NWConnection?) {
            self.channel = Channel(connection: connection, name: String(describing: type(of: self)))
            registerIncomingMethods(cancellables: &cancellables)
            //connection.resume()
        }
        
        public let channel: Channel
        
        private var cancellables = Set<AnyCancellable>()
        
        open func registerIncomingMethods(cancellables: inout Set<AnyCancellable>) {
            fatalError("Subclasses must override this method.")
        }
        
    }
    
    public enum MessageKind: CustomStringConvertible {
        case methodCall(String, expectResponse: Bool)
        case response(UUID)
        
        public var description: String {
            switch self {
            case .methodCall(let method, let expectResponse):
                return "call: '\(method)' " + (expectResponse ? "(resp)" : "(no-resp)")
            case .response(let uuid):
                return "resp: \(uuid)"
            }
        }
        
        fileprivate static let kMethod = 0
        fileprivate static let kResponse = 1
        
        fileprivate var code: Int {
            switch self {
            case .methodCall: return Self.kMethod
            case .response: return Self.kResponse
            }
        }
        
        fileprivate init(from container: inout UnkeyedDecodingContainer) throws {
            let code = try container.decode(Int.self)
            switch code {
            case Self.kMethod:
                let method = try container.decode(String.self)
                let expectResponse = try container.decode(Bool.self)
                self = .methodCall(method, expectResponse: expectResponse)
                
            case Self.kResponse:
                let uuid = try container.decode(UUID.self)
                self = .response(uuid)
                
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown message kind: \(code)"
                )
            }
        }
        
        fileprivate func encode(to container: inout UnkeyedEncodingContainer) throws {
            try container.encode(self.code)
            
            switch self {
            case .methodCall(let method, expectResponse: let resp):
                try container.encode(method)
                try container.encode(resp)
                
            case .response(let uuid):
                try container.encode(uuid)
                
            }
        }
    }
    
    public struct OutgoingMessage: Encodable, CustomStringConvertible {
        
        public typealias ArgumentEncodeBlock = (inout UnkeyedEncodingContainer) throws -> Void
        
        public init(id: UUID = UUID(), kind: MessageKind, encodeArguments: @escaping ArgumentEncodeBlock) {
            self.id = id
            self.kind = kind
            self.encodeArguments = encodeArguments
        }
        
        public let id: UUID
        
        public let kind: MessageKind
        
        private let encodeArguments: ArgumentEncodeBlock
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(id)
            try kind.encode(to: &container)
            try encodeArguments(&container)
        }
        
        public var description: String {
            "OutgoingMessage(\(id), \(kind), args: \(argumentSummary(encodeArguments) ?? "<err>"))"
        }
        
    }
    
    public struct IncomingMessage: Decodable, CustomStringConvertible {
        
        public typealias ArgumentDecodeBlock = (inout UnkeyedDecodingContainer) throws -> Void
        
        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            self.id = try container.decode(UUID.self)
            self.kind = try MessageKind(from: &container)
            self.container = container
        }
        
        public let id: UUID
        
        public let kind: MessageKind
        
        public let container: UnkeyedDecodingContainer
        
        public var description: String {
            var args = 0
            if let count = container.count {
                args = count - container.currentIndex
            }
            return "IncomingMessage(\(id), \(kind), args: \(args))"
        }
        
    }
    
    public enum FlightError: Error, LocalizedError {
        
    }
    
    fileprivate static func argumentSummary(
        _ encodeBlock: @escaping OutgoingMessage.ArgumentEncodeBlock
    ) -> String? {
        struct Container: Encodable {
            let block: OutgoingMessage.ArgumentEncodeBlock
            func encode(to encoder: Encoder) throws {
                var c = encoder.unkeyedContainer()
                try block(&c)
            }
        }
        
        guard
            let data = try? JSONEncoder().encode(Container(block: encodeBlock)),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        
        return str
    }
}
