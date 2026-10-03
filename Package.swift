// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "mwmbar",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0")
  ],
  targets: [
    // no .swiftLanguageMode: inherits swift 6 from tools-version, which is
    // required for the strict-concurrency checking this codebase depends on.
    .executableTarget(
      name: "mwmbar",
      dependencies: [
        .product(name: "Atomics", package: "swift-atomics")
      ],
      path: "Sources/mwmbar",
      linkerSettings: [
        // embed Info.plist directly in the Mach-O so TCC treats this
        // bundle less binary as an app for Accessibility and Screen
        // Recording prompts. without this the prompts never surface.
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Resources/Info.plist",
        ])
      ]
    )
  ]
)
