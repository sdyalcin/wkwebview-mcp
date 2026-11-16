import Foundation
import WebKit

/// Objective-C entry point, for Cordova and older React Native apps whose AppDelegate is
/// Objective-C:
///
/// ```objc
/// @import WebViewMCP;
///
/// #if DEBUG
/// [WebViewMCP start];
/// #endif
/// ```
@objc(WebViewMCP)
@MainActor
public final class WebViewMCPObjC: NSObject {
  /// Starts the server on port 9333 (or the next free one) and registers every web view.
  @objc public static func start() {
    WebViewMCP.start()
  }

  @objc(startOnPort:)
  public static func start(port: UInt16) {
    var configuration = WebViewMCP.Configuration()
    configuration.port = port
    WebViewMCP.start(configuration)
  }

  @objc(registerWebView:name:)
  public static func register(_ webView: WKWebView, name: String?) {
    WebViewMCP.register(webView, name: name)
  }

  @objc public static func stop() {
    WebViewMCP.stop()
  }
}
