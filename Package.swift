// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CaptureStream",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CaptureStreamCore", targets: ["CaptureStreamCore"]),
        .library(name: "CaptureStreamUI", targets: ["CaptureStreamUI"]),
        .executable(name: "CaptureStreamApp", targets: ["CaptureStreamApp"]),
    ],
    targets: [
        .target(
            name: "CaptureStreamCore",
            path: "Sources/CaptureStreamCore"
        ),
        .target(
            name: "CaptureStreamUI",
            dependencies: ["CaptureStreamCore"],
            path: "Sources/CaptureStreamUI",
            exclude: ["Shaders.metal"]   // 由 CI 用 xcrun metal 编译为 default.metallib
        ),
        .executableTarget(
            name: "CaptureStreamApp",
            dependencies: ["CaptureStreamCore", "CaptureStreamUI"],
            path: "Sources/CaptureStreamApp"
        ),
        .testTarget(
            name: "CaptureStreamTests",
            dependencies: ["CaptureStreamCore"],
            path: "Tests/CaptureStreamTests"
        ),
    ]
)
