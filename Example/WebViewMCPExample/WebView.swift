import Combine
import SwiftUI
import WebKit
#if DEBUG
import WebViewMCP
#endif

@MainActor
final class WebViewModel: ObservableObject {
  let webView: WKWebView
  @Published var url: URL?
  @Published var isLoading = false
  @Published var progress = 0.0
  @Published var canGoBack = false

  private var observations: [NSKeyValueObservation] = []

  /// - Parameter name: A name tools can address this web view by (`webview: "playground"`).
  ///   Without one it is still registered automatically on its first load, as `wv1`, `wv2`…
  init(name: String? = nil) {
    webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    webView.allowsBackForwardNavigationGestures = true

    #if DEBUG
    if let name {
      WebViewMCP.register(webView, name: name)
    }
    #endif

    observations = [
      webView.observe(\.url) { [weak self] webView, _ in
        let url = webView.url
        Task { @MainActor in self?.url = url }
      },
      webView.observe(\.isLoading) { [weak self] webView, _ in
        let isLoading = webView.isLoading
        Task { @MainActor in self?.isLoading = isLoading }
      },
      webView.observe(\.estimatedProgress) { [weak self] webView, _ in
        let progress = webView.estimatedProgress
        Task { @MainActor in self?.progress = progress }
      },
      webView.observe(\.canGoBack) { [weak self] webView, _ in
        let canGoBack = webView.canGoBack
        Task { @MainActor in self?.canGoBack = canGoBack }
      },
    ]
  }

  func load(_ address: String) {
    var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.contains("://") {
      text = "https://" + text
    }
    guard let url = URL(string: text) else {
      return
    }
    webView.load(URLRequest(url: url))
  }

  func loadFile(_ url: URL) {
    guard webView.url == nil else {
      return
    }
    webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
  }
}

struct WebView: UIViewRepresentable {
  let model: WebViewModel

  func makeUIView(context: Context) -> WKWebView {
    model.webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {}
}
