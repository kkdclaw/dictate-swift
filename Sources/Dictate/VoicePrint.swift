import AppKit
import DictateCore
import FluidAudio

/// Отпечаток голоса «пропускать только мой голос» — логика Python-версии (make_voiceprint, проверка, строгость),
/// но эмбеддинг другой: WeSpeaker v2 (CoreML, 256 чисел) из FluidAudio вместо speechbrain ECAPA — у Swift нет torch.
/// Старый voiceprint.npz (ECAPA) к нему не подходит: отпечаток записывается заново. Модель (~десятки МБ) качается
/// с Hugging Face при первой записи в models/speaker.
final class VoicePrint: @unchecked Sendable {
    struct Print: Codable { var vec: [Float]; var ts: Double; var device: String; var windows: Int
        var speechSec: Double; var selfMin: Double; var selfMean: Double; var threshold: Double; var model = "wespeaker_v2" }

    static let recordSec = 12.0, checkSec = 5.0, minSpeech = 4.0
    static let strictness: [(String, Double)] = [("Строго — чужих точно нет", 0.55), ("Обычно", 0.40), ("Мягко — лишь бы своё не терять", 0.28)]

    private var diarizer: DiarizerManager?
    private let lock = NSLock()
    private(set) var print: Print?
    var url: URL { Setup.data.appendingPathComponent("voiceprint.json") }

    init() {
        if let d = try? Data(contentsOf: url) { print = try? JSONDecoder().decode(Print.self, from: d) }
    }

    var summary: String {
        guard let p = print else { return "не записан" }
        let date = DateFormatter.localizedString(from: Date(timeIntervalSince1970: p.ts), dateStyle: .short, timeStyle: .none)
        return String(format: "записан %@ · %.0f с речи · микрофон «%@»", date, p.speechSec, p.device)
    }

    func ensureModel() async throws -> DiarizerManager {
        if let d = { lock.lock(); defer { lock.unlock() }; return diarizer }() { return d }
        let models = try await DiarizerModels.downloadIfNeeded(to: Setup.models.appendingPathComponent("speaker", isDirectory: true))
        let d = DiarizerManager()
        d.initialize(models: models)
        lock.lock(); diarizer = d; lock.unlock()
        log("Отпечаток: модель WeSpeaker готова")
        return d
    }

    var ready: Bool { lock.lock(); defer { lock.unlock() }; return diarizer != nil }

    func embed(_ audio: [Float]) throws -> [Float] {
        guard let d = { lock.lock(); defer { lock.unlock() }; return diarizer }() else { throw Err("модель отпечатка не загружена") }
        let e = try d.extractSpeakerEmbedding(from: audio)
        let n = sqrt(e.reduce(0) { $0 + $1 * $1 })
        guard n.isFinite, n > 1e-9 else { throw Err("пустой эмбеддинг (тишина?)") }
        return e.map { $0 / n }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double { Double(zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }) }

    /// Эмбеддинги окон по 3 с с шагом 1,5 с — устойчивее одного снимка (как embed_windows).
    func embedWindows(_ speech: [Float]) throws -> [[Float]] {
        let win = 3 * 16000, hop = 1500 * 16
        if speech.count <= win { return [try embed(speech)] }
        return try stride(from: 0, through: speech.count - win, by: hop).map { try embed(Array(speech[$0..<($0 + win)])) }
    }

