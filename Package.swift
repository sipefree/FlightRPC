// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FlightRPC",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(
            name: "FlightRPC",
            targets: ["FlightRPC"]),
        .executable(
            name: "flightrpc-gen",
            targets: ["flightrpc-gen"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "0.0.1"),
        .package(url: "https://github.com/JohnSundell/ShellOut.git", from: "2.3.0"),
        .package(url: "https://github.com/mxcl/Path.swift.git", from: "1.0.1"),
        .package(url: "https://github.com/vapor/console-kit.git", .branch("4.0.0-rc.1")),
    ],
    targets: [
        .target(
            name: "FlightRPC",
            dependencies: []),
        .target(
            name: "flightrpc-gen",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Path", package: "Path.swift"),
                .product(name: "ShellOut", package: "ShellOut"),
                .product(name: "ConsoleKit", package: "console-kit"),
            ]),
        .testTarget(
            name: "FlightRPCTests",
            dependencies: ["FlightRPC"]),
    ]
)
