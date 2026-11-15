import DictateCore
import Foundation

/// Каталог данных, импорт из Python-версии, модель и сосуществование с Python-версией.
enum Setup {
    static let fm = FileManager.default
    static var data: URL { AppInfo.dataDirectory }
    static var models: URL { data.appendingPathComponent("models", isDirectory: true) }
    static let pythonDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("dictate", isDirectory: true)

    /// Первый запуск: каталог данных + словарь, слои, сниппеты и часть настроек из ~/dictate (Python-версия).
    static func prepareDataDir() {
        try? fm.createDirectory(at: models, withIntermediateDirectories: true)
        let cfg = data.appendingPathComponent("config.json")
        if fm.fileExists(atPath: cfg.path) {
            // ключи новых функций — из Python-версии, если их ещё нет
            if let d = try? Data(contentsOf: pythonDir.appendingPathComponent("config.json")),
               let py = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let added = Config(url: cfg).adoptMissing(from: py)
                if !added.isEmpty { log("Настройки: из Python-версии взято \(added.joined(separator: ", "))") }
            }
            return
        }
        var imported: [String] = []
        for name in ["terms.txt", "auto_terms.txt", "commands.json", "terms.d"] {
            let src = pythonDir.appendingPathComponent(name), dst = data.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path), (try? fm.copyItem(at: src, to: dst)) != nil {
                imported.append(name)
            }
        }
        var dict: [String: Any] = [:]
        if let d = try? Data(contentsOf: pythonDir.appendingPathComponent("config.json")),
           let py = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for k in Config.importKeys { if let v = py[k] { dict[k] = v } }
            imported.append("config.json (\(dict.count) ключей)")
        }
        dict["enabled"] = true
        Config.write(dict, to: cfg)
        log("Первый запуск: каталог \(data.path); из Python-версии взято: \(imported.isEmpty ? "ничего" : imported.joined(separator: ", "))")
    }

    // MARK: модель

    /// Файл ggml для модели из конфига (имя репо HF, как у Python-версии).
    static func ggmlPath(for repo: String) -> URL {
        models.appendingPathComponent((repo.split(separator: "/").last.map(String.init) ?? repo) + ".ggml.bin")
    }

    static var vadModel: URL {
        Bundle.main.resourceURL!.appendingPathComponent("vad/ggml-silero-v6.2.0.bin")
    }

    static var assets: URL {
        Bundle.main.resourceURL!.appendingPathComponent("whisper-assets", isDirectory: true)
    }

    /// Готовит модель: есть ggml — сразу; нет — перегоняет из кэша Python-версии (MLX). Долго — звать не на main.
    static func ensureModel(repo: String) throws -> URL {
        let out = ggmlPath(for: repo)
        if fm.fileExists(atPath: out.path) { return out }
        guard let src = MLXConverter.cachedModel(repo: repo) else {
            throw NSError(domain: "Setup", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "модели \(repo) нет в кэше ~/.cache/huggingface — скачайте её в Python-версии (окно «Модели»)"])
        }
        log("Модель: перегоняю \(repo) из кэша Python-версии (MLX → ggml)…")
        let t = Date()
        try MLXConverter.convert(modelDir: src, assets: assets, output: out)
        log(String(format: "Модель: готово за %.1f с — %@", Date().timeIntervalSince(t), out.lastPathComponent))
        return out
    }

    // MARK: Python-версия

    /// Python-версия активна: служба запущена и диктовка в ней не выключена галкой.
    static var pythonActive: Bool {
        guard let d = try? Data(contentsOf: pythonDir.appendingPathComponent("config.json")),
              let py = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        if (py["enabled"] as? Bool) == false { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/com.kkd.dictate"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.contains("state = running")
    }

    /// Включить/выключить диктовку в Python-версии её же способом: ключ enabled в config.json + перезапуск службы.
    static func setPythonEnabled(_ on: Bool) throws {
        let url = pythonDir.appendingPathComponent("config.json")
        var text = try String(contentsOf: url, encoding: .utf8)
        let re = try NSRegularExpression(pattern: #""enabled"\s*:\s*(true|false)"#)
        let range = NSRange(text.startIndex..., in: text)
        if re.firstMatch(in: text, range: range) != nil {
            text = re.stringByReplacingMatches(in: text, range: range, withTemplate: "\"enabled\": \(on)")
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            var dict = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
            dict["enabled"] = on
            Config.write(dict, to: url)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [pythonDir.appendingPathComponent("daemon.sh").path, "restart"]
        p.currentDirectoryURL = pythonDir
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        log("Python-версия: диктовка \(on ? "включена" : "выключена (🌙)"), служба перезапущена (rc \(p.terminationStatus))")
    }
}
