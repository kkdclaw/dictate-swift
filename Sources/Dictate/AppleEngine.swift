import AVFoundation
import DictateCore
import Foundation
import Speech

/// Встроенный распознаватель macOS — DictationTranscriber (движок системной диктовки, SpeechAnalyzer) на устройстве.
/// Замер на 224 диктовках: 0,14 с на запись, но WER 17,6 % против 6,2 % у whisper.cpp, термины 3–5 из 12 —
/// выбирается вручную в «Моделях». Модель живёт в macOS (AssetInventory), процесс Dictate весов не держит.
/// SpeechTranscriber (новый) русского не знает; SFSpeechRecognizer ru — только через сервер, его не берём.
@available(macOS 26.0, *)
final class AppleEngine {
    static let repo = AppleASR.repo
    let locale: Locale

    init(language: String) { locale = Locale(identifier: language == "en" ? "en_US" : "ru_RU") }

    private func transcriber() -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                             reportingOptions: [], attributeOptions: [])
    }

    /// Поставить языковую модель, если её нет (качает macOS). Возвращает строку для журнала.
    func install() async throws -> String {
        guard await DictationTranscriber.supportedLocales.contains(where: { $0.identifier == locale.identifier }) else {
            throw NSError(domain: "Apple", code: 1, userInfo: [NSLocalizedDescriptionKey: "встроенный распознаватель не знает \(locale.identifier)"])
        }
        guard let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber()]) else {
            return "модель \(locale.identifier) уже в системе"
        }
        let t = Date()
        try await req.downloadAndInstall()
        return String(format: "модель %@ скачана за %.0f с", locale.identifier, Date().timeIntervalSince(t))
    }

    static func installed(_ language: String) async -> Bool {
        let id = language == "en" ? "en_US" : "ru_RU"
        return await DictationTranscriber.installedLocales.contains { $0.identifier == id }
    }

    /// Распознать 16 кГц моно; terms — словарь подсказкой (contextualStrings).
    func transcribe(_ audio: [Float], terms: [String]) async throws -> (String, Double) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-\(UUID().uuidString).wav")
        try WAV.write(audio, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tr = transcriber()
        let an = SpeechAnalyzer(modules: [tr])
        if !terms.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = terms
            try await an.setContext(ctx)
        }
        let file = try AVAudioFile(forReading: tmp)
        let t = Date()
        async let text: String = tr.results.reduce("") { $0 + String($1.text.characters) }
        try await an.start(inputAudioFile: file, finishAfterFile: true)
        let out = try await text
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), Date().timeIntervalSince(t) * 1000)
    }
}

/// Имя «модели» встроенного распознавателя в config.json (asr_model) — без привязки к версии macOS.
enum AppleASR {
    static let repo = "apple/dictation"
    static var available: Bool { if #available(macOS 26.0, *) { return true } else { return false } }
}
