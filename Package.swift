// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EluAnalytics",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(
            name: "EluAnalytics",
            targets: ["EluAnalytics"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/PostHog/posthog-ios.git", .upToNextMinor(from: "3.69.0")),
    ],
    targets: [
        .target(
            name: "EluAnalytics",
            dependencies: [
                .product(name: "PostHog", package: "posthog-ios"),
            ],
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ]
        ),
    ]
)
