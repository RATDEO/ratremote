// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RatRemote",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RatRemote", targets: ["RatRemote"])
    ],
    dependencies: [
        .package(url: "https://github.com/alta/swift-opus.git", exact: "0.0.2")
    ],
    targets: [
        .executableTarget(
            name: "RatRemote",
            dependencies: [
                .product(name: "Copus", package: "swift-opus")
            ],
            path: "Sources/RatRemote"
        ),
        .testTarget(
            name: "RatRemoteTests",
            dependencies: ["RatRemote"],
            path: "Tests/RatRemoteTests"
        )
    ]
)
