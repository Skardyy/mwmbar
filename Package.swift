// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "mwmbar",
  platforms: [.macOS(.v14)],
  targets: [
    // no .swiftLanguageMode: inherits swift 6 from tools-version, which is
    // required for the strict-concurrency checking this codebase depends on.
    .executableTarget(
      name: "mwmbar",
      path: "Sources/mwmbar"
    )
  ]
)
