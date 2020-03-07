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

public enum Flight {
    
    public class Connection {
        
        public convenience init(
            to endpoint: NWEndpoint,
            using parameters: NWParameters
        ) {
            self.init(connection: NWConnection(to: endpoint, using: parameters), name: "Default")
        }
        
        public init(connection: NWConnection?, name: String) {
            let log = OSLog(subsystem: "Flight", category: name)
            self.log = log
            
            self.connection = connection
            self.name = name
            let endpoint = connection?.endpoint
            
            struct LogOut: TextOutputStream {
                let log: OSLog
                mutating func write(_ string: String) { os_log("%@", log: log, string) }
            }
            let logOut = LogOut(log: log)
            
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
                .collectMessageData()
                .handleEvents(receiveOutput: { data in
                    os_log("    <IN Data: %@>", log: log, String(data: data, encoding: .utf8)!)
                })

                .decode(type: IncomingMessage.self, decoder: decoder)
                .handleEvents(receiveCompletion: { error in
                    os_log("Decoding error: %@", log: log, String(describing: error))
                })
                .retry(Int.max)
                .assertNoFailure()
                .handleEvents(receiveOutput: { msg in
                    os_log("  [IN Msg: %@]", log: log, String(describing: msg))
                })
                //.print("    <Incoming Msgs>", to: logOut)
                .share()
                .eraseToAnyPublisher()
                
            outgoingDataPublisher = outgoingMessageSubject
                .receive(on: encodingQueue)
                .handleEvents(receiveOutput: { msg in
                    os_log("  [OUT Msg: %@]", log: log, String(describing: msg))
                })
                .encode(encoder: encoder)
                .eraseToAnyPublisher()
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
                .handleEvents(receiveOutput: { data in
                    os_log("    <OUT Data: %@>", log: log, String(data: data, encoding: .utf8)!)
                })
                //.print("    <Outgoing Data>", to: logOut)
                .share()
                .eraseToAnyPublisher()
            
        }
        
        private var name: String
        
        private var log: OSLog
        
        private var connection: NWConnection?
        
        private let encodingQueue: DispatchQueue
        private let decodingQueue: DispatchQueue
        
        private let outgoingMessageSubject = PassthroughSubject<OutgoingMessage, Never>()
        let outgoingDataPublisher: AnyPublisher<Data, Never>
        
        let incomingDataSubject = PassthroughSubject<Data, Never>()
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
            os_log("Subscribe Incoming: %@", log: self.log, name)
            
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
                    
                    os_log("Dispatch Incoming: %@ (%@)", log: self.log, name, call.msg.id.uuidString)
                    
                    var responseFulfiller: ResponseFulfiller? = nil
                    
                    if call.expectResp {
                        os_log("  Expecting Response: %@", log: self.log, call.msg.id.uuidString)
                        
                        responseFulfiller = { [weak self] argEncodeBlock in
                            guard let self = self else { return }
                            
                            let responseMsg = OutgoingMessage(
                                kind: .response(call.msg.id),
                                encodeArguments: argEncodeBlock
                            )
                        
                            os_log("    Sending Response: %@", log: self.log, call.msg.id.uuidString)
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
            
            os_log("Sending %@: %@", log: self.log, name, outMsgID.uuidString)
            
            if let respHandler = handler {
                os_log("  Expect Response %@", log: self.log, outMsgID.uuidString)
                
                let cancellable = incomingMessagePublisher
                    .filter { (incMsg: IncomingMessage) -> Bool in
                        guard
                            case .response(let respID) = incMsg.kind,
                            respID == outMsgID
                        else { return false }
                        os_log("    Found Response: %@ (%@)", log: self.log, outMsgID.uuidString, incMsg.id.uuidString)
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
    
    open class RemoteProxy {
        
        public convenience init(
            at endpoint: NWEndpoint,
            using parameters: NWParameters
        ) {
            self.init(connection: NWConnection(to: endpoint, using: parameters))
        }
        
        public init(connection: NWConnection?) {
            self.connection = Connection(connection: connection, name: String(describing: type(of: self)))
            registerIncomingMethods(cancellables: &cancellables)
            //connection.resume()
        }
        
        public let connection: Connection
        
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
                    os_log("DEMAND5: %@ <%@>", String(describing: demand), String(data: buffer, encoding: .utf8)!)
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

extension Publisher where Output == UInt8 {
    
    fileprivate func collectMessageData() -> Flight.MessageCollector<Self> {
        Flight.MessageCollector(upstream: self)
    }
    
}
