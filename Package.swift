// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "parrot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Pinned past v1.0.0 for argmaxinc/argmax-oss-swift#514: before it, any
        // transcription with promptTokens came back empty, because a prediction
        // made while forcing the prompt was allowed to complete the segment.
        // Move to a version requirement once a release carries it.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git",
                 revision: "97d09fd9790393579d2834e2bc098deb3e26bc06"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "parrot",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
