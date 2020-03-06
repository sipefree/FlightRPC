//
//  Flight.swift
//
//
//  Created by Simon Free on 2020-03-05.
//

import Combine
import Foundation
import Network

public enum Flight {
    
    public class Connection {
        
        public init(
            to endpoint: NWEndpoint,
            using parameters: NWParameters
        ) {
            connection = NWConnection(to: endpoint, using: parameters)
            
            incomingMessagePublisher = incomingDataSubject
                .flatMap { (data: Data) in data.publisher }
                .collectMessageData()
                .decode(type: IncomingMessage.self, decoder: decoder)
                .handleEvents(receiveCompletion: { error in
                    Swift.print("Decoding Error: \(error)")
                })
                .retry(Int.max)
                .assertNoFailure()
                .multicast { PassthroughSubject<IncomingMessage, Never>() }
                .eraseToAnyPublisher()
            
            outgoingDataPublisher = outgoingMessageSubject
                .encode(encoder: encoder)
                .eraseToAnyPublisher()
                .handleEvents(receiveCompletion: { error in
                    Swift.print("Encoding Error: \(error)")
                })
                .retry(Int.max)
                .assertNoFailure()
                .map { (origData: JSONEncoder.Output) -> Data in
                    var data: Data = origData
                    data.append(UInt8(0))
                    return data
                }
                .eraseToAnyPublisher()
        }
        
        private let connection: NWConnection
        
        private let outgoingMessageSubject = PassthroughSubject<OutgoingMessage, Never>()
        private let outgoingDataPublisher: AnyPublisher<Data, Never>
        
        private let incomingDataSubject = PassthroughSubject<Data, Never>()
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
        
        public typealias ResponseFuture = Future<OutgoingMessage.ArgumentEncoder, Never>
        public typealias ResponsePromise = ResponseFuture.Promise
        public typealias IncomingHandler = (inout UnkeyedDecodingContainer, ResponsePromise?) -> Void
        
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
                    
                    if call.expectResp {
                        ResponseFuture { promise in
                            var container = call.msg.container
                            handler(&container, promise)
                        }
                        .sink { [weak self] (argumentEncoder: @escaping OutgoingMessage.ArgumentEncoder) in
                            let responseMsg = OutgoingMessage(
                                kind: .response(call.msg.id),
                                encodeArguments: argumentEncoder
                            )
                            
                            self?.outgoingMessageSubject.send(responseMsg)
                        }
                        .store(in: &self.cancellables)
                    } else {
                        var container = call.msg.container
                        handler(&container, nil)
                    }
                }
        }
        
        public func sendOutgoingCall(
            named name: String,
            with encoder: @escaping OutgoingMessage.ArgumentEncoder,
            response handler: @escaping IncomingMessage.ArgumentDecoder?
        ) {
            let msg = OutgoingMessage(
                kind: .methodCall(name, expectResponse: handler != nil),
                encodeArguments: encoder
            )
            
            if let respHandler = handler {
                incomingMessagePublisher
                    .filter { (msg: IncomingMessage) -> Bool in
                        guard
                            case .response(let respID) = msg.kind,
                            respUUID == msg.id
                        else { return false }
                        return true
                    }
                    
            }
        }
        
        
//        private enum State {
//            case idle
//            case incomingDemand(IncomingSubscribers)
//            case outgoingDemand(Subscribers.Demand, OutgoingSubscriptions)
//            case duplexDemand(Subscribers.Demand, OutgoingSubscriptions, IncomingSubscribers)
//        }
        
//        private var state: State = .idle
//
//        private func updateDemand() {
//            switch state {
//
//            case .idle:
//                break
//
//            case .incomingDemand(let subscribers):
//                for sub
//
//            case .outgoingDemand(let outgoings):
//                for sub in outgoings {
//
//                }
//
//            }
//        }
        
