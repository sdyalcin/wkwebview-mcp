import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Maps HTTP requests onto the registry. Everything runs on the main actor, as WebKit requires.
@MainActor
final class Router {
  private unowned let registry: Registry

  init(registry: Registry) {
    self.registry = registry
  }

  func handle(_ request: HTTPRequest) async -> HTTPResponse {
    if let rejection = reject(request) {
      return rejection
    }

    switch (request.method, request.path) {
    case ("GET", "/"), ("GET", "/info"):
      return .json(appInfo())
    case ("GET", "/webviews"):
      return .json(["ok": true, "webViews": registry.sessions.map { $0.summary() }])
    case ("GET", "/frames"):
      return withSession(request) { .json(["ok": true, "frames": self.frames(of: $0)]) }
    case ("GET", "/console"):
      return withSession(request) { self.console($0, request) }
    case ("GET", "/network"):
      return withSession(request) { self.network($0, request) }
    case ("GET", "/network/entry"):
      return withSession(request) { self.networkEntry($0, request) }
    case ("GET", "/navigation"):
      return withSession(request) { self.navigation($0, request) }
    case ("POST", "/clear"):
      return withSession(request) { self.clear($0, request) }
    case ("POST", "/eval"):
      guard let session = session(for: request) else {
        return noWebView(request)
      }
      return await evaluate(session, request)
    case ("POST", "/navigate"):
      guard let session = session(for: request) else {
        return noWebView(request)
      }
      return await navigate(session, request)
    case ("GET", "/snapshot"):
      guard let session = session(for: request) else {
        return noWebView(request)
      }
      return await snapshot(session, scale: request.string("scale").flatMap(Double.init).map { CGFloat($0) })
    default:
      return .error(404, "No route for \(request.method) \(request.path)")
    }
  }

  // MARK: Guarding

  /// Browsers must not be able to drive this server. A page in Safari on the Mac can send
  /// requests to 127.0.0.1, so refuse anything carrying an `Origin` (which browsers attach to
  /// cross-origin requests) and, in loopback mode, any `Host` that is not loopback (which
  /// stops DNS rebinding).
  private func reject(_ request: HTTPRequest) -> HTTPResponse? {
    if request.headers["origin"] != nil {
      return .error(403, "Requests from web pages are not allowed")
    }
    if registry.configuration.loopbackOnly, let host = request.headers["host"] {
      let name = host.split(separator: ":").first.map(String.init) ?? host
      if !["127.0.0.1", "localhost", "[::1]"].contains(name.lowercased()) {
        return .error(403, "Unexpected Host header")
      }
    }
    return nil
  }

  private func session(for request: HTTPRequest) -> Session? {
    if let id = request.string("webview") {
      return registry.session(id: id)
    }
    return registry.defaultSession()
  }

  private func withSession(_ request: HTTPRequest, _ body: (Session) -> HTTPResponse) -> HTTPResponse {
    guard let session = session(for: request) else {
      return noWebView(request)
    }
    return body(session)
  }

  private func noWebView(_ request: HTTPRequest) -> HTTPResponse {
    if let id = request.string("webview") {
      return .error(404, "No registered web view with id or name \"\(id)\"")
    }
    return .error(409, "No web view is registered. Call WebViewMCP.register(webView) in the app.")
  }

  // MARK: Info

