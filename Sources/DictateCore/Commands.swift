import Foundation

/// Голосовые команды и сниппеты — порт commands.py Python-версии, правила те же.
///
/// Команда срабатывает целой фразой («удали», «отправь») — тогда текст не вставляется, — или хвостом
/// («созвон переносим на завтра, отправь») — текст до неё вставляется, потом действие. Хвостом работают
/// только команды, где это осмысленно. Внутри текста команды не ищутся. Сопоставление — по словам
/// (нижний регистр, ё→е, без знаков). Пользовательский слой — commands.json в каталоге данных:
/// snippets (фраза → текст), phrases (свои формулировки встроенных команд), disabled; перечитывается по mtime.
public final class Commands: @unchecked Sendable {
    public static let maxWords = 4

    /// id → (фразы, можно ли хвостом, описание)
    public static let defaults: [(String, [String], Bool, String)] = [
        ("delete_line", ["удали", "удали строку", "сотри", "сотри строку", "очисти строку"], false, "стереть текущую строку"),
        ("undo", ["отмени", "отмена", "откати", "убери"], false, "убрать последнюю вставленную диктовку"),
        ("delete_word", ["удали слово", "сотри слово"], false, "стереть слово слева (⌥⌫)"),
        ("delete_all", ["удали всё", "сотри всё", "очисти всё", "очисти поле"], false, "выделить всё и стереть"),
        ("select_all", ["выдели всё", "выделить всё"], false, "выделить всё (⌘A)"),
        ("repeat", ["повтори", "ещё раз"], false, "вставить последнюю диктовку ещё раз"),
        ("send", ["отправь", "отправить", "отправляй"], true, "Return (в мессенджерах — отправить)"),
        ("new_line", ["новая строка", "с новой строки", "перенос", "перенос строки"], true, "перенос строки без отправки (⇧Return)"),
        ("paragraph", ["абзац", "новый абзац"], true, "пустая строка (⇧Return ×2)"),
        ("tab", ["таб", "табуляция"], true, "Tab"),
        ("enter", ["энтер", "ввод"], true, "Return"),
        ("esc", ["эскейп", "отбой"], false, "Esc"),
        ("copy", ["скопируй", "копировать"], false, "⌘C"),
        ("cut", ["вырежи", "вырезать"], false, "⌘X"),
        ("paste", ["вставь", "вставить"], false, "⌘V"),
        ("translate", ["переведи", "перевод"], true,
         "перевести на английский: хвостом — текст перед командой, отдельно — последнюю вставку"),
        ("style_clean", ["обычный стиль", "стиль чистка", "стиль по умолчанию"], false, "профиль приложения: Чистка"),
        ("style_casual", ["разговорный стиль", "стиль разговорный"], false, "профиль приложения: Разговорный"),
        ("style_formal", ["строгий стиль", "стиль строгий"], false, "профиль приложения: Строгий"),
        ("style_raw", ["как сказано", "стиль как сказано", "без правок"], false, "профиль приложения: Как сказано (без LLM)"),
    ]

    nonisolated(unsafe) public static let template: [String: Any] = [
        "_help": [
            "Сниппеты: фраза -> текст. Сказал «моя почта» — вставилась почта; хвостом тоже: «пиши на, моя почта». Многострочный текст — через \\n.",
            "phrases: свои формулировки для встроенных команд (список заменяет стандартный). Идентификаторы: "
                + defaults.map(\.0).joined(separator: ", "),
            "disabled: список идентификаторов команд, которые выключить.",
            "Файл перечитывается сам, перезапуск не нужен. Меню → «Список команд…» показывает, что сейчас действует.",
        ],
        "snippets": ["моя почта": "user@example.com", "подпись": "С уважением,\nИмя Фамилия"],
        "phrases": [String: Any](),
        "disabled": [String](),
    ]

    public struct Row { public let id: String; public let phrases: [String]; public let trailing: Bool; public let desc: String }

    public struct Match: Equatable {
        public let id: String        // id команды или "snippet:<фраза>"
        public let phrase: String    // какой формулировкой сказано
        public let head: String      // текст ДО команды (хвостовая форма) или ""
        public let snippet: String?  // текст сниппета
        public var isSnippet: Bool { snippet != nil }
        public init(id: String, phrase: String, head: String, snippet: String?) {
            self.id = id; self.phrase = phrase; self.head = head; self.snippet = snippet
        }
    }

