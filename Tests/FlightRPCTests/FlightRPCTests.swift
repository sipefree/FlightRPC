import XCTest
@testable import FlightRPC
import Network
import Combine
import os

let log = OSLog(subsystem: "FlightTests", category: "Tests")

enum TestProtocols {  }

protocol ServerProtocol: FlightProtocol {
    
    typealias Suite = TestProtocols
    
    func serverMethodA(
        foo: String,
        bar: Int,
        completion: @escaping (Int) -> Void
    )
    
    func serverMethodB(
        baz: Int
    )
    
}


protocol ClientProtocol: FlightProtocol {
    
    typealias Suite = TestProtocols
    
    func clientMethodA(
        bing: Int,
        bang: String,
        completion: @escaping (Float) -> Void
    )
    
    func clientMethodB(
        boom: Double
    )
    
}

extension TestProtocols {
    
    class ServerProtocolProxy: Flight.RemoteProxy, ServerProtocol {
        
        init(connection: NWConnection?, exporting local: AnyObject&ClientProtocol) {
            self.local = local
            super.init(connection: connection)
        }
        
        private weak var local: (AnyObject&ClientProtocol)?
        
        override func registerIncomingMethods(cancellables: inout Set<AnyCancellable>) {
            connection.handleIncomingCalls(
                named: "clientMethodA(bing:bang:completion:)"
            ) { [weak self] (dec, fulfill) in
                
                self?.local?.clientMethodA(
                    bing: try dec.decode(Int.self),
                    bang: try dec.decode(String.self),
                    completion: { arg0 in
                        fulfill?({ enc in
                            try enc.encode(arg0)
                        })
                    }
                )
                
            }.store(in: &cancellables)
            
            connection.handleIncomingCalls(
                named: "clientMethodB(boom:)"
            ) { [weak self] (dec, promise) in
                
                self?.local?.clientMethodB(
                    boom: try dec.decode(Double.self)
                )
                
            }.store(in: &cancellables)
        }
        
        func serverMethodA(foo: String, bar: Int, completion: @escaping (Int) -> Void) {
            
            connection.sendOutgoingCall(
                named: "serverMethodA(foo:bar:completion:)",
                with: { enc in
                    try enc.encode(foo)
                    try enc.encode(bar)
                },
                response: { dec in
                    completion(try dec.decode(Int.self))
                }
            )
            
        }
        
        func serverMethodB(baz: Int) {
            
            connection.sendOutgoingCall(
                named: "serverMethodB(baz:)",
                with: { enc in
                    try enc.encode(baz)
                }
            )
            
        }
        
    }
    
    class ClientProtocolProxy: Flight.RemoteProxy, ClientProtocol {
        
        init(connection: NWConnection?, exporting local: AnyObject&ServerProtocol) {
            self.local = local
            super.init(connection: connection)
        }
        
        private weak var local: (AnyObject&ServerProtocol)?
        
        override func registerIncomingMethods(cancellables: inout Set<AnyCancellable>) {
            connection.handleIncomingCalls(
                named: "serverMethodA(foo:bar:completion:)"
            ) { [weak self] (dec, fulfill) in
                
                self?.local?.serverMethodA(
                    foo: try dec.decode(String.self),
                    bar: try dec.decode(Int.self),
                    completion: { arg0 in
                        fulfill?({ enc in
                            try enc.encode(arg0)
                        })
                    }
                )
                
            }.store(in: &cancellables)
            
            connection.handleIncomingCalls(
                named: "serverMethodB(baz:)"
            ) { [weak self] (dec, promise) in
                
                self?.local?.serverMethodB(
                    baz: try dec.decode(Int.self)
                )
                
            }.store(in: &cancellables)
        }
        
        func clientMethodA(bing: Int, bang: String, completion: @escaping (Float) -> Void) {
            
            connection.sendOutgoingCall(
                named: "clientMethodA(bing:bang:completion:)",
                with: { enc in
                    try enc.encode(bing)
                    try enc.encode(bang)
                },
                response: { dec in
                    completion(try dec.decode(Float.self))
                }
            )
            
        }
        
        func clientMethodB(boom: Double) {
            
            connection.sendOutgoingCall(
                named: "clientMethodB(boom:)",
                with: { enc in
                    try enc.encode(boom)
                }
            )
            
        }
        
    }
    
}

class TestClientImpl: ClientProtocol {
    
    var methodAExpectation = XCTestExpectation(description: "TestClientImpl receives clientMethodA.")
    var methodBExpectation = XCTestExpectation(description: "TestClientImpl receives clientMethodB.")
    
