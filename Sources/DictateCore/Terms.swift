import Foundation

/// Словарь для подсказки Whisper (initial_prompt) — как load_terms()/asr_hint() в Python-версии.
///
/// Порядок = приоритет: слой приложения (terms.d/<слой>.txt) → terms.txt → auto_terms.txt,
/// дедуп по слову без учёта регистра, обрезка по ТОКЕНАМ с хвоста (бюджет 210 из потолка 224).
public struct Terms: Sendable {
    public static let hintTokens = 210
    public let dataDir: URL

    public init(dataDir: URL) { self.dataDir = dataDir }

    public var layersDir: URL { dataDir.appendingPathComponent("terms.d", isDirectory: true) }

    /// Имена слоёв — по файлам terms.d/*.txt.
    public func layers() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layersDir.path)) ?? []
        return names.filter { $0.hasSuffix(".txt") && !$0.hasPrefix(".") }.map { String($0.dropLast(4)) }.sorted()
    }

    /// Слой для приложения: своя настройка (terms_profiles), иначе слой по умолчанию (default_terms).
    /// Слоя нет на диске — общий словарь.
    public func layer(for app: String, profiles: [String: String], defaultLayer: String) -> String {
        let l = profiles[app] ?? defaultLayer
        return layers().contains(l) ? l : ""
    }

    /// Термины через запятую, обрезанные по бюджету. count — длина текста в токенах Whisper.
    public func load(layer: String, budget: Int = Terms.hintTokens, count: (String) -> Int) -> String {
        var paths: [URL] = []
        if !layer.isEmpty { paths.append(layersDir.appendingPathComponent("\(layer).txt")) }
        paths.append(dataDir.appendingPathComponent("terms.txt"))
        paths.append(dataDir.appendingPathComponent("auto_terms.txt"))
        var words: [String] = [], seen = Set<String>()
        for p in paths {
            guard let s = try? String(contentsOf: p, encoding: .utf8) else { continue }
            for line in s.split(whereSeparator: \.isNewline) {
                let w = line.trimmingCharacters(in: .whitespaces)
                if w.isEmpty || w.hasPrefix("#") || seen.contains(w.lowercased()) { continue }
                words.append(w); seen.insert(w.lowercased())
            }
        }
        var out: [String] = [], total = 0
        for w in words {
            let n = count(", " + w)
            if total + n > budget { break }  // ручные идут первыми — обрезается хвост автослоя
            out.append(w); total += n
        }
        return out.joined(separator: ", ")
    }

    /// Подсказка целиком: словарь + «задеплоить.» (как asr_hint). Служебных слов в подсказке быть
    /// не должно — на тихих записях Whisper выдаёт их эхом.
    public func hint(layer: String, count: (String) -> Int) -> String {
        let t = load(layer: layer, count: count)
        return t.isEmpty ? "" : "\(t), задеплоить."
    }
}
