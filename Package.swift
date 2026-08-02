// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BonhommeNotch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BonhommeNotchCore", targets: ["BonhommeNotchCore"]),
        .executable(name: "BonhommeNotch", targets: ["BonhommeNotch"])
    ],
    targets: [
        .target(
            name: "BonhommeNotchCore",
            path: "Sources/BonhommeNotchCore"
        ),
        .executableTarget(
            name: "BonhommeNotch",
            dependencies: ["BonhommeNotchCore"],
            path: "Sources/BonhommeNotch"
        ),
        .testTarget(
            name: "BonhommeNotchCoreTests",
            dependencies: ["BonhommeNotchCore"],
            path: "Tests/BonhommeNotchCoreTests"
        )
    ]
)
