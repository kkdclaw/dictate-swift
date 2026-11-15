import AppKit
import CoreAudio
import DictateCore

/// Звуки-подтверждения — как hud.py Python-версии. Если вывод по умолчанию — Bluetooth (AirPods), звук в них
/// НЕЛЬЗЯ: наушники перещёлкивают профиль A2DP↔HFP, и микрофон на 1–2 с отдаёт нули («диктовка ломается после
/// двух слов»). Тогда играем во встроенный динамик Mac; его нет — молчим.
final class Sounds {
    static let volume: [String: Float] = ["start": 0.55, "done": 0.45, "error": 0.30]
    private var cache: [String: NSSound] = [:]
    private var route: (ts: Date, uid: String?)? = nil

    static func systemSounds() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }

    init() {
        // смена вывода (подключили AirPods) — маршрут пересчитать сразу, а не через 5 с
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.route = nil
        }
    }

    private func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v = def, n = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &n, &v) == noErr ? v : def
    }

    /// UID устройства для звуков: nil — вывод по умолчанию, "" — не играть.
    func routeUID() -> (String?, String) {
        if let r = route, Date().timeIntervalSince(r.ts) < 5 { return (r.uid, "") }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let dout: AudioObjectID = prop(sys, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0)
        var uid: String? = nil, why = "вывод по умолчанию"
        let tt: UInt32 = prop(dout, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0)
        if tt == kAudioDeviceTransportTypeBluetooth || tt == kAudioDeviceTransportTypeBluetoothLE {
            uid = ""; why = "вывод — Bluetooth, встроенного динамика нет"
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size)
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids)
            for d in ids {
                let t2: UInt32 = prop(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0)
                guard t2 == kAudioDeviceTransportTypeBuiltIn else { continue }
                var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                    mElement: kAudioObjectPropertyElementMain)
                var ss: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(d, &sa, 0, nil, &ss) == noErr, ss > 0 else { continue }
                var ua = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
                var cf: Unmanaged<CFString>?
                var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                if AudioObjectGetPropertyData(d, &ua, 0, nil, &n, &cf) == noErr, let s = cf?.takeRetainedValue() {
                    uid = s as String; why = "вывод — Bluetooth, звуки во встроенный динамик"
                }
                break
            }
        }
        route = (Date(), uid)
        return (uid, why)
    }

    func play(_ kind: String, name: String) {
        guard !name.isEmpty, name != "none" else { return }
        let (uid, _) = routeUID()
        if uid == "" { return }
        let snd = cache[name] ?? NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        guard let snd else { return }
        cache[name] = snd
        snd.volume = Sounds.volume[kind] ?? 0.5
        snd.playbackDeviceIdentifier = uid.map { NSSound.PlaybackDeviceIdentifier($0) }
        snd.stop(); snd.play()
    }
}
