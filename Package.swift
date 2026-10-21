// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoongdoongCodex",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DoongdoongAI", targets: ["DoongdoongAI"]),
               .library(name: "DoongdoongCodex", targets: ["DoongdoongCodex"])],
    targets: [.target(name: "DoongdoongAI"),
              .target(name: "DoongdoongCodex", dependencies: ["DoongdoongAI"]),
              .testTarget(name: "DoongdoongCodexTests", dependencies: ["DoongdoongCodex", "DoongdoongAI"])],
    swiftLanguageModes: [.v5]
)
