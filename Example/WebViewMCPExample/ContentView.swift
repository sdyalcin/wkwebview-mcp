import SwiftUI

struct ContentView: View {
  var body: some View {
    TabView {
      PlaygroundTab()
        .tabItem { Label("Playground", systemImage: "ladybug") }
      BrowserTab()
        .tabItem { Label("Browser", systemImage: "globe") }
    }
  }
}

/// A local page with deliberate bugs to find with an agent.
struct PlaygroundTab: View {
  @StateObject private var model = WebViewModel(name: "playground")

  var body: some View {
    WebView(model: model)
      .ignoresSafeArea(edges: .bottom)
      .onAppear {
        if let url = Bundle.main.url(forResource: "playground", withExtension: "html") {
          model.loadFile(url)
        }
      }
  }
}

/// Any website, to try the tools on real pages. Its web view is never registered by hand:
/// `WebViewMCP.start()` picks it up on its first load, the way it does inside Capacitor,
/// Cordova, React Native or Flutter.
struct BrowserTab: View {
  @StateObject private var model = WebViewModel()
  @State private var address = "https://en.m.wikipedia.org/wiki/WebKit"

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
          .disabled(!model.canGoBack)
        TextField("Address", text: $address)
          .textFieldStyle(.roundedBorder)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.go)
          .onSubmit { model.load(address) }
        Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
      ProgressView(value: model.progress)
        .opacity(model.isLoading ? 1 : 0)
      WebView(model: model)
    }
    .onAppear {
      if model.webView.url == nil {
        model.load(address)
      }
    }
    .onReceive(model.$url) { url in
      if let url, url.scheme != "about" {
        address = url.absoluteString
      }
    }
  }
}
