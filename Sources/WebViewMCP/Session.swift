import Foundation
import WebKit

/// A bounded log of JSON-ready entries. Each entry gets a `seq` that only grows, so clients can
/// ask for "everything after seq N" without missing or repeating entries.
struct EntryLog {
  private(set) var entries: [[String: Any]] = []
  private(set) var nextSeq = 1
  private(set) var dropped = 0
  let limit: Int

  init(limit: Int) {
    self.limit = limit
  }

  @discardableResult
  mutating func append(_ entry: [String: Any]) -> Int {
    var entry = entry
    let seq = nextSeq
    nextSeq += 1
    entry["seq"] = seq
    entries.append(entry)
    if entries.count > limit {
      let overflow = entries.count - limit
      entries.removeFirst(overflow)
      dropped += overflow
    }
    return seq
  }

  mutating func clear() {
    entries.removeAll()
  }
}

/// Network entries arrive in phases (start, end, body) and are merged by request id.
struct NetworkLog {
  private var order: [String] = []
  private var entries: [String: [String: Any]] = [:]
  private(set) var nextSeq = 1
  private(set) var dropped = 0
  let limit: Int

  init(limit: Int) {
    self.limit = limit
  }

  var all: [[String: Any]] {
    order.compactMap { entries[$0] }
  }

  func entry(id: String) -> [String: Any]? {
    entries[id]
  }

  mutating func merge(_ message: [String: Any]) {
    guard let id = message["id"] as? String else {
      return
    }
    var update = message
    let phase = update.removeValue(forKey: "phase") as? String
    update.removeValue(forKey: "type")
    let time = update.removeValue(forKey: "time")

    var entry = entries[id] ?? [:]
    if entries[id] == nil {
      entry["seq"] = nextSeq
      nextSeq += 1
      entry["startedAt"] = time
      order.append(id)
    }
    entry.merge(update) { _, new in new }

    switch phase {
    case "start":
      entry["state"] = "pending"
    case "end", "resource":
      entry["state"] = entry["error"] == nil ? "finished" : "failed"
      entry["finishedAt"] = time
    default:
      break
    }
    entries[id] = entry

    if order.count > limit {
      let overflow = order.count - limit
      order.prefix(overflow).forEach { entries.removeValue(forKey: $0) }
      order.removeFirst(overflow)
      dropped += overflow
    }
  }

  mutating func clear() {
    order.removeAll()
    entries.removeAll()
  }
}

struct FrameRecord {
  let id: String
  let info: WKFrameInfo
  let isMainFrame: Bool
  var url: String
  let seenAt: Date
}

/// Everything recorded for one registered web view.
@MainActor
final class Session {
  let id: String
  var name: String?
  weak var webView: WKWebView?
  let registeredAt = Date()
  var lastBridgeMessage: Date?

  var console: EntryLog
  var network: NetworkLog
  var navigation: EntryLog
  var frames: [String: FrameRecord] = [:]

  private var observations: [NSKeyValueObservation] = []
  private var committedURL: String?
  private var attemptedURL: String?

  init(id: String, name: String?, webView: WKWebView, configuration: WebViewMCP.Configuration) {
    self.id = id
    self.name = name
    self.webView = webView
    committedURL = webView.isLoading ? nil : webView.url?.absoluteString
    console = EntryLog(limit: configuration.consoleLimit)
    network = NetworkLog(limit: configuration.networkLimit)
    navigation = EntryLog(limit: configuration.navigationLimit)
    observe(webView)
  }

  var isAlive: Bool {
    webView != nil
  }

  var isVisible: Bool {
    guard let webView, webView.window != nil, !webView.isHidden else {
      return false
    }
    return true
  }

  var mainFrame: FrameRecord? {
    frames.values.first { $0.isMainFrame }
  }

  // MARK: Bridge messages

  func receive(_ body: [String: Any], frame: WKFrameInfo) {
    lastBridgeMessage = Date()
    guard let type = body["type"] as? String else {
      return
    }

    switch type {
    case "hello":
      guard let frameId = body["frameId"] as? String else {
        return
      }
      let isMainFrame = (body["isMainFrame"] as? Bool) ?? frame.isMainFrame
      if isMainFrame {
        // A new main document: every frame of the previous one is gone.
        frames.removeAll()
        navigation.append([
          "source": "page",
          "event": "document",
          "url": body["url"] ?? NSNull(),
          "referrer": body["referrer"] ?? NSNull(),
          "time": body["time"] ?? NSNull(),
        ])
      }
      frames[frameId] = FrameRecord(
        id: frameId,
        info: frame,
        isMainFrame: isMainFrame,
        url: (body["url"] as? String) ?? frame.request.url?.absoluteString ?? "",
        seenAt: Date()
      )

    case "console":
      var entry = body
      entry.removeValue(forKey: "type")
      if !frame.isMainFrame {
        entry["frameURL"] = frame.request.url?.absoluteString
      }
      console.append(entry)

    case "network":
      network.merge(body)

    case "navigation":
      var entry = body
      entry.removeValue(forKey: "type")
      entry["source"] = "page"
      if let frameId = body["frameId"] as? String, let url = body["url"] as? String {
        frames[frameId]?.url = url
      }
      navigation.append(entry)

    default:
      break
    }
  }

  // MARK: Native observation

  private func observe(_ webView: WKWebView) {
    observations = [
      webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
        let url = webView.url?.absoluteString
        Task { @MainActor in
          self?.recordNative(event: "url", url: url)
        }
      },
      webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
        let isLoading = webView.isLoading
        let url = webView.url?.absoluteString
        Task { @MainActor in
          self?.recordNative(event: isLoading ? "loadStarted" : "loadFinished", url: url)
        }
      },
    ]
  }

  private func recordNative(event: String, url: String?) {
    navigation.append([
      "source": "native",
      "event": event,
      "url": url ?? NSNull(),
      "time": Date().timeIntervalSince1970 * 1000,
    ])

    // The navigation delegate belongs to the app, so failures are inferred: a load that ends
    // with the URL back where it was before the load started never committed.
    switch event {
    case "loadStarted":
      attemptedURL = url
    case "loadFinished":
      if let attemptedURL, attemptedURL != committedURL, url == committedURL {
        navigation.append([
          "source": "native",
          "event": "loadFailed",
          "url": attemptedURL,
          "detail": "The load never committed (DNS, connection, TLS, a cancelled navigation or a policy decision). The app's navigation delegate has the error.",
          "time": Date().timeIntervalSince1970 * 1000,
        ])
      }
      committedURL = url
      attemptedURL = nil
    default:
      break
    }
  }

  // MARK: Description

  func summary() -> [String: Any] {
    var summary: [String: Any] = [
      "id": id,
      "name": name ?? NSNull(),
      "alive": isAlive,
      "visible": isVisible,
      "registeredAt": registeredAt,
      "bridgeActive": lastBridgeMessage != nil,
      "frames": frames.count,
      "consoleEntries": console.entries.count,
      "networkEntries": network.all.count,
    ]
    if let webView {
      summary["className"] = String(describing: type(of: webView))
      summary["url"] = webView.url?.absoluteString ?? NSNull()
      summary["title"] = webView.title ?? NSNull()
      summary["isLoading"] = webView.isLoading
      summary["estimatedProgress"] = webView.estimatedProgress
      summary["canGoBack"] = webView.canGoBack
      summary["canGoForward"] = webView.canGoForward
      summary["frame"] = [
        "width": Double(webView.bounds.width),
        "height": Double(webView.bounds.height),
      ]
    }
    return summary
  }
}
