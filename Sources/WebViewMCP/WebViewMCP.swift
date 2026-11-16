import Foundation
import WebKit

/// Exposes the app's WKWebViews to the `wkwebview-mcp` MCP server over a local HTTP port.
///
/// Call it from debug builds only:
///
/// ```swift
/// #if DEBUG
/// WebViewMCP.start()
/// WebViewMCP.register(webView, name: "checkout")
/// #endif
/// ```
///
/// Anyone who can reach the port can run JavaScript in your web views, so it binds to the
/// loopback interface unless you opt out with `Configuration.loopbackOnly = false`.
public enum WebViewMCP {
  public static let version = "0.1.0"

  public struct Configuration {
    /// First port to try. If it is taken (another simulator running the app, say), the next
    /// `portAttempts - 1` ports are tried in order. The MCP server scans the same range.
    public var port: UInt16 = 9333
    public var portAttempts = 10
    /// Bind to 127.0.0.1 only. Simulators share the Mac's loopback, and physical devices are
    /// reached through a USB port forward (`iproxy 9333 9333`), so this rarely needs changing.
    public var loopbackOnly = true
    /// Request and response bodies longer than this are truncated in the network log.
    public var maxBodyCharacters = 65_536
    public var consoleLimit = 1_000
    public var networkLimit = 500
    public var navigationLimit = 300
    /// Also sets `isInspectable = true` (iOS 16.4+), so Safari's Web Inspector can attach too.
    public var makeInspectable = true
    /// Register every WKWebView in the app automatically, just before its first load (and
    /// when it enters a window). This is what makes Capacitor, Cordova, React Native and
    /// Flutter apps work without touching framework code. Set to `false` to register web views
    /// yourself with `WebViewMCP.register(_:name:)`.
    public var registerAllWebViews = true

    public init() {}
  }

  /// The port the server is listening on, once it has started.
  @MainActor public private(set) static var port: UInt16?

  /// Starts the HTTP server. Safe to call more than once; later calls are ignored.
  @MainActor
  public static func start(
    _ configuration: Configuration = Configuration(),
    onReady: ((Result<UInt16, Error>) -> Void)? = nil
  ) {
    Registry.shared.start(configuration, onReady: onReady)
  }

  /// Stops the HTTP server. Registered web views keep recording.
  @MainActor
  public static func stop() {
    Registry.shared.stop()
  }

  /// Starts recording a web view's console, network and navigation, and makes it scriptable.
  /// With `registerAllWebViews` (the default) this happens on its own; call it to give a web
  /// view a name that tools can use (`webview: "checkout"`), or when that option is off.
  ///
  /// Register before the first `load`, so the bridge script is in place at document start of
  /// the first page and in every iframe. Registering later still works for the main frame of
  /// the current page and for everything loaded afterwards.
  @MainActor
  public static func register(_ webView: WKWebView, name: String? = nil) {
    Registry.shared.register(webView, name: name)
  }

  @MainActor
  public static func unregister(_ webView: WKWebView) {
    Registry.shared.unregister(webView)
  }

  @MainActor
  static func setPort(_ value: UInt16?) {
    port = value
  }
}

/// Owns the server, the sessions and the script message handler.
@MainActor
final class Registry: NSObject, WKScriptMessageHandler {
  static let shared = Registry()
  static let messageHandlerName = "__wvdbg"

  private(set) var configuration = WebViewMCP.Configuration()
  private(set) var sessions: [Session] = []
  private var server: HTTPServer?
  private var nextSessionNumber = 1
  private let installedControllers = NSHashTable<WKUserContentController>.weakObjects()
  private let explicitlyUnregistered = NSHashTable<WKWebView>.weakObjects()
  private lazy var router = Router(registry: self)

  private override init() {
    super.init()
  }

  // MARK: Server

