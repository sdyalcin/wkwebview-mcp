# wkwebview-mcp

**Let your AI coding agent debug the WKWebViews inside your iOS app.**

An [MCP](https://modelcontextprotocol.io) server that gives Claude Code, Cursor, VS Code, Windsurf and any other MCP client
the console, network log, DOM and a JavaScript prompt of every web view in your app, in the simulator or on a
USB-connected device. It works for native apps and for hybrid apps built with **Capacitor, Cordova/Ionic,
React Native (react-native-webview) and Flutter (webview_flutter)**, because all of them render with WKWebView.

```text
You:    Tapping "Subscribe" in the app does nothing. Find out why.
Agent:  click {text: "Subscribe"}
        → Clicked <button#subscribe> "Subscribe" at 314,406
          Warning: <div#cookie-banner.banner-ghost> is on top of it at that point,
          so a real tap would hit that instead.
Agent:  The cookie banner fades to opacity 0 but stays in the layout and on top of the
        newsletter card. Removing it after the animation (or pointer-events: none) fixes it.
```

## Why

Debugging a web view inside an app has meant Safari's Web Inspector: excellent, but manual, so an agent can't use it.
Automation tools don't fill the gap. `safaridriver` and WebDriver only drive Safari itself, not the web views in your app. Proxies
built on the remote Web Inspector protocol (ios-webkit-debug-proxy, Appium's remote debugger) are tied to private
protocol details that change between iOS releases.

wkwebview-mcp takes a different route. A small Swift package in your **debug build** serves the app's web views
on `127.0.0.1:9333`, and this MCP server talks to it. No private APIs, no proxy, no jailbreak, nothing in release builds.

```text
┌──────────────┐  stdio  ┌───────────────┐  HTTP 127.0.0.1:9333  ┌──────────────────────────────┐
│ Claude Code, │ ──────▶ │ wkwebview-mcp │ ────────────────────▶ │ Your app (debug build)       │
│ Cursor, …    │  (MCP)  │ (Node, npx)   │                       │  WebViewMCP Swift package    │
└──────────────┘         └───────────────┘                       │   ├─ WKWebView #1  ◀─ bridge │
                                                                 │   └─ WKWebView #2  ◀─ bridge │
                                                                 └──────────────────────────────┘
```

## What your agent can do

| Tool | What it does |
| --- | --- |
| `list_apps` | Find running apps (and their web views) across simulators and forwarded devices |
| `get_page_content` | Read the page as text, as HTML, or as a list of interactive elements with refs |
| `click`, `fill`, `scroll`, `wait_for` | Drive the page. `click` reports the element that is really on top at that point (overlays, ghost banners) |
| `evaluate_javascript` | Run any JavaScript (async, `await` works) in the main frame or any iframe |
| `console_messages` | `console.*`, uncaught exceptions, unhandled rejections, failed resources and CSP violations, recorded from document start |
| `list_network_requests`, `get_network_request` | fetch and XHR with status, headers and bodies, plus documents, scripts, images and styles with timing |
| `navigation_history` | Page loads, redirects, failed loads, `pushState`, `popstate` and `hashchange`, for routing bugs and double loads |
| `navigate` | Load a URL, reload, back, forward |
| `screenshot` | The web view as WebKit renders it, or the whole simulator screen with the native UI around it |
| `list_frames`, `list_webviews`, `page_info`, `clear_logs` | Everything else you need to aim the above |

Logs are recorded all the time, not only while a client is connected. So you can reproduce a bug by hand and then
ask the agent what happened.

## Quick start

### 1. Add the Swift package

In Xcode: **File → Add Package Dependencies…**, enter `https://github.com/sdyalcin/wkwebview-mcp`, and add the
**WebViewMCP** library to your app target. With `Package.swift`:

```swift
.package(url: "https://github.com/sdyalcin/wkwebview-mcp", from: "0.1.0")
```

### 2. Start it in debug builds

```swift
import WebViewMCP

// In your App init or application(_:didFinishLaunchingWithOptions:)
#if DEBUG
WebViewMCP.start()
#endif
```

That's all. Every WKWebView in the app is picked up just before its first load. Optionally give one a name the
agent can refer to:

```swift
#if DEBUG
WebViewMCP.register(checkoutWebView, name: "checkout")
#endif
```

### 3. Add the MCP server to your client

**Claude Code**

```bash
claude mcp add wkwebview -- npx -y wkwebview-mcp
```

**Cursor, Windsurf, Claude Desktop** and other clients that use an `mcpServers` JSON file:

```json
{
  "mcpServers": {
    "wkwebview": {
      "command": "npx",
      "args": ["-y", "wkwebview-mcp"]
    }
  }
}
```

**VS Code** (`.vscode/mcp.json`):

```json
{
  "servers": {
    "wkwebview": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "wkwebview-mcp"]
    }
  }
}
```

### 4. Run the app and ask

Run a debug build in the simulator, then ask your agent things like *"what errors does the checkout page log?"*,
*"why does the login request fail?"* or *"click Pay and tell me what the payment iframe sends back"*.

Check what the server can see at any time:

```bash
npx -y wkwebview-mcp doctor
```

## Hybrid frameworks

`WebViewMCP.start()` registers web views automatically, so in each framework you only add the package to the
iOS project and call `start()` where the app launches. These setups follow each framework's standard iOS project.
They haven't all been tried in real apps yet, so if one needs more than shown here, please open an issue.

**Capacitor / Ionic.** Open `ios/App/App.xcworkspace` (or `App.xcodeproj`), add the package to the **App** target, and in
`AppDelegate.swift`:

```swift
import WebViewMCP

func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
  #if DEBUG
  WebViewMCP.start()
  #endif
  return true
}
```

**Cordova.** Add the package to the app target in `platforms/ios`, then in `AppDelegate.m`:

```objc
@import WebViewMCP;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
#if DEBUG
  [WebViewMCP start];
#endif
  self.viewController = [[MainViewController alloc] init];
  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}
```

**React Native (react-native-webview).** Add the package to the app target in `ios/`, then in `AppDelegate.swift`
(or `[WebViewMCP start];` in an Objective-C `AppDelegate.mm`):

```swift
import WebViewMCP

#if DEBUG
WebViewMCP.start()
#endif
```

**Flutter (webview_flutter, flutter_inappwebview).** Add the package to the **Runner** target in `ios/Runner.xcworkspace`, then
in `AppDelegate.swift`:

```swift
import WebViewMCP

override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
  #if DEBUG
  WebViewMCP.start()
  #endif
  GeneratedPluginRegistrant.register(with: self)
  return super.application(application, didFinishLaunchingWithOptions: launchOptions)
}
```

Framework hooks that run whenever the native project is regenerated (`cap sync`, `cordova prepare`, `expo prebuild`)
can drop manual Xcode changes. If yours does, add the package and the `start()` call from a config plugin or hook.

## Try it with the example app

`Example/` has a SwiftUI app with two web views. The **Playground** tab is a local page with deliberate bugs: a
failing API call, a button covered by an invisible banner, a promise nobody handles and a payment iframe. The **Browser**
tab is a plain browser whose web view is never registered by hand.

```bash
open Example/WebViewMCPExample.xcodeproj
```

Run it on a simulator, add the MCP server to your client, and ask *"Why does Load profile fail in the playground?"*.
The project is generated from `Example/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Physical devices

The server listens on the device's loopback interface. Forward the port over USB with `iproxy` from libimobiledevice:

```bash
brew install libimobiledevice
```

```bash
iproxy 9333 9333
```

This route hasn't been tested on hardware yet. Reports are welcome.

## Several apps or simulators at once

Each app takes the first free port from 9333 to 9342, and the MCP server scans that range. Tools act on the first app
found unless you pass `app` (a port, bundle id, app name or simulator name). They act on the web view that is on screen
unless you pass `webview` (`wv1`, `wv2`, … or a name you registered).

## Configuration

```swift
var configuration = WebViewMCP.Configuration()
configuration.port = 9333                 // first port to try
configuration.portAttempts = 10           // how many ports to try
configuration.registerAllWebViews = true  // false: only web views you register()
configuration.maxBodyCharacters = 65_536  // network bodies are truncated beyond this
configuration.makeInspectable = true      // also allow Safari's Web Inspector (iOS 16.4+)
WebViewMCP.start(configuration)
```

The MCP server reads `WKWEBVIEW_MCP_HOST`, `WKWEBVIEW_MCP_PORT` and `WKWEBVIEW_MCP_PORT_RANGE` if you change the defaults.

## HTTP API

The MCP server is a thin client. You can call the app directly from scripts or tests:

```bash
curl -s localhost:9333/webviews
```

```bash
curl -s localhost:9333/eval -d '{"code": "document.title"}'
```

```bash
curl -s "localhost:9333/console?level=error"
```

Routes: `GET /info`, `/webviews`, `/frames`, `/console`, `/network`, `/network/entry?id=`, `/navigation`,
`/snapshot` and `POST /eval`, `/navigate`, `/clear`. Every route takes an optional `webview`.

## How it works

- **Bridge script.** A `WKUserScript` injected at document start into every frame, in the page's own JavaScript
  world. It wraps `console`, `fetch`, `XMLHttpRequest` and `history`, listens for errors, rejections and CSP
  violations, and reads Resource Timing for everything else. Every wrapper calls the original and returns its
  result, so the page sees no difference.
- **JavaScript.** Runs through `callAsyncJavaScript` in the page world, in the main frame or the iframe you choose.
  Results are serialized in the page, so DOM nodes, cycles and BigInts come back readable.
- **Automatic registration.** The package exchanges the implementations of WKWebView's `load…` methods and
  `didMoveToWindow`, so it can register a web view before its first page starts. These are ordinary public
  methods, and each one calls straight through to WebKit.
- **Server.** A small HTTP/1.1 server on Network.framework, bound to `127.0.0.1`.

## Security

Anyone who can reach the port can run JavaScript in your web views, so:

- **Only start it in debug builds.** Wrap `WebViewMCP.start()` in `#if DEBUG`.
- It binds to the loopback interface. On a simulator that is your Mac's loopback; on a device it is reachable only
  through a USB port forward.
- Requests that carry an `Origin` header are refused. So are requests whose `Host` is not loopback. This stops a
  web page open on your Mac from driving the app, including through DNS rebinding.

## Limitations

- `click` and `fill` dispatch DOM events. They don't produce real touches, so native gesture recognizers and hit-testing are not
  involved. When a real tap matters, tap the simulator (Claude Code's iOS Simulator tools, `xcrun simctl`, XCUITest).
  `click` warns when another element would take the real tap.
- There are no breakpoints or stepping. `isInspectable` is set, so Safari's Web Inspector can attach next to it.
- The network log covers what the page does through `fetch` and XHR in detail. Documents, scripts, images and styles get URL and
  timing only. Requests made natively (URLSession) or by service workers are not seen.
- A failed page load (DNS, offline, TLS) shows up as `loadFailed` in `navigation_history`. The error code itself
  stays with the app's navigation delegate.
- iOS 15 or later.

## Development

```bash
swift test
```

```bash
npm test
```

`swift test` runs the package against a real WKWebView on macOS. `npm test` runs the MCP server against a stand-in app.

## License

MIT
