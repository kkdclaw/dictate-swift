import DictateCore
import FluidAudio
import Foundation

/// Parakeet-семейство через FluidAudio (CoreML, нейроядро): Parakeet Ultra (Moondream) и fluid-speech-pro (FluidVoice).
/// Замер на 224 диктовках (14.11): 0,05–0,06 с на запись — в 8–9 раз быстрее whisper turbo; по русским словам близко
/// к GigaAM, но словаря-подсказки нет и английские термины пишет кириллицей (латиница 0–20 из 59 против 45 у turbo).
final class ParakeetEngine: @unchecked Sendable {
    static let ultra = "moondream/parakeet-ultra"
    static let pro = "FluidVoice-Labs/fluid-speech-pro-coreml"
    private let asr = AsrManager()

    private init() {}

    /// Загрузить: Ultra — FluidAudio качает сам в свой кэш; fluid-speech-pro — из кэша HF (контракт v3, у Joint
    /// другое имя файла — собираем папку ссылками под ожидаемые FluidAudio имена).
    static func load(repo: String) async throws -> ParakeetEngine {
        let e = ParakeetEngine()
        let models: AsrModels
        if repo == ultra {
            models = try await AsrModels.downloadAndLoad(version: .ultra)
        } else {
            guard let src = MLXConverter.cachedSnapshot(repo: repo) else {
                throw NSError(domain: "Parakeet", code: 1, userInfo: [NSLocalizedDescriptionKey: "модели \(repo) нет в кэше — «Скачать» в окне «Модели»"])
            }
            let dir = Setup.models.appendingPathComponent("fluid-speech-pro", isDirectory: true)
            let fm = FileManager.default
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in ["Decoder.mlmodelc", "Encoder.mlmodelc", "Preprocessor.mlmodelc", "parakeet_v3_vocab.json", "parakeet_vocab.json", "config.json"] {
                try fm.createSymbolicLink(at: dir.appendingPathComponent(f), withDestinationURL: src.appendingPathComponent(f))
            }
            try fm.createSymbolicLink(at: dir.appendingPathComponent("JointDecisionv3.mlmodelc"), withDestinationURL: src.appendingPathComponent("JointDecision.mlmodelc"))
            models = try AsrModels.loadLocal(from: dir, version: .ultra)
        }
        try await e.asr.loadModels(models)
        var warm = try TdtDecoderState()
        _ = try await e.asr.transcribe([Float](repeating: 0, count: 16000), decoderState: &warm)
        return e
    }

    func transcribe(_ audio: [Float], language: String) async throws -> (String, Double) {
        var st = try TdtDecoderState()
        let t = Date()
        let r = try await asr.transcribe(audio, decoderState: &st, language: language == "en" ? .english : .russian)
        return (r.text.trimmingCharacters(in: .whitespacesAndNewlines), Date().timeIntervalSince(t) * 1000)
    }
}