  func start(_ configuration: WebViewMCP.Configuration, onReady: ((Result<UInt16, Error>) -> Void)?) {
    guard server == nil else {
      if let port = WebViewMCP.port {
        onReady?(.success(port))
      }
      return
    }
    self.configuration = configuration

    if configuration.registerAllWebViews {
      AutoRegistration.install()
    }

    let router = router
    let server = HTTPServer { request in
      await router.handle(request)
    }
    self.server = server
    server.start(
      port: configuration.port,
      attempts: configuration.portAttempts,
      loopbackOnly: configuration.loopbackOnly
    ) { result in
      Task { @MainActor in
        switch result {
        case let .success(port):
          WebViewMCP.setPort(port)
          let host = configuration.loopbackOnly ? "127.0.0.1" : "0.0.0.0"
          NSLog("[wkwebview-mcp] listening on http://%@:%d", host, Int(port))
        case let .failure(error):
          self.server = nil
          NSLog("[wkwebview-mcp] could not start: %@", String(describing: error))
        }
        onReady?(result)
      }
    }
  }

  func stop() {
    server?.stop()
    server = nil
    WebViewMCP.setPort(nil)
  }

  // MARK: Sessions

  func register(_ webView: WKWebView, name: String?) {
    pruneDeadSessions()
    explicitlyUnregistered.remove(webView)
    if let existing = session(for: webView) {
      if let name {
        existing.name = name
      }
      return
    }

    let session = Session(id: "wv\(nextSessionNumber)", name: name, webView: webView, configuration: configuration)
    nextSessionNumber += 1
    sessions.append(session)

    if configuration.makeInspectable, #available(iOS 16.4, macOS 13.3, *) {
      webView.isInspectable = true
    }

    install(into: webView.configuration.userContentController)

    // Already showing a page: bring the bridge into it now rather than on the next load.
    if webView.url != nil {
      webView.evaluateJavaScript(Self.bridgeSource(configuration), completionHandler: nil)
    }
  }

  /// Called from the load hooks: registers web views nobody registered explicitly.
  func registerAutomatically(_ webView: WKWebView) {
    guard configuration.registerAllWebViews, server != nil, session(for: webView) == nil,
          !explicitlyUnregistered.contains(webView) else {
      return
    }
    register(webView, name: nil)
  }

  func unregister(_ webView: WKWebView) {
    explicitlyUnregistered.add(webView)
    sessions.removeAll { $0.webView == nil || $0.webView === webView }
  }

  func session(for webView: WKWebView) -> Session? {
    sessions.first { $0.webView === webView }
  }

  func session(id: String) -> Session? {
    sessions.first { $0.id == id || $0.name == id }
  }

  /// The web view a request means when it names none: the most recently registered one that
  /// is on screen, else the most recently registered one that still exists.
  func defaultSession() -> Session? {
    pruneDeadSessions()
    return sessions.last { $0.isVisible } ?? sessions.last { $0.isAlive }
  }

  private func pruneDeadSessions() {
    sessions.removeAll { !$0.isAlive }
  }

  // MARK: Bridge

  private func install(into controller: WKUserContentController) {
    guard !installedControllers.contains(controller) else {
      return
    }
    installedControllers.add(controller)
    controller.add(WeakMessageHandler(self), contentWorld: .page, name: Self.messageHandlerName)
    controller.addUserScript(WKUserScript(
      source: Self.bridgeSource(configuration),
      injectionTime: .atDocumentStart,
      forMainFrameOnly: false,
      in: .page
    ))
  }

  nonisolated static func bridgeSource(_ configuration: WebViewMCP.Configuration) -> String {
    guard let url = Bundle.module.url(forResource: "bridge", withExtension: "js"),
          let source = try? String(contentsOf: url, encoding: .utf8) else {
      assertionFailure("bridge.js is missing from the WebViewMCP bundle")
      return ""
    }
    return source
      .replacingOccurrences(of: "__WVDBG_MAX_BODY__", with: String(configuration.maxBodyCharacters))
      .replacingOccurrences(of: "__WVDBG_VERSION__", with: WebViewMCP.version)
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], let webView = message.webView else {
      return
    }
    // A web view sharing a registered one's content controller (a popup, say) reports in
    // before anyone registered it.
    if session(for: webView) == nil, !explicitlyUnregistered.contains(webView) {
      register(webView, name: nil)
    }
    session(for: webView)?.receive(body, frame: message.frameInfo)
  }
}

/// `WKUserContentController` retains its handlers; this keeps it from retaining the registry.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?

  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(userContentController, didReceive: message)
  }
}
