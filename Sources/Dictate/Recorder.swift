import AVFoundation
import DictateCore
import ObjCCatch

/// Микрофон: поток открыт на время записи (mic_mode on_demand) или пока диктовка включена (always),
/// звук копится только между begin() и end(). Выход — 16 кГц моно float32.
final class Recorder {
    /// AVAudioEngine запоминает формат входа при первом обращении к inputNode: сменилось устройство, пока
    /// микрофон закрыт (AirPods 24 кГц ↔ встроенный 48 кГц), — installTap бросает исключение на каждом нажатии.
    /// Поэтому движок пересоздаётся при смене входа и после неудачного открытия; иначе — тот же (0,1 мс против ~100).
    private var engine = AVAudioEngine()
    private var engineDevice = AudioObjectID(0)
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
    /// Вход «ожил» — пришёл первый ненулевой отсчёт после открытия. У AirPods первые 0,2–1,3 с после открытия
    /// macOS поднимает канал гарнитуры и подаёт цифровые нули: сказанное в это время потеряно, поэтому сигнал
    /// «говорите» ждёт этого момента. Вызывается на главном потоке.
    var onLive: (() -> Void)?
    private var live = false
    /// Вход уже отдаёт звук (не нули с момента открытия).
    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return live }

    /// Имя текущего входа; входа нет — «нет микрофона» (у Mac mini и Mac Studio своего микрофона нет).
    var deviceName: String {
        guard Recorder.hasInput else { return "нет микрофона" }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "?"
    }

    /// В системе есть вход по умолчанию с входными потоками. Без входа macOS отдаёт id 0, а AVAudioEngine —
    /// фиктивный формат «2 канала, 44,1 кГц», и открытие падает невнятным «format mismatch».
    /// Это свойство CoreAudio: микрофон не открывает, индикатор macOS не зажигает — можно звать раз в 3 с.
    static var hasInput: Bool {
        let id = defaultInputID()
        guard id != kAudioObjectUnknown else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// Имя входа по умолчанию прямо из CoreAudio ("" — входа нет): два чтения свойства, можно звать на каждом
    /// нажатии. Ключ выученного усиления (mic_gain_auto).
    static var inputName: String {
        let id = defaultInputID()
        guard id != kAudioObjectUnknown else { return "" }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }

    static let noInput = NSError(domain: "Recorder", code: 2, userInfo: [NSLocalizedDescriptionKey:
        "нет микрофона — подключите USB-микрофон, гарнитуру или AirPods"])

    func start() throws {
        guard !running else { return }
        guard Recorder.hasInput else { throw Recorder.noInput }
        if Recorder.defaultInputID() != engineDevice { renewEngine() }
        do { try open() } catch {
            // формат входа устарел или устройство переключается (AirPods подключаются) — ещё раз с новым движком
            log("Микрофон: не открылся (\(error.localizedDescription)) — пересоздаю поток")
            stop()
            renewEngine()
            try open()
        }
    }

    private func renewEngine() {
        engine = AVAudioEngine()
        engineDevice = Recorder.defaultInputID()
    }

    /// Текущий вход по умолчанию (0 — не узнали).
    private static func defaultInputID() -> AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private func open() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "нет входного аудиоустройства"])
        }
        converter = AVAudioConverter(from: fmt, to: out)
        lock.lock(); live = false; lock.unlock()
        let engine = self.engine
        try ObjCCatch.run {
            input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.consume(buf) }
            engine.prepare()
        }
        try engine.start()
        running = true
        // смена входа во время работы потока (AirPods, док-станция): пересобрать поток
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            guard let self else { return }
            log("Микрофон: конфигурация сменилась — переоткрываю поток")
            self.stop()
            do { try self.start(); log("Микрофон: \(self.deviceName)") } catch {
                log("Микрофон: не переоткрылся — \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let engine = self.engine
        try? ObjCCatch.run {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        running = false
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        lock.lock(); let rec = recording, wasLive = live; lock.unlock()
        if !wasLive, let ch = buf.floatChannelData {
            var any = false
            for i in 0..<Int(buf.frameLength) where ch[0][i] != 0 { any = true; break }
            if any {
                lock.lock(); live = true; lock.unlock()
                if let onLive { DispatchQueue.main.async { onLive() } }
            }
        }
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
