// swift-tools-version:6.0
import PackageDescription
// Замер whisper.cpp (Metal) с initial_prompt — см. bench/README.md.
let package = Package(
    name: "wcbench",
    platforms: [.macOS(.v15)],
    targets: [
        .binaryTarget(name: "whisper",
                      url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
                      checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"),
        .executableTarget(name: "pkbench", dependencies: ["whisper"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "wcbench", dependencies: ["whisper"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
