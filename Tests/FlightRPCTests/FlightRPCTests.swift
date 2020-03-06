import XCTest
@testable import FlightRPC

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
CharacterSet.alphanumerics

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


final class FlightRPCTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(FlightRPC().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