  private func appInfo() -> [String: Any] {
    let bundle = Bundle.main
    var device: [String: Any] = [:]
    #if canImport(UIKit)
    device["model"] = UIDevice.current.model
    device["systemName"] = UIDevice.current.systemName
    device["systemVersion"] = UIDevice.current.systemVersion
    #else
    device["systemName"] = "macOS"
    device["systemVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
    #endif
    #if targetEnvironment(simulator)
    device["simulator"] = true
    let environment = ProcessInfo.processInfo.environment
    device["name"] = environment["SIMULATOR_DEVICE_NAME"]
    device["udid"] = environment["SIMULATOR_UDID"]
    #else
    device["simulator"] = false
    #endif

    var app: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier)]
    app["bundleId"] = bundle.bundleIdentifier
    app["name"] = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
    app["version"] = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var info: [String: Any] = [
      "ok": true,
      "server": "wkwebview-mcp",
      "version": WebViewMCP.version,
      "app": app,
      "device": device,
      "webViews": registry.sessions.map { $0.summary() },
    ]
    info["port"] = WebViewMCP.port.map { Int($0) }
    return info
  }

  private func frames(of session: Session) -> [[String: Any]] {
    session.frames.values
      .sorted { lhs, rhs in lhs.isMainFrame != rhs.isMainFrame ? lhs.isMainFrame : lhs.seenAt < rhs.seenAt }
      .map { frame in
        [
          "frameId": frame.id,
          "isMainFrame": frame.isMainFrame,
          "url": frame.url,
          "origin": "\(frame.info.securityOrigin.protocol)://\(frame.info.securityOrigin.host)"
            + (frame.info.securityOrigin.port == 0 ? "" : ":\(frame.info.securityOrigin.port)"),
        ]
      }
  }

  // MARK: Logs

  private func console(_ session: Session, _ request: HTTPRequest) -> HTTPResponse {
    let levels = request.string("level").map { Set($0.lowercased().split(separator: ",").map(String.init)) }
    let since = request.int("since") ?? 0
    let search = request.string("search")?.lowercased()
    var entries = session.console.entries.filter { entry in
      guard (entry["seq"] as? Int ?? 0) > since else {
        return false
      }
      if let levels, let level = entry["level"] as? String, !levels.contains(level) {
        return false
      }
      if let search, !((entry["message"] as? String)?.lowercased().contains(search) ?? false) {
        return false
      }
      return true
    }
    let matched = entries.count
    if let limit = request.int("limit"), limit > 0, entries.count > limit {
      entries = Array(entries.suffix(limit))
    }
    let response = HTTPResponse.json([
      "ok": true,
      "webview": session.id,
      "entries": entries,
      "matched": matched,
      "lastSeq": session.console.nextSeq - 1,
      "dropped": session.console.dropped,
    ])
    if request.bool("clear") {
      session.console.clear()
    }
    return response
  }

  private func network(_ session: Session, _ request: HTTPRequest) -> HTTPResponse {
    let urlFilter = request.string("url")?.lowercased()
    let method = request.string("method")?.uppercased()
    let since = request.int("since") ?? 0
    let failedOnly = request.bool("failed")
    let statusMin = request.int("statusMin")
    let statusMax = request.int("statusMax")
    let kinds = request.string("kind").map { Set($0.lowercased().split(separator: ",").map(String.init)) }

    var entries = session.network.all.filter { entry in
      guard (entry["seq"] as? Int ?? 0) > since else {
        return false
      }
      if let urlFilter, !((entry["url"] as? String)?.lowercased().contains(urlFilter) ?? false) {
        return false
      }
      if let method, (entry["method"] as? String) != method {
        return false
      }
      if let kinds, !kinds.contains((entry["kind"] as? String ?? "").lowercased()) {
        return false
      }
      let status = entry["status"] as? Int
      if failedOnly, entry["error"] == nil, (status ?? 0) < 400 {
        return false
      }
      if let statusMin, (status ?? -1) < statusMin {
        return false
      }
      if let statusMax, (status ?? Int.max) > statusMax {
        return false
      }
      return true
    }
    let matched = entries.count
    if let limit = request.int("limit"), limit > 0, entries.count > limit {
      entries = Array(entries.suffix(limit))
    }

    // Keep the list light; full headers and bodies come from /network/entry.
    let summaries: [[String: Any]] = entries.map { entry in
      var summary = entry
      for key in ["requestHeaders", "responseHeaders", "requestBody", "responseBody"] {
        summary.removeValue(forKey: key)
      }
      return summary
    }
    let response = HTTPResponse.json([
      "ok": true,
      "webview": session.id,
      "requests": summaries,
      "matched": matched,
      "dropped": session.network.dropped,
    ])
    if request.bool("clear") {
      session.network.clear()
    }
    return response
  }

  private func networkEntry(_ session: Session, _ request: HTTPRequest) -> HTTPResponse {
    guard let id = request.string("id") else {
      return .error(400, "Missing id")
    }
    guard let entry = session.network.entry(id: id) else {
      return .error(404, "No network request with id \(id) (it may have been dropped or cleared)")
    }
    return .json(["ok": true, "request": entry])
  }

  private func navigation(_ session: Session, _ request: HTTPRequest) -> HTTPResponse {
    var entries = session.navigation.entries
    if let since = request.int("since") {
      entries = entries.filter { ($0["seq"] as? Int ?? 0) > since }
    }
    if let limit = request.int("limit"), limit > 0, entries.count > limit {
      entries = Array(entries.suffix(limit))
    }
    return .json(["ok": true, "webview": session.id, "entries": entries])
  }

  private func clear(_ session: Session, _ request: HTTPRequest) -> HTTPResponse {
    let what = request.string("what") ?? "all"
    if what == "all" || what == "console" {
      session.console.clear()
    }
    if what == "all" || what == "network" {
      session.network.clear()
    }
    if what == "all" || what == "navigation" {
      session.navigation.clear()
    }
    return .json(["ok": true, "cleared": what])
  }

  // MARK: JavaScript

  private func evaluate(_ session: Session, _ request: HTTPRequest) async -> HTTPResponse {
    guard let webView = session.webView else {
      return .error(409, "The web view has been deallocated")
    }
    guard let code = request.string("code") ?? request.string("expression") else {
      return .error(400, "Missing code")
    }

    var frame: WKFrameInfo?
    if let frameId = request.string("frame") {
      guard let record = session.frames[frameId] else {
        return .error(404, "No frame \(frameId). Frame ids change on every page load; get current ones from list_frames (GET /frames).")
      }
      frame = record.info
    }

    let timeout = Double(request.int("timeoutMs") ?? 10_000) / 1000
    let started = Date()
    do {
      let raw = try await withTimeout(seconds: timeout) {
        try await webView.callAsyncJavaScript(
          JavaScript.wrap(code),
          arguments: [:],
          in: frame,
          contentWorld: .page
        )
      }
      var result: [String: Any] = ["ok": true, "webview": session.id]
      if let json = raw as? String,
         let data = json.data(using: .utf8),
         let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
        result["type"] = decoded["type"] ?? "undefined"
        result["value"] = decoded["value"] ?? NSNull()
      } else {
        result["type"] = "undefined"
        result["value"] = NSNull()
      }
      result["durationMs"] = Int(Date().timeIntervalSince(started) * 1000)
      return .json(result)
    } catch is TimeoutError {
      return .json([
        "ok": false,
        "error": "Timed out after \(Int(timeout * 1000)) ms. The promise may still settle in the page.",
      ], status: 408)
    } catch {
      return .json(JavaScript.describe(error), status: 200)
    }
  }

  // MARK: Navigation

  private func navigate(_ session: Session, _ request: HTTPRequest) async -> HTTPResponse {
    guard let webView = session.webView else {
      return .error(409, "The web view has been deallocated")
    }

    let action = request.string("action") ?? (request.string("url") == nil ? "reload" : "load")
    switch action {
    case "load":
      guard let string = request.string("url"), let url = URL(string: string), url.scheme != nil else {
        return .error(400, "Missing or invalid url")
      }
      if url.isFileURL {
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
      } else {
        webView.load(URLRequest(url: url))
      }
    case "reload":
      webView.reload()
    case "back":
      guard webView.canGoBack else {
        return .error(409, "Nothing to go back to")
      }
      webView.goBack()
    case "forward":
      guard webView.canGoForward else {
        return .error(409, "Nothing to go forward to")
      }
      webView.goForward()
    case "stop":
      webView.stopLoading()
    default:
      return .error(400, "Unknown action \(action). Use load, reload, back, forward or stop.")
    }

    if request.bool("wait") {
      let deadline = Date().addingTimeInterval(Double(request.int("timeoutMs") ?? 15_000) / 1000)
      // Give WebKit a moment to flip isLoading on before waiting for it to go off.
      try? await Task.sleep(nanoseconds: 150_000_000)
      while webView.isLoading, Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    return .json(["ok": true, "action": action, "webView": session.summary()])
  }

  // MARK: Snapshot

  /// - Parameter scale: Pixels per point of the returned PNG (iOS only). Defaults to the
  ///   screen's scale; 1 keeps images small enough to hand to a model.
  private func snapshot(_ session: Session, scale: CGFloat?) async -> HTTPResponse {
    guard let webView = session.webView else {
      return .error(409, "The web view has been deallocated")
    }
    let configuration = WKSnapshotConfiguration()
    configuration.afterScreenUpdates = true

    do {
      let png: Data? = try await withCheckedThrowingContinuation { continuation in
        webView.takeSnapshot(with: configuration) { image, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          #if canImport(UIKit)
          guard let image else {
            continuation.resume(returning: nil)
            return
          }
          guard let scale, scale > 0, scale != image.scale else {
            continuation.resume(returning: image.pngData())
            return
          }
          let format = UIGraphicsImageRendererFormat()
          format.scale = scale
          let resized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
          }
          continuation.resume(returning: resized.pngData())
          #else
          let png = image?.tiffRepresentation
            .flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:])
          continuation.resume(returning: png)
          #endif
        }
      }
      guard let png else {
        return .error(500, "WebKit returned no image")
      }
      return HTTPResponse(status: 200, contentType: "image/png", body: png)
    } catch {
      return .error(500, "Snapshot failed: \(error.localizedDescription)")
    }
  }
}

struct TimeoutError: Error {}

/// Returns the operation's result, or throws `TimeoutError` if it takes longer than `seconds`.
/// WebKit cannot cancel a running script, so a timed-out operation keeps running unobserved.
@MainActor
func withTimeout(
  seconds: Double,
  _ operation: @escaping @MainActor () async throws -> Any?
) async throws -> Any? {
  final class State {
    var resumed = false
  }
  let state = State()

  return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
    Task { @MainActor in
      do {
        let value = try await operation()
        guard !state.resumed else { return }
        state.resumed = true
        continuation.resume(returning: value)
      } catch {
        guard !state.resumed else { return }
        state.resumed = true
        continuation.resume(throwing: error)
      }
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.1) * 1_000_000_000))
      guard !state.resumed else { return }
      state.resumed = true
      continuation.resume(throwing: TimeoutError())
    }
  }
}
