import XCTest
@testable import ElinkAIBridge

final class HTTPServerTests: XCTestCase {
    private func request(contentLength: String, body: String = "") -> Data {
        Data("POST /v1/event HTTP/1.1\r\nContent-Length: \(contentLength)\r\n\r\n\(body)".utf8)
    }

    func testNegativeContentLengthIsRejectedInsteadOfCrashing() {
        let outcome = HTTPServer.parseRequest(from: request(contentLength: "-1"))
        XCTAssertEqual(outcome, .invalid)
    }

    func testNonNumericContentLengthIsRejected() {
        let outcome = HTTPServer.parseRequest(from: request(contentLength: "abc"))
        XCTAssertEqual(outcome, .invalid)
    }

    func testOversizedContentLengthIsRejected() {
        let outcome = HTTPServer.parseRequest(from: request(contentLength: "1000001"))
        XCTAssertEqual(outcome, .invalid)
    }

    func testDeclaredLengthLargerThanReceivedBodyWaitsForMoreData() {
        let outcome = HTTPServer.parseRequest(from: request(contentLength: "10", body: "abc"))
        XCTAssertEqual(outcome, .incomplete)
    }

    func testValidRequestParsesMethodPathAndBody() {
        let outcome = HTTPServer.parseRequest(from: request(contentLength: "3", body: "abc"))
        XCTAssertEqual(outcome, .complete(
            method: "POST", path: "/v1/event", query: [:],
            headers: ["content-length": "3"], body: Data("abc".utf8)
        ))
    }

    func testMissingHeaderTerminatorWaitsForMoreData() {
        let outcome = HTTPServer.parseRequest(from: Data("GET / HTTP/1.1\r\n".utf8))
        XCTAssertEqual(outcome, .incomplete)
    }
}