    func clientMethodA(bing: Int, bang: String, completion: @escaping (Float) -> Void) {
        os_log("->CLIENT clientMethodA(bing: %ld, bang: %@)", log: log, bing, bang)
        print()
        DispatchQueue.main.async {
            let resp: Float = 42.2
            os_log("<-CLIENT (response) clientMethodA: %.1f", log: log, resp)
            completion(resp)
            self.methodAExpectation.fulfill()
        }
    }
    
    func clientMethodB(boom: Double) {
        os_log("->CLIENT clientMethodB(boom: %.2f)", log: log, boom)
        self.methodBExpectation.fulfill()
    }
    
}

class TestServerImpl: ServerProtocol {
    
    var methodAExpectation = XCTestExpectation(description: "TestServerImpl receives serverMethodA.")
    var methodBExpectation = XCTestExpectation(description: "TestServerImpl receives serverMethodB.")
    
    func serverMethodA(foo: String, bar: Int, completion: @escaping (Int) -> Void) {
        os_log("->SERVER serverMethodA(foo: %@, bar: %ld)", log: log, foo, bar)
        DispatchQueue.main.async {
            let resp: Int = 22
            os_log("<-SERVER (response) serverMethodA: %ld", log: log, resp)
            completion(resp)
            self.methodAExpectation.fulfill()
        }
    }
    
    func serverMethodB(baz: Int) {
        os_log("->SERVER serverMethodB(baz: %ld)", log: log, baz)
        self.methodBExpectation.fulfill()
    }
    
    
    
    
}

final class FlightRPCTests: XCTestCase {
    
    var cancellables = Set<AnyCancellable>()
    
    var clientImpl: TestClientImpl!
    var serverImpl: TestServerImpl!
    
    var clientProxy: TestProtocols.ClientProtocolProxy!
    var serverProxy: TestProtocols.ServerProtocolProxy!
    
    func testDataFlow() {
        let clientImpl = TestClientImpl()
        let serverImpl = TestServerImpl()
        
        let clientProxy = TestProtocols.ClientProtocolProxy(connection: nil, exporting: serverImpl)
        let serverProxy = TestProtocols.ServerProtocolProxy(connection: nil, exporting: clientImpl)
        
        let dataToClient = clientProxy.connection.outgoingDataPublisher
        let dataToServer = serverProxy.connection.outgoingDataPublisher
        
        let dataFromClient = clientProxy.connection.incomingDataSubject
        let dataFromServer = serverProxy.connection.incomingDataSubject
        
        let clientAResponseExpectation = XCTestExpectation(description: "Client responds to clientMethodA.")
        let serverAResponseExpectation = XCTestExpectation(description: "Server responds to serverMethodA.")
        
        func setupDataFlow(
            from outPublisher: AnyPublisher<Data, Never>,
            to inSubject: PassthroughSubject<Data, Never>
        ) -> AnyCancellable {
            let pipe = outPublisher
                .flatMap { (data: Data) -> Publishers.Sequence<[Data], Never> in
                    let packetSize = 10
                    let packets: [Data] = stride(
                        from: data.startIndex,
                        to: data.endIndex,
                        by: packetSize
                    ).map { (index: Int) -> Data in
                        let endIndex = data.index(index, offsetBy: packetSize, limitedBy: data.endIndex) ?? data.endIndex
                        return Data(data[index..<endIndex])
                    }
                    return packets.publisher
                }
                .sink { (packet: Data) in
                    inSubject.send(packet)
                }
            
            inSubject.send(Data(repeating: 0, count: 1))
            
            return pipe
        }
        
        setupDataFlow(from: dataToClient, to: dataFromServer).store(in: &cancellables)
        setupDataFlow(from: dataToServer, to: dataFromClient).store(in: &cancellables)
        
//        clientProxy.clientMethodA(bing: 1, bang: "Test Bang") { (resp) in
//            os_log("->TEST clientMethodA resp: %.2f", log: log, resp)
//            clientAResponseExpectation.fulfill()
//        }
        
//        serverProxy.serverMethodB(baz: 5)

        serverProxy.serverMethodA(foo: "Test Foo", bar: 8982) { (resp) in
            os_log("->TEST serverMethodA resp: %ld", log: log, resp)
            serverAResponseExpectation.fulfill()
        }

        clientProxy.clientMethodB(boom: 189.6)
        
        self.clientImpl = clientImpl
        self.clientProxy = clientProxy
        self.serverImpl = serverImpl
        self.serverProxy = serverProxy
        
        let expectations = [
//            clientImpl.methodAExpectation,
            clientImpl.methodBExpectation,
            serverImpl.methodAExpectation,
//            serverImpl.methodBExpectation,
//            clientAResponseExpectation,
            serverAResponseExpectation
        ]
        
        wait(for: expectations, timeout: 10000000)
    }

    static var allTests = [
        ("testDataFlow", testDataFlow),
    ]
}
