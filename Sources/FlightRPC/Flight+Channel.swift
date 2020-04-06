//
//  Flight+Channel.swift
//  
//
//  Created by Simon Free on 2020-03-08.
//

import Foundation
import Combine
import os
import Network

extension Flight {
    
    public class Channel {
        
        public init(connection: Flight.Connection?, name: String) {
            let log = OSLog(subsystem: "FlightRPC", category: name)
            self.log = log
            
            self.connection = connection
            self.name = name
            
            self.connectionStatePublisher = CurrentValueSubject(connection?.connectionStatePublisher.value ?? .setup)
            
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
                .merge(with: Just(Data([UInt8(0)])))
                .share()
                .eraseToAnyPublisher()
            
            
            if let connection = connection {
                outgoingDataPublisher
                    .buffer(size: 128, prefetch: .keepFull, whenFull: .dropOldest)
                    .subscribe(connection)
                
                connection
                    .sink { [weak self] data in
                        self?.incomingDataSubject.send(data)
                    }
                    .store(in: &cancellables)
                
                connection.connectionStatePublisher
                    .sink { [weak self] (state) in
                        self?.connectionStatePublisher.send(state)
                    }
                    .store(in: &cancellables)
            }
            
        }
        
        private var name: String
        
        private var log: OSLog
        
        private var connection: Flight.Connection?
        
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
        
        public func connect() {
            connection?.connect().store(in: &cancellables)
        }
        
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
        
        public var connectionStatePublisher: CurrentValueSubject<NWConnection.State, Never>

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