    public let url: URL
    private var mtime: Date?
    private var data: [String: Any] = [:]
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    static let wordRE = try! NSRegularExpression(pattern: #"[\w'-]+"#)

    static func norm(_ s: String) -> [String] {
        let t = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        let ns = t as NSString
        return wordRE.matches(in: t, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// commands.json: перечитывается, если файл поменялся. Ошибка — работаем на встроенных.
    func user() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = attrs[.modificationDate] as? Date else { mtime = nil; data = [:]; return [:] }
        if m != mtime {
            mtime = m
            if let d = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                data = obj
            } else {
                data = [:]
                log("  commands.json не прочитан — работаю на встроенных")
            }
        }
        return data
    }

    /// Создать commands.json из шаблона, если его нет.
    public func ensureFile() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        if let d = try? JSONSerialization.data(withJSONObject: Commands.template, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url)
        }
    }

    /// Действующие команды + сниппеты как ("snippet:<фраза>", [фраза], true, текст).
    public func table() -> [Row] {
        let u = user()
        let disabled = Set(u["disabled"] as? [String] ?? [])
        let over = u["phrases"] as? [String: Any] ?? [:]
        var rows: [Row] = []
        for (id, phrases, trailing, desc) in Commands.defaults where !disabled.contains(id) {
            let p = (over[id] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? phrases
            rows.append(Row(id: id, phrases: p, trailing: trailing, desc: desc))
        }
        let snips = u["snippets"] as? [String: Any] ?? [:]
        for (phrase, text) in snips.sorted(by: { $0.key < $1.key }) {
            if let t = text as? String, !t.isEmpty, !phrase.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(Row(id: "snippet:\(phrase)", phrases: [phrase], trailing: true, desc: t))
            }
        }
        return rows
    }

    /// Найти команду: вся фраза или хвост. nil — обычная диктовка.
    public func match(_ raw: String) -> Match? {
        let words = Commands.norm(raw)
        guard !words.isEmpty else { return nil }
        let rows = table()
        if words.count <= Commands.maxWords {
            for r in rows {
                for ph in r.phrases where Commands.norm(ph) == words {
                    return Match(id: r.id, phrase: ph, head: "", snippet: r.id.hasPrefix("snippet:") ? r.desc : nil)
                }
            }
        }
        var best: (Int, Row, String)?
        for r in rows where r.trailing {
            for ph in r.phrases {
                let pw = Commands.norm(ph), k = pw.count
                if k > 0, k < words.count, Array(words.suffix(k)) == pw, best == nil || k > best!.0 { best = (k, r, ph) }
            }
        }
        guard let (k, r, ph) = best else { return nil }
        let src = raw.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
        let ns = src as NSString
        let spans = Commands.wordRE.matches(in: src, range: NSRange(location: 0, length: ns.length))
        let cut = spans[spans.count - k].range.location
        var head = (raw as NSString).substring(to: cut)
        while let last = head.last, " \t\n,.;:!?…—–-".contains(last) { head.removeLast() }
        guard !head.isEmpty else { return nil }
        return Match(id: r.id, phrase: ph, head: head, snippet: r.id.hasPrefix("snippet:") ? r.desc : nil)
    }

    /// Текст для окна «Список команд».
    public func describeAll() -> String {
        var lines: [String] = [], snips: [String] = []
        for r in table() {
            if r.id.hasPrefix("snippet:") {
                var short = r.desc.replacingOccurrences(of: "\n", with: "⏎")
                if short.count > 40 { short = String(short.prefix(39)) + "…" }
                snips.append("• \(r.phrases[0]) → \(short)")
            } else {
                lines.append("• \(r.phrases.joined(separator: " / ")) — \(r.desc)\(r.trailing ? "  (и хвостом)" : "")")
            }
        }
        if !snips.isEmpty { lines += ["", "Сниппеты:"] + snips }
        return lines.joined(separator: "\n")
    }
}

/// Защиты и мелкая правка текста из ml_worker Python-версии.
public enum Guards {
    static let wordRE = try! NSRegularExpression(pattern: #"\w+"#)

    static func words(_ s: String) -> [String] {
        let t = s.lowercased(), ns = t as NSString
        return wordRE.matches(in: t, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Тихое аудио + подсказка ⇒ Whisper перечисляет термины словаря. Эхо — несколько разных терминов,
    /// и все слова из подсказки; одиночный термин — нормальная диктовка.
    public static func isDictionaryEcho(_ raw: String, hint: String) -> Bool {
        let rw = words(raw), hw = Set(words(hint))
        return rw.count >= 2 && Set(rw).isSubset(of: hw) && Set(rw).count >= 2
    }

    /// Петля, рассыпанная по тексту: одно слово ≥ 8 раз и ≥ 40 % слов. Возвращает (слово, сколько).
    public static func wordLoop(_ raw: String) -> (String, Int)? {
        let rw = words(raw)
        guard rw.count >= 8 else { return nil }
        let counts = Dictionary(rw.map { ($0, 1) }, uniquingKeysWith: +)
        guard let (top, cnt) = counts.max(by: { $0.value < $1.value }) else { return nil }
        return cnt >= 8 && Double(cnt) >= Double(rw.count) * 0.4 ? (top, cnt) : nil
    }

    /// Короткая фраза без внутренней пунктуации — скорее фрагмент, точка в конце не нужна.
    public static func stripShortPeriod(_ text: String) -> String {
        if text.hasSuffix("."), !text.dropLast().contains("."), text.count < 60 { return String(text.dropLast()) }
        return text
    }
}
