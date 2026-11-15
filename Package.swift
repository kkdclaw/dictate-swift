// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dictate",
    platforms: [.macOS(.v15)],
    dependencies: [
        // LLM-чистка на MLX: модели берутся из кэша Python-версии как есть (Qwen3, GigaChat/deepseek_v3…)
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // отпечаток голоса: эмбеддинг WeSpeaker v2 (CoreML)
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.3"),
    ],
    targets: [
        // whisper.cpp (Metal) + parakeet.h — релиз ggml-org b5454 (= v1.9.5), выбор движка — Ф0
        .binaryTarget(name: "whisper",
                      url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
                      checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"),
        // Логика без интерфейса: конфиг, словарь, чистка, история, хоткей, конвертер моделей.
        .target(name: "DictateCore", path: "Sources/DictateCore"),
        // Приложение: меню-бар, хоткей, запись, распознавание, вставка.
        .executableTarget(name: "Dictate", dependencies: [
            "DictateCore", "whisper",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "FluidAudio", package: "FluidAudio"),
        ], path: "Sources/Dictate",
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "DictateCoreTests", dependencies: ["DictateCore"], path: "Tests/DictateCoreTests"),
    ]
)
