import XCTest
@testable import WebViewMCP

final class JavaScriptTests: XCTestCase {
  func testSingleExpressionIsReturned() {
    XCTAssertEqual(JavaScript.implicitReturn("document.title"), "return (document.title);")
    XCTAssertEqual(JavaScript.implicitReturn("  location.href;  "), "return (location.href);")
  }

  func testStatementsAreLeftAlone() {
    XCTAssertEqual(JavaScript.implicitReturn("return 1"), "return 1")
    XCTAssertEqual(JavaScript.implicitReturn("const a = 1; return a"), "const a = 1; return a")
    XCTAssertEqual(JavaScript.implicitReturn("if (x) { y() }"), "if (x) { y() }")
    XCTAssertEqual(JavaScript.implicitReturn("a()\nb()"), "a()\nb()")
  }
}