    /// Отпечаток: средний эмбеддинг окон + разброс; порог — строже 0,40 никогда, шумная запись ослабляет до 0,28.
    func make(speech: [Float], device: String) throws -> Print {
        let secs = Double(speech.count) / 16000
        guard secs >= VoicePrint.minSpeech else {
            throw Err(String(format: "речи всего %.1f с из нужных %.0f с — говори подряд, без длинных пауз", secs, VoicePrint.minSpeech))
        }
        let embs = try embedWindows(speech)
        var mean = [Float](repeating: 0, count: embs[0].count)
        for e in embs { for i in mean.indices { mean[i] += e[i] } }
        let n = sqrt(mean.reduce(0) { $0 + $1 * $1 }); mean = mean.map { $0 / n }
        let sims = embs.map { VoicePrint.dot($0, mean) }
        let low = sims.min() ?? 0
        let thr = (min(0.40, max(0.28, low - 0.30)) * 100).rounded() / 100
        return Print(vec: mean, ts: Date().timeIntervalSince1970, device: device, windows: embs.count, speechSec: secs,
                     selfMin: low, selfMean: sims.reduce(0, +) / Double(sims.count), threshold: thr)
    }

    func save(_ p: Print) {
        print = p
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: url) }
    }

    struct Err: LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }
}

/// Окно записи/проверки отпечатка — как enrollwindow.py: что читать, уровень, сколько прошло, итог.
final class EnrollWindow: NSObject {
    static let readingText = """
        Широкая электрификация южных губерний даст мощный толчок подъёму сельского хозяйства.
        Съешь ещё этих мягких французских булок да выпей чаю.
        В чащах юга жил-был цитрусовый жёлтый фрукт, объём которого человек ценил чрезвычайно высоко.
        Если текст кончился, а запись идёт — читай сначала, спокойно и без пауз.
        """
    static let checkText = "Скажи любую фразу обычным голосом — например, эту."

    private var panel: NSPanel?
    private let text = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let level = NSLevelIndicator()
    private var primary: NSButton!
    private var secondary: NSButton!
    var onPrimary: () -> Void = {}
    var onSecondary: () -> Void = {}

    func show(enroll: Bool, mic: String, secs: Double) {
        build()
        panel?.title = enroll ? "Отпечаток голоса" : "Проверка голоса"
        text.stringValue = enroll ? EnrollWindow.readingText : EnrollWindow.checkText
        status.stringValue = String(format: "Микрофон: %@. Нажми «Начать» и читай вслух — запись %.0f с.", mic, secs)
        status.textColor = .secondaryLabelColor
        primary.title = "Начать"; primary.isEnabled = true; secondary.title = "Закрыть"
        level.doubleValue = 0
        panel?.center(); NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
    }

    func recording(left: Double, lvl: Float) {
        status.stringValue = String(format: "Идёт запись… осталось %.0f с. Читай без пауз.", max(0, left))
        status.textColor = .labelColor
        level.doubleValue = Double(min(1, lvl * 12)) * 10
        primary.title = "Остановить"; secondary.title = "Отмена"
    }

    func busy() { status.stringValue = "Считаю…"; primary.isEnabled = false; level.doubleValue = 0 }

    func finish(ok: Bool, _ msg: String, again: String) {
        status.stringValue = msg
        status.textColor = ok ? .systemGreen : .systemOrange
        primary.title = again; primary.isEnabled = true; secondary.title = "Закрыть"
    }

    func close() { panel?.orderOut(nil) }

    @objc private func p1() { onPrimary() }
    @objc private func p2() { onSecondary() }

    private func build() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false; p.level = .floating
        text.font = .systemFont(ofSize: 15); text.preferredMaxLayoutWidth = 480
        status.font = .systemFont(ofSize: 12); status.preferredMaxLayoutWidth = 480
        level.levelIndicatorStyle = .continuousCapacity; level.maxValue = 10; level.warningValue = 8; level.criticalValue = 9.5
        level.widthAnchor.constraint(equalToConstant: 480).isActive = true
        primary = NSButton(title: "Начать", target: self, action: #selector(p1)); primary.keyEquivalent = "\r"
        secondary = NSButton(title: "Закрыть", target: self, action: #selector(p2))
        let buttons = NSStackView(views: [secondary, primary]); buttons.spacing = 8
        let stack = NSStackView(views: [text, level, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        p.contentView = stack
        panel = p
    }
}