//        private func cancelOutgoing(_ subscription: AnyOutgoingSubscription) {
//
//        }
//
//        private class AnyOutgoingSubscription: Hashable {
//
//            init(parent: Connection) {
//                self.parent = parent
//            }
//
//            weak var parent: Connection?
//
//            func receiveMessage(_ message: OutgoingMessage) { }
//        }
//
//        private final class OutgoingSubscription<S: Subscriber>:
//            AnyOutgoingSubscription,
//            Subscription
//        {
//
//            init(parent: Connection, subscriber: S) {
//                self.subscriber = subscriber
//                super.init(parent: parent)
//            }
//
//            private let subscriber: S
//
//            var demand: Subscribers.Demand = .max(0)
//
//            func receiveMessage(_ message: OutgoingMessage) {
//                guard demand > 0 else { return }
//                demand -= 1
//                demand += subscriber.receive(message)
//                parent?.updateDemand()
//            }
//
//            func request(_ demand: Subscribers.Demand) {
//                self.demand += demand
//                parent?.updateDemand()
//            }
//
//            func cancel() {
//                parent?.cancelOutgoing(self)
//            }
//        }
//
//        public func receive(subscription: Subscription) {
//            switch state {
//
//            }
//        }
//
//        public func receive<S>(subscriber: S)
//            where
//                S : Subscriber,
//                Self.Failure == S.Failure,
//                Self.Output == S.Input
//        {
//
//        }

    }
    
    public enum MessageKind {
        case methodCall(String, expectResponse: Bool)
        case response(UUID)
        
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
    
    public struct OutgoingMessage: Encodable {
        
        public typealias ArgumentEncoder = (inout UnkeyedEncodingContainer) throws -> Void
        
        public init(id: UUID = UUID(), kind: MessageKind, encodeArguments: @escaping ArgumentEncoder) {
            self.id = id
            self.kind = kind
            self.encodeArguments = encodeArguments
        }
        
        public let id: UUID
        
        public let kind: MessageKind
        
        private let encodeArguments: ArgumentEncoder
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(id)
            try kind.encode(to: &container)
            try encodeArguments(&container)
        }
        
    }
    
    public struct IncomingMessage: Decodable {
        
        public typealias ArgumentDecoder = (inout UnkeyedDecodingContainer) throws -> Void
        
        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            self.id = try container.decode(UUID.self)
            self.kind = try MessageKind(from: &container)
            self.container = container
        }
        
        public let id: UUID
        
        public let kind: MessageKind
        
        public let container: UnkeyedDecodingContainer
        
    }
    
    
    //public class MessageChannel: ConnectablePublisher {
        
        //public typealias Output =
        
    //}
    
    public enum FlightError: Error, LocalizedError {
        
    }
    
    fileprivate struct MessageCollector<Upstream: Publisher>:
        Publisher
    where
        Upstream.Output == UInt8
    {
        
        typealias Output = Data
        typealias Failure = Upstream.Failure
        
        init(upstream: Upstream) {
            self.upstream = upstream
        }
        
        private let upstream: Upstream
        
        func receive<S>(subscriber: S)
        where
            S : Subscriber,
            Self.Failure == S.Failure,
            Self.Output == S.Input
        {
            let inner = Inner(downstream: subscriber)
            upstream.subscribe(inner)
            subscriber.receive(subscription: inner)
        }
        
        private final class Inner<Downstream: Subscriber>:
            Subscriber,
            Subscription
        where
            Downstream.Input == Data,
            Downstream.Failure == Upstream.Failure
        {
            
            typealias Input = Upstream.Output
            typealias Failure = Upstream.Failure
            typealias Demand = Subscribers.Demand
            
            fileprivate enum State {
                case awaitingFirstEOM(Demand)
                case collecting(Demand, Data)
                case fullMessage(Data)
                
                var demand: Demand {
                    if case .fullMessage = self {
                        return .none
                    } else {
                        return .unlimited
                    }
                }
                
                private func makeBuffer() -> Data { Data(capacity: 1024) }
                
                private mutating func sendBuffer(_ buffer: Data, to downstream: Downstream) {
                    let demand = downstream.receive(buffer)
                    self = .collecting(demand, makeBuffer())
                }
                
                mutating func receiveByte(_ byte: UInt8, downstream: Downstream) {
                    let EOM: UInt8 = 0
                    
                    switch (byte, self) {
                        
                    case (EOM, .awaitingFirstEOM(let demand)):
                        self = .collecting(demand, makeBuffer())
                    
                    case (EOM, .collecting(.none, let buffer)):
                        self = .fullMessage(buffer)
                        
                    case (EOM, .collecting(_, let buffer)):
                        sendBuffer(buffer, to: downstream)
                        
                    case (let byte, .collecting(let demand, var buffer)):
                        buffer.append(byte)
                        self = .collecting(demand, buffer)
                        
                    case (_, .fullMessage):
                        break
                        
                    case (_, .awaitingFirstEOM):
                        break
                    
                    }
                }
                
                mutating func requestDemand(_ demand: Demand, downstream: Downstream) {
                    switch (demand, self) {
                        
                    case (let newDemand, .awaitingFirstEOM):
                        self = .awaitingFirstEOM(newDemand)
                        
                    case (let newDemand, .collecting(_, let buffer)):
                        self = .collecting(newDemand, buffer)
                        
                    case (.none, .fullMessage(_)):
                        break
                        
                    case (_, .fullMessage(let buffer)):
                        sendBuffer(buffer, to: downstream)
                    }
                }
            }
            
            let downstream: Downstream
            var subscription: Subscription?
            var state = State.awaitingFirstEOM(.max(0))
            
            init(downstream: Downstream) {
                self.downstream = downstream
            }
            
            func receive(subscription: Subscription) {
                self.subscription = subscription
                subscription.request(state.demand)
            }
            
            func receive(_ input: UInt8) -> Subscribers.Demand {
                state.receiveByte(input, downstream: downstream)
                return state.demand
            }
        
            func request(_ demand: Subscribers.Demand) {
                state.requestDemand(demand, downstream: downstream)
                subscription?.request(state.demand)
            }
            
            func receive(completion: Subscribers.Completion<Upstream.Failure>) {
                downstream.receive(completion: completion)
            }
            
            func cancel() {
                subscription?.cancel()
                subscription = nil
            }
        }
        
    }
    
}

extension Publisher where Output == UInt8 {
    
    fileprivate func collectMessageData() -> Flight.MessageCollector<Self> {
        Flight.MessageCollector(upstream: self)
    }
    
}
