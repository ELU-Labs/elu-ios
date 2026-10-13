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
    dependencies: [],
    targets: [
        .target(
            name: "EluAnalytics",
            dependencies: [],
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "EluAnalyticsTests",
            dependencies: ["EluAnalytics"]
        ),
    ]
)
