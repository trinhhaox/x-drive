// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "XDrive",
    defaultLocalization: "vi",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OrbitCore", targets: ["OrbitCore"]),
        .executable(name: "XDrive", targets: ["XDriveApp"]),
        .executable(name: "OrbitMountHelper", targets: ["OrbitMountHelper"]),
        .executable(name: "OrbitFS", targets: ["OrbitFS"]),
        .executable(name: "OrbitFinder", targets: ["OrbitFinder"])
    ],
    targets: [
        .target(
            name: "OrbitCore",
            path: "Sources/OrbitCore"
        ),
        .executableTarget(
            name: "XDriveApp",
            dependencies: ["OrbitCore"],
            path: "Sources/XDriveApp"
        ),
        .executableTarget(
            name: "OrbitMountHelper",
            dependencies: ["OrbitCore"],
            path: "Sources/OrbitMountHelper"
        ),
        .executableTarget(
            name: "OrbitFS",
            dependencies: ["OrbitCore"],
            path: "Sources/OrbitFS"
        ),
        .executableTarget(
            name: "OrbitFinder",
            dependencies: ["OrbitCore"],
            path: "Sources/OrbitFinder"
        ),
        .testTarget(
            name: "OrbitCoreTests",
            dependencies: ["OrbitCore"],
            path: "Tests/OrbitCoreTests"
        )
    ]
)

