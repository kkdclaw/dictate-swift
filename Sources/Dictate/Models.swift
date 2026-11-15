import DictateCore
import FluidAudio
import Foundation

/// Каталог моделей и закачка из Hugging Face — как ROLES и окно «Модели» Python-версии.
/// Модели качаются в тот же кэш ~/.cache/huggingface/hub (раскладка snapshots/<rev>), что у Python-версии,
/// и перегоняются в ggml по кнопке «Выбрать».
enum Catalog {
    struct Model {
        let repo: String; let mb: Int; let title: String; let engine: Engine; var name: String = ""
        /// Одна строка «для чего» и цифры сравнения 14.11 (подпись → значение) — для карточки в окне «Модели».
        var role: String = ""; var metrics: [(String, String)] = []; var badge: String? = nil; var available = true
    }
    enum Engine { case whisper, parakeet, llm, apple }

    static var asr: [Model] { allASR.filter { $0.engine != .apple || AppleASR.available } }
    /// Каталог — по сравнению 14.11.2026 на 224 диктовках:
    /// время на запись (M5), расхождение с large-v3, сколько английских слов из 59 сохранено.
    static let allASR: [Model] = [
        Model(repo: "mlx-community/whisper-large-v3-turbo", mb: 1600,
              title: "Whisper turbo — по умолчанию: 0,46 с, расхождение 6,4 %, английских слов 45 из 59; словарь работает", engine: .whisper, name: "turbo", role: "Лучший баланс: быстро, точно, понимает словарь терминов", metrics: [("время", "0,46 с"), ("ошибки", "6,4 %"), ("англ. слова", "45 из 59"), ("словарь", "да"), ("вес", "1,6 ГБ")], badge: "по умолчанию"),
        Model(repo: "coriollon/whisper-large-v3-turbo-russian-codeswitch", mb: 3200,
              title: "Codeswitch-turbo — дообучен на русском с английскими терминами: 0,57 с, 6,7 %, 42 из 59; словарь работает", engine: .whisper, name: "codeswitch-turbo", role: "Turbo, дообученный на русском с английскими терминами", metrics: [("время", "0,57 с"), ("ошибки", "6,7 %"), ("англ. слова", "42 из 59"), ("словарь", "да"), ("вес", "1,6 ГБ")]),
        Model(repo: "bond005/whisper-podlodka-turbo", mb: 3200,
              title: "Podlodka-turbo — дообучен на русском IT-подкасте: 0,54 с, 7,0 %, 32 из 59; словарь работает", engine: .whisper, name: "podlodka-turbo", role: "Turbo, дообученный на русском IT-подкасте", metrics: [("время", "0,54 с"), ("ошибки", "7,0 %"), ("англ. слова", "32 из 59"), ("словарь", "да"), ("вес", "1,6 ГБ")]),
        Model(repo: "mlx-community/whisper-large-v3-mlx", mb: 3100,
              title: "Whisper large-v3 — точнее всех, но вдвое медленнее: 0,94 с, 55 из 59 (эталон)", engine: .whisper, name: "large-v3", role: "Самый точный, но вдвое медленнее — для Mac Studio", metrics: [("время", "0,94 с"), ("ошибки", "эталон"), ("англ. слова", "55 из 59"), ("словарь", "да"), ("вес", "3,1 ГБ")]),
        Model(repo: ParakeetEngine.ultra, mb: 630,
              title: "Parakeet Ultra — самая быстрая: 0,06 с, на нейроядре, памяти почти не держит; без словаря, английские термины кириллицей (0 из 59)", engine: .parakeet, name: "Parakeet Ultra", role: "Самый быстрый, на нейроядре; английские термины пишет по-русски", metrics: [("время", "0,06 с"), ("ошибки", "9,3 %"), ("англ. слова", "0 из 59"), ("словарь", "нет"), ("вес", "0,6 ГБ")], badge: "самый быстрый"),
        Model(repo: ParakeetEngine.pro, mb: 650,
              title: "Fluid Speech Pro — дообученная Ultra: 0,05 с, 8,8 %, 20 из 59; без словаря", engine: .parakeet, name: "Fluid Speech Pro", role: "Дообученный Parakeet Ultra: так же быстр, чуть лучше с английским", metrics: [("время", "0,05 с"), ("ошибки", "8,8 %"), ("англ. слова", "20 из 59"), ("словарь", "нет"), ("вес", "0,65 ГБ")]),
        Model(repo: AppleASR.repo, mb: 0,
              title: "Встроенный в macOS — 0,24 с, памяти не держит; но ошибок втрое больше (17,5 %), пунктуации нет", engine: .apple, name: "Apple (встроенный)", role: "Встроенный в macOS: памяти не держит, но ошибок втрое больше, без пунктуации", metrics: [("время", "0,24 с"), ("ошибки", "17,5 %"), ("англ. слова", "22 из 59"), ("словарь", "слабо"), ("вес", "в системе")]),
    ]

