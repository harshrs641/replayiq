// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReplayIQ",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ReplayIQ", targets: ["ReplayIQ"]),
    ],
    targets: [
        .target(name: "ReplayIQ", path: "Sources/ReplayIQ"),
        .testTarget(name: "ReplayIQTests", dependencies: ["ReplayIQ"], path: "Tests/ReplayIQTests"),
    ]
)
