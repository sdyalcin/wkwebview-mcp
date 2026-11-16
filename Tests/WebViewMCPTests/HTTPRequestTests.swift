import XCTest
@testable import WebViewMCP

final class HTTPRequestTests: XCTestCase {
  func testParsesRequestWithQueryAndBody() throws {
    let raw = "POST /eval?webview=wv1&limit=5 HTTP/1.1\r\nHost: 127.0.0.1:9333\r\nContent-Length: 16\r\n\r\n{\"code\":\"1 + 1\"}trailing"
    guard case let .complete(request) = HTTPRequest.parse(Data(raw.utf8)) else {
      return XCTFail("Expected a complete request")
    }
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/eval")
    XCTAssertEqual(request.string("webview"), "wv1")
    XCTAssertEqual(request.int("limit"), 5)
    XCTAssertEqual(request.string("code"), "1 + 1")
    XCTAssertEqual(request.headers["host"], "127.0.0.1:9333")
  }

  func testWaitsForTheWholeBody() {
    let raw = "POST /eval HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":"
    guard case .incomplete = HTTPRequest.parse(Data(raw.utf8)) else {
      return XCTFail("Expected incomplete")
    }
  }

  func testWaitsForTheEndOfHeaders() {
    guard case .incomplete = HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)) else {
      return XCTFail("Expected incomplete")
    }
  }

  func testRejectsMalformedRequestLine() {
    guard case .invalid = HTTPRequest.parse(Data("NONSENSE\r\n\r\n".utf8)) else {
      return XCTFail("Expected invalid")
    }
  }

  func testBooleanParameters() throws {
    guard case let .complete(request) = HTTPRequest.parse(Data("GET /console?clear=true&failed=0 HTTP/1.1\r\n\r\n".utf8)) else {
      return XCTFail("Expected a complete request")
    }
    XCTAssertTrue(request.bool("clear"))
    XCTAssertFalse(request.bool("failed"))
    XCTAssertFalse(request.bool("missing"))
  }
}