    /// Чистка — сравнение 14.11.2026 на 150 фразах: время, сколько «ё» поставила, сколько паразитов убрала (из 85).
    static let llm: [Model] = [
        Model(repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", mb: 2300,
              title: "Qwen3-4B — по умолчанию: 1,2 с, паразитов убрала 40 из 85, «ё» почти не ставит (6)", engine: .llm, name: "Qwen3-4B", role: "Убирает паразитов лучше всех; «ё» почти не ставит", metrics: [("время", "1,2 с"), ("«ё»", "6"), ("паразиты", "40 из 85"), ("вес", "2,3 ГБ")], badge: "по умолчанию"),
        Model(repo: "bogdanminko/RuadaptQwen3-4B-Instruct-MLX-4bit", mb: 2300,
              title: "RuadaptQwen3-4B — Qwen3-4B с русским токенизатором: 0,9 с, «ё» 28, но паразитов убрала только 11", engine: .llm, name: "RuadaptQwen3-4B", role: "Qwen3-4B с русским токенизатором: быстрее и больше «ё», паразитов убирает хуже", metrics: [("время", "0,9 с"), ("«ё»", "28"), ("паразиты", "11 из 85"), ("вес", "2,3 ГБ")]),
        Model(repo: "mlx-community/Qwen3-1.7B-4bit", mb: 1000, title: "Qwen3-1.7B — для слабых машин (не сравнивалась)", engine: .llm, name: "Qwen3-1.7B", role: "Для слабых машин; в сравнении не участвовала", metrics: [("время", "—"), ("«ё»", "—"), ("паразиты", "—"), ("вес", "1,0 ГБ")]),
        Model(repo: "RockTalk/GigaChat3.1-10B-A1.8B-MLX-4bit", mb: 6000,
              title: "GigaChat 3.1 — русскоцентричная; в Swift-версии пока не грузится (q_lora_rank = null)", engine: .llm, name: "GigaChat 3.1", role: "Русскоцентричная, для Mac Studio; в Swift-версии пока не загружается", metrics: [("время", "—"), ("«ё»", "—"), ("паразиты", "—"), ("вес", "6 ГБ")], available: false),
    ]

    /// Модель чистки: готова = лежит в кэше HF (MLX берёт её как есть, без перегонки).
    static func llmStatus(_ m: Model, active: String, loaded: Bool) -> (String, Bool) {
        if let d = Downloader.shared.progress[m.repo] { return ("⬇️ качается: \(d)", false) }
        let cached = MLXConverter.cachedModel(repo: m.repo) != nil
        if m.repo == active { return ("● активная · " + (loaded ? "в памяти" : "не в памяти"), cached) }
        return (cached ? "✓ скачана" : "○ не скачана (~\(m.mb) МБ)", cached)
    }

    nonisolated(unsafe) static var appleInstalled: Bool?  // обновляется фоном (AssetInventory — async)

    static func status(_ m: Model, active: String) -> (text: String, ready: Bool, cached: Bool) {
        if m.engine == .parakeet {
            if let d = Downloader.shared.progress[m.repo] { return ("⬇️ качается: \(d)", false, false) }
            let have = m.repo == ParakeetEngine.ultra
                ? FileManager.default.fileExists(atPath: AsrModels.defaultCacheDirectory(for: .ultra).path)
                : MLXConverter.cachedSnapshot(repo: m.repo) != nil
            let st = have ? "✓ скачана" : (m.repo == ParakeetEngine.ultra ? "○ скачается при выборе (~630 МБ)" : "○ не скачана (~650 МБ)")
            return ((m.repo == active ? "● активная · " : "") + st, have || m.repo == ParakeetEngine.ultra, have)
        }
        if m.engine == .apple {
            let inst = appleInstalled.map { $0 ? "модель в системе" : "модель скачает macOS (~35 с)" } ?? "проверяю…"
            return ((m.repo == active ? "● активная · " : "✓ встроен · ") + inst, true, true)
        }
        let ggml = Setup.ggmlPath(for: m.repo)
        let have = FileManager.default.fileExists(atPath: ggml.path)
        let cached = MLXConverter.cachedModel(repo: m.repo) != nil
        if let d = Downloader.shared.progress[m.repo] {
            return ("⬇️ качается: \(d)", false, cached)
        }
        if m.repo == active { return ("● активная" + (have ? " · \(mb(ggml))" : ""), true, cached) }
        if have { return ("✓ готова · \(mb(ggml))", true, cached) }
        if cached { return ("⬇️ скачана — «Выбрать» перегонит в ggml за секунды", false, true) }
        return ("○ не скачана (~\(m.mb) МБ)", false, false)
    }

