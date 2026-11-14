// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorPluginSockets",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CapacitorPluginSockets",
            targets: ["SocketsPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "SocketsPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/SocketsPlugin"),
        .testTarget(
            name: "SocketsPluginTests",
            dependencies: ["SocketsPlugin"],
            path: "ios/Tests/SocketsPluginTests")
    ]
)