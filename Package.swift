// swift-tools-version: 5.10
import Foundation
import PackageDescription

// scripts/build-runtime.sh builds the pinned NeMo-Speech.cpp libraries here.
let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".runtime/lib").path

let package = Package(
    name: "Imla",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CNemoSpeech"),
        .target(name: "CLlama"),
        .target(
            name: "ImlaCore",
            dependencies: ["CNemoSpeech", "CLlama"],
            linkerSettings: [
                // The app bundle carries the libraries in Contents/Frameworks; tests load them from .runtime.
                .unsafeFlags(["-L", runtime, "-lnemo_speech_asr_c", "-lllama",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", runtime]),
            ]
        ),
        .executableTarget(name: "Imla", dependencies: ["ImlaCore"]),
        .testTarget(name: "ImlaCoreTests", dependencies: ["ImlaCore"]),
    ]
)
