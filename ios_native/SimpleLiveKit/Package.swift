// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SimpleLiveKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SimpleLiveKit", targets: ["SimpleLiveKit"]),
        .executable(name: "douyu-probe", targets: ["DouyuProbe"]),
    ],
    targets: [
        .target(
            name: "SimpleLiveKit",
            resources: [.copy("Resources/crypto-js.js"), .copy("Resources/crypto-js.LICENSE")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DouyuProbe",
            dependencies: ["SimpleLiveKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SimpleLiveKitTests",
            dependencies: ["SimpleLiveKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
