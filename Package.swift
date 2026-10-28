// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "InStrumMeants",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "InStrumMeants", targets: ["InStrumMeants"])
    ],
    targets: [
        // Optimised even in debug, so tests measure the real cost of the simulations (cloth, frost growth).
        .target(name: "InStrumCore", swiftSettings: [.unsafeFlags(["-O"])]),
        // Real-time DSP (C++17 behind a C header). Optimised even in debug so tests measure real cost.
        .target(name: "InStrumDSP", cxxSettings: [.unsafeFlags(["-O2", "-fno-math-errno"])]),
        .target(name: "InStrumAudio", dependencies: ["InStrumCore", "InStrumDSP"]),
        .target(name: "InStrumApp", dependencies: ["InStrumCore", "InStrumAudio"]),
        .executableTarget(name: "InStrumMeants", dependencies: ["InStrumApp"]),
        .testTarget(name: "InStrumCoreTests", dependencies: ["InStrumCore"]),
        .testTarget(name: "InStrumAudioTests", dependencies: ["InStrumAudio", "InStrumCore", "InStrumDSP"]),
        .testTarget(name: "InStrumAppTests", dependencies: ["InStrumApp", "InStrumAudio", "InStrumCore", "InStrumDSP"]),
    ],
    cxxLanguageStandard: .cxx17
)
