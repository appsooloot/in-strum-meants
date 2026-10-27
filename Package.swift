// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "InStrumMeants",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "InStrumMeants", targets: ["InStrumMeants"])
    ],
    targets: [
        .target(name: "InStrumCore"),
        .target(name: "InStrumAudio", dependencies: ["InStrumCore"]),
        .target(name: "InStrumApp", dependencies: ["InStrumCore", "InStrumAudio"]),
        .executableTarget(name: "InStrumMeants", dependencies: ["InStrumApp"]),
        .testTarget(name: "InStrumCoreTests", dependencies: ["InStrumCore"]),
        .testTarget(name: "InStrumAudioTests", dependencies: ["InStrumAudio", "InStrumCore"]),
    ]
)