    static func size(_ mb: Int) -> String { mb >= 1000 ? String(format: "%.1f ГБ", Double(mb) / 1000).replacingOccurrences(of: ".", with: ",") : "\(mb) МБ" }

    static func mb(_ url: URL) -> String {
        let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return n > 1_000_000_000 ? String(format: "%.1f ГБ", Double(n) / 1e9) : "\(n / 1_000_000) МБ"
    }
}

/// Закачка репо HF в кэш (как snapshot_download): api/models/<repo> → список файлов → snapshots/<sha>/<файл>.
final class Downloader: @unchecked Sendable {
    static let shared = Downloader()
    private(set) var progress: [String: String] = [:]   // repo → «12 % (200 из 1600 МБ)»
    private let lock = NSLock()

    func download(_ repo: String, done: @escaping (Error?) -> Void) {
        lock.lock()
        guard progress[repo] == nil else { lock.unlock(); return }
        progress[repo] = "начинаю…"
        lock.unlock()
        Task.detached {
            do {
                try await self.run(repo)
                self.set(repo, nil)
                DispatchQueue.main.async { done(nil) }
            } catch {
                self.set(repo, nil)
                DispatchQueue.main.async { done(error) }
            }
        }
    }

    private func set(_ repo: String, _ s: String?) { lock.lock(); progress[repo] = s; lock.unlock() }

    private func run(_ repo: String) async throws {
        let api = URL(string: "https://huggingface.co/api/models/\(repo)")!
        let (data, _) = try await URLSession.shared.data(from: api)
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = info["sha"] as? String, let sib = info["siblings"] as? [[String: Any]] else {
            throw NSError(domain: "HF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Hugging Face не отдал список файлов \(repo)"])
        }
        let files = sib.compactMap { $0["rfilename"] as? String }
            .filter { !$0.hasPrefix(".") && !$0.hasPrefix("ct2_") && !$0.hasPrefix("examples/") && !$0.hasSuffix(".wav") && !$0.hasSuffix(".nemo") }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + repo.replacingOccurrences(of: "/", with: "--"))
        let snap = root.appendingPathComponent("snapshots/\(sha)")
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("refs"), withIntermediateDirectories: true)
        // размеры для прогресса
        var sizes: [String: Int64] = [:]
        for f in files {
            var req = URLRequest(url: URL(string: "https://huggingface.co/\(repo)/resolve/main/\(f)")!)
            req.httpMethod = "HEAD"
            if let (_, r) = try? await URLSession.shared.data(for: req), let h = r as? HTTPURLResponse {
                sizes[f] = Int64(h.value(forHTTPHeaderField: "x-linked-size") ?? "") ?? h.expectedContentLength
            }
        }
        let total = max(1, sizes.values.reduce(0, +))
        var doneBytes: Int64 = 0
        for f in files {
            let dst = snap.appendingPathComponent(f)
            if FileManager.default.fileExists(atPath: dst.path) { doneBytes += sizes[f] ?? 0; continue }
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(f)")!
            let base = doneBytes
            let delegate = ProgressDelegate { got in
                let p = Double(base + got) / Double(total)
                self.set(repo, String(format: "%.0f %% (%d из %d МБ)", p * 100, (base + got) / 1_000_000, total / 1_000_000))
            }
            let (tmp, resp) = try await URLSession.shared.download(from: url, delegate: delegate)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "HF", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(f): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"])
            }
            try FileManager.default.moveItem(at: tmp, to: dst)
            doneBytes += sizes[f] ?? 0
        }
        try sha.write(to: root.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
    }
}

final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onBytes: (Int64) -> Void
    init(_ f: @escaping (Int64) -> Void) { onBytes = f }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        onBytes(totalBytesWritten)
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
