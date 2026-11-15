import AVFoundation
import DictateCore

/// Микрофон: поток открыт, пока диктовка включена (как в Python-версии — нажатие не ждёт открытия устройства),
/// звук копится только между begin() и end(). Выход — 16 кГц моно float32.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var recording = false
    private(set) var running = false
    private var observer: NSObjectProtocol?
    /// Уровень последнего буфера (для значка).
    private(set) var level: Float = 0
    /// RMS каждого буфера во время записи — для капсулы (вызывается на главном потоке).
    var onLevel: ((Float) -> Void)?

    var deviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "?"
    }

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "нет входного аудиоустройства"])
        }
        converter = AVAudioConverter(from: fmt, to: out)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.consume(buf) }
        engine.prepare()
        try engine.start()
        running = true
        // смена входа (AirPods, док-станция): пересобрать поток
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            guard let self else { return }
            log("Микрофон: конфигурация сменилась — переоткрываю поток")
            self.stop(); try? self.start()
            log("Микрофон: \(self.deviceName)")
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        lock.lock(); let rec = recording; lock.unlock()
        guard rec, let converter else { return }
        let ratio = out.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
        guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: dst, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, let ch = dst.floatChannelData else { return }
        let n = Int(dst.frameLength)
        let chunk = UnsafeBufferPointer(start: ch[0], count: n)
        var peak: Float = 0, sq: Float = 0
        for v in chunk { peak = max(peak, abs(v)); sq += v * v }
        lock.lock(); samples.append(contentsOf: chunk); level = peak; lock.unlock()
        let rms = n > 0 ? (sq / Float(n)).squareRoot() : 0
        if let onLevel { DispatchQueue.main.async { onLevel(rms) } }
    }

    func begin() {
        lock.lock(); samples.removeAll(keepingCapacity: true); recording = true; lock.unlock()
        converter?.reset()
    }

    func end() -> [Float] {
        lock.lock(); recording = false; let s = samples; samples.removeAll(); lock.unlock()
        return s
    }
}
