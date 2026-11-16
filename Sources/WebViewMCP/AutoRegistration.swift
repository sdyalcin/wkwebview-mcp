import Foundation
import ObjectiveC
import WebKit

/// Registers every WKWebView in the process just before its first load, so hybrid frameworks
/// (Capacitor, Cordova, React Native, Flutter) work without access to their web view instances.
///
/// It exchanges the implementations of WKWebView's load methods and `didMoveToWindow`. These
/// are ordinary methods (no init-family memory rules), and each replacement calls straight
/// through to WebKit's original.
enum AutoRegistration {
  private static var installed = false

  @MainActor
  static func install() {
    guard !installed else {
      return
    }
    installed = true

    exchange(#selector(WKWebView.load(_:)), with: #selector(WKWebView.wvmcp_load(_:)))
    exchange(#selector(WKWebView.loadHTMLString(_:baseURL:)), with: #selector(WKWebView.wvmcp_loadHTMLString(_:baseURL:)))
    exchange(#selector(WKWebView.loadFileURL(_:allowingReadAccessTo:)), with: #selector(WKWebView.wvmcp_loadFileURL(_:allowingReadAccessTo:)))
    exchange(#selector(WKWebView.load(_:mimeType:characterEncodingName:baseURL:)), with: #selector(WKWebView.wvmcp_load(_:mimeType:characterEncodingName:baseURL:)))
    #if canImport(UIKit)
    exchange(#selector(WKWebView.didMoveToWindow), with: #selector(WKWebView.wvmcp_didMoveToWindow))
    #else
    exchange(#selector(WKWebView.viewDidMoveToWindow), with: #selector(WKWebView.wvmcp_didMoveToWindow))
    #endif
  }

  private static func exchange(_ original: Selector, with replacement: Selector) {
    guard let originalMethod = class_getInstanceMethod(WKWebView.self, original),
          let replacementMethod = class_getInstanceMethod(WKWebView.self, replacement) else {
      NSLog("[wkwebview-mcp] could not hook %@", NSStringFromSelector(original))
      return
    }
    method_exchangeImplementations(originalMethod, replacementMethod)
  }
}

extension WKWebView {
  // After the exchange, calling a `wvmcp_` method runs WebKit's original implementation.
  //
  // Parameters are nullable Objective-C types on purpose: WebKit calls these selectors
  // internally with nil where the headers say non-null (loadHTMLString with a nil base URL
  // ends up in loadData with a nil base URL), and bridging nil to a Swift value type traps.

  @objc fileprivate func wvmcp_load(_ request: NSURLRequest?) -> WKNavigation? {
    Registry.shared.registerAutomatically(self)
    return wvmcp_load(request)
  }

  @objc fileprivate func wvmcp_loadHTMLString(_ string: NSString?, baseURL: NSURL?) -> WKNavigation? {
    Registry.shared.registerAutomatically(self)
    return wvmcp_loadHTMLString(string, baseURL: baseURL)
  }

  @objc fileprivate func wvmcp_loadFileURL(_ url: NSURL?, allowingReadAccessTo readAccessURL: NSURL?) -> WKNavigation? {
    Registry.shared.registerAutomatically(self)
    return wvmcp_loadFileURL(url, allowingReadAccessTo: readAccessURL)
  }

  @objc fileprivate func wvmcp_load(
    _ data: NSData?,
    mimeType: NSString?,
    characterEncodingName: NSString?,
    baseURL: NSURL?
  ) -> WKNavigation? {
    Registry.shared.registerAutomatically(self)
    return wvmcp_load(data, mimeType: mimeType, characterEncodingName: characterEncodingName, baseURL: baseURL)
  }

  @objc fileprivate func wvmcp_didMoveToWindow() {
    wvmcp_didMoveToWindow()
    if window != nil {
      Registry.shared.registerAutomatically(self)
    }
  }
}
