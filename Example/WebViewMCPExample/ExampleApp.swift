import SwiftUI
#if DEBUG
import WebViewMCP
#endif

@main
struct ExampleApp: App {
  init() {
    #if DEBUG
    // Serves the app's web views on 127.0.0.1:9333 for the wkwebview-mcp MCP server.
    WebViewMCP.start()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
