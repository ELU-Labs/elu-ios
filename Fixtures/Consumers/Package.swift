// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EluConsumerFixtures",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "UIKitConsumer", targets: ["UIKitConsumer"]),
        .library(name: "SwiftUIConsumer", targets: ["SwiftUIConsumer"]),
    ],
    dependencies: [
        .package(name: "EluSDK", path: "../.."),
    ],
    targets: [
        .target(name: "UIKitConsumer", dependencies: [.product(name: "EluAnalytics", package: "EluSDK")]),
        .target(name: "SwiftUIConsumer", dependencies: [.product(name: "EluAnalytics", package: "EluSDK")]),
    ]
)
