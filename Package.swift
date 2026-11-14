// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The sockets live in SocketsCore, which needs only Foundation and Darwin; SocketsPlugin is the Capacitor layer on top.
// Capacitor needs UIKit, so on a Mac `SOCKETS_CORE_ONLY=1 swift test` builds and tests the core alone. An app never sets it.
let coreOnly = ProcessInfo.processInfo.environment["SOCKETS_CORE_ONLY"] != nil

var targets: [Target] = [
    .target(
        name: "SocketsCore",
        path: "ios/Sources/SocketsCore"),
    .testTarget(
        name: "SocketsCoreTests",
        dependencies: ["SocketsCore"],
        path: "ios/Tests/SocketsCoreTests")
]
var products: [Product] = [
    .library(name: "SocketsCore", targets: ["SocketsCore"])
]
var dependencies: [Package.Dependency] = []

if !coreOnly {
    dependencies.append(.package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"))
    products = [
        .library(
            name: "CapacitorPluginSockets",
            targets: ["SocketsPlugin"])
    ]
    targets += [
        .target(
            name: "SocketsPlugin",
            dependencies: [
                "SocketsCore",
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/SocketsPlugin"),
        .testTarget(
            name: "SocketsPluginTests",
            dependencies: ["SocketsPlugin"],
            path: "ios/Tests/SocketsPluginTests")
    ]
}

let package = Package(
    name: "CapacitorPluginSockets",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
