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
    
    final class ServerProtocolProxy<Local: AnyObject&ClientProtocol>:
        Flight.RemoteProxy,
        ServerProtocol,
        FlightListener
    {
        
        typealias ExportedObject = Local
        
        init(connection: NWConnection?, exporting local: Local) {
            self.local = local
            super.init(connection: connection)
        }
        
        private weak var local: Local?
        
        override func registerIncomingMethods(cancellables: inout Set<AnyCancellable>) {
            channel.handleIncomingCalls(
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
            
            channel.handleIncomingCalls(
                named: "clientMethodB(boom:)"
            ) { [weak self] (dec, promise) in
                
                self?.local?.clientMethodB(
                    boom: try dec.decode(Double.self)
                )
                
            }.store(in: &cancellables)
        }
        
        func serverMethodA(foo: String, bar: Int, completion: @escaping (Int) -> Void) {
            
            channel.sendOutgoingCall(
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
            
            channel.sendOutgoingCall(
                named: "serverMethodB(baz:)",
                with: { enc in
                    try enc.encode(baz)
                }
            )
            
        }
        
    }
    
    final class ClientProtocolProxy<Local: AnyObject&ServerProtocol>:
        Flight.RemoteProxy,
        ClientProtocol,
        FlightListener
    {
        
        typealias ExportedObject = Local
        
        init(connection: NWConnection?, exporting local: Local) {
            self.local = local
            super.init(connection: connection)
        }
        
        private weak var local: Local?
        
        override func registerIncomingMethods(cancellables: inout Set<AnyCancellable>) {
            channel.handleIncomingCalls(
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
            
            channel.handleIncomingCalls(
                named: "serverMethodB(baz:)"
            ) { [weak self] (dec, promise) in
                
                self?.local?.serverMethodB(
                    baz: try dec.decode(Int.self)
                )
                
            }.store(in: &cancellables)
        }
        
        func clientMethodA(bing: Int, bang: String, completion: @escaping (Float) -> Void) {
            
            channel.sendOutgoingCall(
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
            
            channel.sendOutgoingCall(
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
        //os_log("->CLIENT clientMethodA(bing: %ld, bang: %@)", log: log, bing, bang)
        DispatchQueue.main.async {
            let resp: Float = 42.2
            //os_log("<-CLIENT (response) clientMethodA: %.1f", log: log, resp)
            completion(resp)
            self.methodAExpectation.fulfill()
        }
    }
    
    func clientMethodB(boom: Double) {
        //os_log("->CLIENT clientMethodB(boom: %.2f)", log: log, boom)
        self.methodBExpectation.fulfill()
    }
    
}

class TestServerImpl: ServerProtocol {
    
    var methodAExpectation = XCTestExpectation(description: "TestServerImpl receives serverMethodA.")
    var methodBExpectation = XCTestExpectation(description: "TestServerImpl receives serverMethodB.")
    
    func serverMethodA(foo: String, bar: Int, completion: @escaping (Int) -> Void) {
        //os_log("->SERVER serverMethodA(foo: %@, bar: %ld)", log: log, foo, bar)
        DispatchQueue.main.async {
            let resp: Int = 22
            //os_log("<-SERVER (response) serverMethodA: %ld", log: log, resp)
            completion(resp)
            self.methodAExpectation.fulfill()
        }
    }
    
    func serverMethodB(baz: Int) {
        //os_log("->SERVER serverMethodB(baz: %ld)", log: log, baz)
        self.methodBExpectation.fulfill()
    }
    
    
    
    
}

final class FlightRPCTests: XCTestCase {
    
    var cancellables = Set<AnyCancellable>()
    
    var clientImpl: TestClientImpl! = nil
    var serverImpl: TestServerImpl! = nil
    
    var clientProxy: TestProtocols.ClientProtocolProxy<TestServerImpl>! = nil
    var serverProxy: TestProtocols.ServerProtocolProxy<TestClientImpl>! = nil
    
    var expectations: [XCTestExpectation] {
        [
            clientImpl.methodAExpectation,
            clientImpl.methodBExpectation,
            serverImpl.methodAExpectation,
            serverImpl.methodBExpectation,
            clientAResponseExpectation,
            serverAResponseExpectation
        ]
    }
    
    var clientAResponseExpectation: XCTestExpectation! = nil
    var serverAResponseExpectation: XCTestExpectation! = nil
    
    override func setUp() {
        keepAlive = []
        
        clientImpl = TestClientImpl()
        serverImpl = TestServerImpl()
        
        clientAResponseExpectation = XCTestExpectation(description: "Client responds to clientMethodA.")
        serverAResponseExpectation = XCTestExpectation(description: "Server responds to serverMethodA.")
    }
    
    func off_testDataFlow() {
        clientProxy = TestProtocols.ClientProtocolProxy(connection: nil, exporting: serverImpl)
        serverProxy = TestProtocols.ServerProtocolProxy(connection: nil, exporting: clientImpl)
        
        let dataToClient = clientProxy.channel.outgoingDataPublisher
        let dataToServer = serverProxy.channel.outgoingDataPublisher
        
        let dataFromClient = clientProxy.channel.incomingDataSubject
        let dataFromServer = serverProxy.channel.incomingDataSubject
        
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
        
        clientProxy.clientMethodA(bing: 1, bang: "Test Bang") { (resp) in
            //os_log("->TEST clientMethodA resp: %.2f", log: log, resp)
            self.clientAResponseExpectation.fulfill()
        }
        
        serverProxy.serverMethodB(baz: 5)

        serverProxy.serverMethodA(foo: "Test Foo", bar: 8982) { (resp) in
            //os_log("->TEST serverMethodA resp: %ld", log: log, resp)
            self.serverAResponseExpectation.fulfill()
        }

        clientProxy.clientMethodB(boom: 189.6)
        
        wait(for: expectations, timeout: 2)
    }
    
    private func makeSocketEndpoint() -> NWEndpoint {
        let uuid = UUID().uuidString
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let sockFile = tempDir.appendingPathComponent("\(uuid).sock")
        return NWEndpoint.unix(path: sockFile.path)
    }
    
    private func makeSocketParameters(endpoint: NWEndpoint? = nil) -> NWParameters {
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = endpoint ?? makeSocketEndpoint()
        return params
    }
    
    func off_testUnixSocket() {
        let endpoint = makeSocketEndpoint()
        let params = makeSocketParameters(endpoint: endpoint)
        
        let listener = try! NWListener(using: params)
        
        let connectionA = NWConnection(to: endpoint, using: params)
        
        let listenQueue = DispatchQueue(label: "ListenQueue")
        let connectQueue = DispatchQueue(label: "ConnectQueue")
        
        let listenReady = expectation(description: "Listen ready.")
        
        let connAReady = expectation(description: "Connection A ready.")
        let connBReady = expectation(description: "Connection B ready.")
        let connError = expectation(description: "No error occurred.")
        connError.isInverted = true
        
        listener.stateUpdateHandler = { state in
            if state == .ready {
                listenReady.fulfill()
                connectionA.start(queue: connectQueue)
            }
        }
        
        var recvData = Data()
        
        let messageStr = String("Here's to the crazy ones.")
        let messageData = messageStr.data(using: .utf8)!
        let messageCorrect = expectation(description: "Message correct.")
        
        func doReceiveA() {
            connectionA.receive(
                minimumIncompleteLength: 1,
                maximumLength: 1024
            ) { (data, context, finished, error) in
                guard let data = data, error == nil else {
                    connError.fulfill()
                    return
                }
                
                recvData.append(data)
                
                if finished || recvData.count == messageData.count {
                    let receivedStr = String(data: recvData, encoding: .utf8)!
                    if receivedStr == messageStr {
                        messageCorrect.fulfill()
                    }
                } else {
                    doReceiveA()
                }
            }
        }
        
        connectionA.stateUpdateHandler = { state in
            if state == .ready {
                connAReady.fulfill()
                
                doReceiveA()
            }
        }
        
        var connectionB: NWConnection!
        let messageSent = expectation(description: "Message sent.")
        
        func doSendB() {
            connectionB.send(content: messageData, completion: .contentProcessed({ (error) in
                guard error == nil else {
                    connError.fulfill()
                    return
                }
                
                messageSent.fulfill()
            }))
        }
        
        listener.newConnectionHandler = { conn in
            connectionB = conn
            
            connectionB.stateUpdateHandler = { state in
                if state == .ready {
                    connBReady.fulfill()
                    
                    doSendB()
                }
            }
            
            connectionB.start(queue: listenQueue)
        }
        
        listener.start(queue: listenQueue)
        
        waitForExpectations(timeout: 0.2, handler: nil)
        
    }
    
    private var keepAlive = [Any]()
    
    func off_testConnection() {
        let endpoint = makeSocketEndpoint()
        let params = makeSocketParameters(endpoint: endpoint)
        
        let listener = try! NWListener(using: params)
        
        let connectionA = NWConnection(to: endpoint, using: params)
        let flightA = Flight.Connection(connection: connectionA, name: "Flight-A")
        
        let outgoingA = PassthroughSubject<Data, Never>()
        let outgoingB = PassthroughSubject<Data, Never>()
        
        let outgoingABuffer = outgoingA
            .buffer(size: 256, prefetch: .keepFull, whenFull: .dropOldest)
        
        let outgoingBBuffer = outgoingB
            .buffer(size: 256, prefetch: .keepFull, whenFull: .dropOldest)
        
        let listenQueue = DispatchQueue(label: "ListenQueue")
        
        let listenReady = expectation(description: "Listen ready.")
        let connError = expectation(description: "No error occurred.")
        connError.isInverted = true
        
        let messageFromA = String("Message from A")
        let messageDataFromA = messageFromA.data(using: .utf8)!
        let messageFromACorrect = expectation(description: "Message from A correct.")
        
        let messageFromB = String("Message from B")
        let messageDataFromB = messageFromB.data(using: .utf8)!
        let messageFromBCorrect = expectation(description: "Message from B correct.")
        
        var recvA = Data()
        var recvB = Data()
        
        listener.stateUpdateHandler = { state in
            if state == .ready {
                listenReady.fulfill()
                
                outgoingABuffer.subscribe(flightA)
                
                flightA.sink { incomingA in
                    recvA.append(incomingA)
                    
                    if recvA.count == messageDataFromB.count {
                        let recvAString = String(data: recvA, encoding: .utf8)!
                        if recvAString == messageFromB {
                            messageFromBCorrect.fulfill()
                        }
                    }
                }.store(in: &self.cancellables)
                
                flightA.connect().store(in: &self.cancellables)
            }
        }
        
        var connectionB: NWConnection!
        var flightB: Flight.Connection!
        
        listener.newConnectionHandler = { conn in
            
            connectionB = conn
            flightB = Flight.Connection(connection: connectionB, name: "Flight-B")
            
            self.keepAlive.append(contentsOf: [connectionB!, flightB!])
            
            outgoingBBuffer.subscribe(flightB)
            
            flightB.sink { incomingB in
                recvB.append(incomingB)
                
                if recvB.count == messageDataFromA.count {
                    let recvBString = String(data: recvB, encoding: .utf8)!
                    if recvBString == messageFromA {
                        messageFromACorrect.fulfill()
                    }
                    
                    outgoingB.send(messageDataFromB)
                }
            }.store(in: &self.cancellables)
            
            flightB.connect().store(in: &self.cancellables)
            
            outgoingA.send(messageDataFromA)
            
        }
        
        listener.start(queue: listenQueue)
        
        keepAlive = [
            listener,
            connectionA,
            flightA,
            outgoingA,
            outgoingB,
            outgoingABuffer,
            outgoingBBuffer
        ]
        
        waitForExpectations(timeout: 0.2, handler: nil)
        
    }
    
    func testChannel() {
        let endpoint = makeSocketEndpoint()
        let params = makeSocketParameters(endpoint: endpoint)
        
        let clientConnected = expectation(description: "Client connected.")
        
        serverProxy = TestProtocols.ServerProtocolProxy(
            endpoint: endpoint,
            parameters: params,
            exporting: clientImpl
        )
        
        serverProxy.serverMethodB(baz: 5)

        serverProxy.serverMethodA(foo: "Test Foo", bar: 8982) { (resp) in
            //os_log("->TEST serverMethodA resp: %ld", log: log, resp)
            self.serverAResponseExpectation.fulfill()
        }
        
        try! TestProtocols.ClientProtocolProxy.listen(
            exporting: serverImpl,
            using: params
        ) { (clientProxy) in
            clientConnected.fulfill()
            
            self.clientProxy = clientProxy
            
            clientProxy.clientMethodA(bing: 1, bang: "Test Bang") { (resp) in
                //os_log("->TEST clientMethodA resp: %.2f", log: log, resp)
                self.clientAResponseExpectation.fulfill()
            }

            clientProxy.clientMethodB(boom: 189.6)
            
        }.store(in: &cancellables)
        
        wait(for: expectations + [clientConnected], timeout: 2)
        
    }

    static var allTests = [
        //("testDataFlow", testDataFlow),
        //("testUnixSocket", testUnixSocket),
        //("testConnection", testConnection)
        ("testChannel", testChannel)
    ]
}
