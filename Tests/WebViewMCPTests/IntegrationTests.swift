import WebKit
import XCTest
@testable import WebViewMCP

/// Drives a real WKWebView through the HTTP server, the way the MCP server does.
@MainActor
final class IntegrationTests: XCTestCase {
  private static var port: UInt16?
  private var webView: WKWebView!

  override func setUp() async throws {
    if Self.port == nil {
      var configuration = WebViewMCP.Configuration()
      configuration.port = 19333
      Self.port = try await withCheckedThrowingContinuation { continuation in
        WebViewMCP.start(configuration) { continuation.resume(with: $0) }
      }
    }
    webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    WebViewMCP.register(webView, name: "test")
  }

  override func tearDown() async throws {
    WebViewMCP.unregister(webView)
    webView = nil
  }

  func testEvalConsoleAndNavigation() async throws {
    let html = """
    <html><head><title>Fixture</title></head><body>
    <button id="go">Go</button>
    <iframe srcdoc="<script>console.warn('from iframe')</script>"></iframe>
    <script>
      console.log('hello', { answer: 42 });
      console.error(new Error('boom'));
      history.pushState({}, '', '#step-2');
    </script>
    </body></html>
    """
    webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.test/"))
    try await waitUntil { !self.webView.isLoading && self.webView.title == "Fixture" }

    let title = try await call("POST", "/eval", body: ["webview": "test", "code": "document.title"])
    XCTAssertEqual(title["ok"] as? Bool, true)
    XCTAssertEqual(title["value"] as? String, "Fixture")

    let element = try await call("POST", "/eval", body: ["webview": "test", "code": "document.querySelector('#go')"])
    XCTAssertEqual(element["type"] as? String, "element")
    XCTAssertEqual(element["value"] as? String, "<button id=\"go\">Go</button>")

    let awaited = try await call("POST", "/eval", body: [
      "webview": "test",
      "code": "await new Promise(r => setTimeout(r, 50)); return { sum: 1 + 2, list: [1, 2] }",
    ])
    XCTAssertEqual((awaited["value"] as? [String: Any])?["sum"] as? Int, 3)

    let thrown = try await call("POST", "/eval", body: ["webview": "test", "code": "throw new TypeError('nope')"])
    XCTAssertEqual(thrown["ok"] as? Bool, false)
    XCTAssertTrue((thrown["error"] as? String ?? "").contains("nope"), "\(thrown)")

    let timedOut = try await call("POST", "/eval", body: [
      "webview": "test", "code": "await new Promise(() => {})", "timeoutMs": 300,
    ])
    XCTAssertEqual(timedOut["ok"] as? Bool, false)

    try await waitUntil {
      let console = try await self.call("GET", "/console?webview=test")
      return (console["entries"] as? [[String: Any]] ?? []).count >= 3
    }
    let console = try await call("GET", "/console?webview=test")
    let messages = (console["entries"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
    XCTAssertTrue(messages.contains("hello {\"answer\":42}"), "\(messages)")
    XCTAssertTrue(messages.contains { $0.hasPrefix("Error: boom") }, "\(messages)")
    XCTAssertTrue(messages.contains("from iframe"), "\(messages)")

    let errorsOnly = try await call("GET", "/console?webview=test&level=error")
    XCTAssertEqual((errorsOnly["entries"] as? [[String: Any]])?.count, 1)

    let frames = try await call("GET", "/frames?webview=test")
    let frameList = frames["frames"] as? [[String: Any]] ?? []
    XCTAssertEqual(frameList.count, 2, "\(frameList)")
    let child = try XCTUnwrap(frameList.first { $0["isMainFrame"] as? Bool == false }?["frameId"] as? String)
    let inFrame = try await call("POST", "/eval", body: ["webview": "test", "frame": child, "code": "window === window.top"])
    XCTAssertEqual(inFrame["value"] as? Bool, false)

    let navigation = try await call("GET", "/navigation?webview=test")
    let events = (navigation["entries"] as? [[String: Any]] ?? []).compactMap { $0["event"] as? String }
    XCTAssertTrue(events.contains("pushState"), "\(events)")
  }

  func testRegistersUnregisteredWebViewsOnLoad() async throws {
    // Created and loaded like a hybrid framework would, without ever calling register.
    let frameworkWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
    frameworkWebView.loadHTMLString("<title>Framework</title><script>console.log('from framework')</script>", baseURL: nil)
    try await waitUntil { !frameworkWebView.isLoading && frameworkWebView.title == "Framework" }

    let list = try await call("GET", "/webviews")
    let views = list["webViews"] as? [[String: Any]] ?? []
    let registered = try XCTUnwrap(views.first { $0["title"] as? String == "Framework" }, "\(views)")
    XCTAssertEqual(registered["className"] as? String, "WKWebView")
    let id = try XCTUnwrap(registered["id"] as? String)

    let console = try await call("GET", "/console?webview=\(id)")
    let messages = (console["entries"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
    XCTAssertEqual(messages, ["from framework"])
    WebViewMCP.unregister(frameworkWebView)
  }

  func testRejectsBrowserOrigins() async throws {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port!)/info")!)
    request.setValue("https://evil.example", forHTTPHeaderField: "Origin")
    let (_, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
  }

  func testSnapshotReturnsPNG() async throws {
    webView.loadHTMLString("<body style='background:red'>x</body>", baseURL: nil)
    try await waitUntil { !self.webView.isLoading }
    let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(Self.port!)/snapshot?webview=test")!)
    XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "image/png")
    XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
  }

  // MARK: Helpers

  private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port!)\(path)")!)
    request.httpMethod = method
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, _) = try await URLSession.shared.data(for: request)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if try await condition() {
        return
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for condition")
  }
}
