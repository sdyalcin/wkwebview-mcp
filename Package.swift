// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "WebViewMCP",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "WebViewMCP", targets: ["WebViewMCP"]),
  ],
  targets: [
    .target(
      name: "WebViewMCP",
      resources: [.copy("Resources/bridge.js")]
    ),
    .testTarget(
      name: "WebViewMCPTests",
      dependencies: ["WebViewMCP"]
    ),
  ]
)
