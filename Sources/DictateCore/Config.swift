import Foundation

/// config.json — те же ключи, что у Python-версии. Неизвестные ключи сохраняются как есть.
public final class Config: @unchecked Sendable {
    public let url: URL
    private var dict: [String: Any] = [:]
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        reload()
    }

    public func reload() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = obj
        }
    }

    public func value(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return dict[key]
    }

    public func set(_ key: String, _ value: Any?) {
        lock.lock()
        dict[key] = value
        let snapshot = dict
        lock.unlock()
        Config.write(snapshot, to: url)
    }

    public func string(_ key: String, _ def: String) -> String { value(key) as? String ?? def }
    public func bool(_ key: String, _ def: Bool) -> Bool { value(key) as? Bool ?? def }

    public var hotkey: String { string("hotkey", "alt_r") }
    public var asrLanguage: String { string("asr_language", "ru") }
    public var asrModel: String { string("asr_model", "mlx-community/whisper-large-v3-turbo") }
    public var enabled: Bool { bool("enabled", true) }
    public var restoreClipboard: Bool { bool("restore_clipboard", true) }
    public var sounds: Bool { bool("sounds", true) }
    public var soundStart: String { string("sound_start", "Tink") }
    public var soundDone: String { string("sound_done", "Pop") }
    public var soundError: String { string("sound_error", "Basso") }
    public var defaultTerms: String { string("default_terms", "") }
    public var termsProfiles: [String: String] { value("terms_profiles") as? [String: String] ?? [:] }

    /// Ключи, которые берём из конфига Python-версии при первом запуске.
    public static let importKeys = ["hotkey", "asr_language", "asr_model", "default_terms", "terms_profiles",
                                    "restore_clipboard", "sounds", "sound_start", "sound_done", "sound_error",
                                    "commands", "default_style", "profiles", "enhance", "llm_model", "unload_llm",
                                    "llm_idle_min", "translate_all", "review", "review_styles",
                                    "hud", "hud_size", "hud_icon", "hud_color", "hud_bg", "hud_pos", "keep_audio", "audio_max_mb",
                                    "auto_update", "auto_update_every", "only_my_voice"]
    /// Дописать отсутствующие ключи из конфига Python-версии (новые ключи появляются по мере переноса функций).
    public func adoptMissing(from py: [String: Any]) -> [String] {
        lock.lock()
        var added: [String] = []
        for k in Config.importKeys where dict[k] == nil { if let v = py[k] { dict[k] = v; added.append(k) } }
        let snapshot = dict
        lock.unlock()
        if !added.isEmpty { Config.write(snapshot, to: url) }
        return added
    }

    public var defaultStyle: String { string("default_style", "clean") }
    public var profiles: [String: String] { value("profiles") as? [String: String] ?? [:] }
    public var enhance: Bool { bool("enhance", true) }
    public var llmModel: String { string("llm_model", "mlx-community/Qwen3-4B-Instruct-2507-4bit") }
    public var unloadLLM: Bool { bool("unload_llm", false) }
    public var llmIdleMin: Double { (value("llm_idle_min") as? Double) ?? Double(value("llm_idle_min") as? Int ?? 10) }
    /// Стиль для приложения: «перевод всего» → translate; профиль приложения; стиль по умолчанию.
    public func style(for app: String) -> String {
        if bool("translate_all", false) { return "translate" }
        return profiles[app] ?? defaultStyle
    }

    public static func write(_ dict: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
