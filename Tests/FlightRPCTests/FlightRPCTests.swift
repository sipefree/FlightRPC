import XCTest
@testable import FlightRPC
import Network
import Combine

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
        
        init(at endpoint: NWEndpoint, parameters: NWParameters, exporting local: AnyObject&ClientProtocol) {
            self.local = local
            super.init(at: endpoint, using: parameters)
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
                named: "clientMethodA(bing:bang:completion:)"
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
        
        init(at endpoint: NWEndpoint, parameters: NWParameters, exporting local: AnyObject&ServerProtocol) {
            self.local = local
            super.init(at: endpoint, using: parameters)
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


final class FlightRPCTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        //XCTAssertEqual(FlightRPC().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
