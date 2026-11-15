import AppKit
import DictateCore
import WebKit

/// История: импорт из Python-версии, автословарь, аудио диктовок, окно поиска и статистики.
enum HistoryTools {
    static var audioDir: URL { Setup.data.appendingPathComponent("audio", isDirectory: true) }

    /// Разово: история Python-версии (~/dictate/history.sqlite3) и её аудио (~/dictate/audio/<id>.wav) — в нашу базу.
    static func importPython(into h: History, config: Config) {
        guard !config.bool("python_history_imported", false) else { return }
        let rows = History.readRows(path: Setup.pythonDir.appendingPathComponent("history.sqlite3").path)
        var n = 0, a = 0
        let pyAudio = Setup.pythonDir.appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        for r in rows.reversed() {  // по времени, старые первыми
            let id = h.insertImported(r)
            guard id > 0 else { continue }
            n += 1
            let src = pyAudio.appendingPathComponent("\(r.id).wav")
            if FileManager.default.fileExists(atPath: src.path),
               (try? FileManager.default.copyItem(at: src, to: audioDir.appendingPathComponent("\(id).wav"))) != nil { a += 1 }
        }
        config.set("python_history_imported", true)
        log("История: из Python-версии взято \(n) диктовок" + (a > 0 ? ", аудиозаписей \(a)" : ""))
    }

    /// auto_terms.txt из истории — как rebuild_autodict Python-версии (при старте и по кнопке).
    @discardableResult
    static func rebuildAutoTerms(_ h: History) -> [String] {
        let known = Set(((try? String(contentsOf: Setup.data.appendingPathComponent("terms.txt"), encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { $0.lowercased() })
        let picked = AutoTerms.build(rows: h.all().map { (raw: $0.raw, text: $0.text) }, known: known)
        try? (picked.joined(separator: "\n") + (picked.isEmpty ? "" : "\n"))
            .write(to: Setup.data.appendingPathComponent("auto_terms.txt"), atomically: true, encoding: .utf8)
        log("Автословарь обновлён: \(picked.isEmpty ? "пусто" : picked.joined(separator: ", "))")
        return picked
    }

    /// audio/<id>.wav — 16 кГц PCM16 (как save_audio Python-версии), потом ротация по audio_max_mb.
    static func saveAudio(id: Int64, _ samples: [Float], maxMB: Int) {
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try? WAV.write(samples, to: audioDir.appendingPathComponent("\(id).wav"))
        rotate(maxMB: maxMB)
    }

    static func audioIDs() -> Set<Int64> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: audioDir.path)) ?? [])
            .filter { $0.hasSuffix(".wav") }.compactMap { Int64($0.dropLast(4)) })
    }

    static func audioStats() -> (Int, Double) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: audioDir.path)) ?? []).filter { $0.hasSuffix(".wav") }
        let bytes = files.reduce(0) { $0 + ((try? fm.attributesOfItem(atPath: audioDir.appendingPathComponent($1).path)[.size] as? Int) ?? 0) }
        return (files.count, Double(bytes) / 1e6)
    }

    /// Старые записи сверх потолка — удалить (по времени изменения).
    static func rotate(maxMB: Int) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "wav" }
            .compactMap { u -> (URL, Date, Int)? in
                guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
                return (u, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
            }.sorted { $0.1 < $1.1 }
        var total = files.reduce(0) { $0 + $1.2 }
        for (u, _, size) in files where total > maxMB * 1_000_000 { try? fm.removeItem(at: u); total -= size }
    }

    static func dictSizes() -> (Int, Int) {
        func count(_ f: String) -> Int {
            ((try? String(contentsOf: Setup.data.appendingPathComponent(f), encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }.count
        }
        return (count("terms.txt"), count("auto_terms.txt"))
    }

    /// Собрать страницу и записать рядом с данными (audio/<id>.wav грузятся по относительному пути).
    static func dashboard(_ mode: String, history h: History) -> URL? {
        guard let tpl = try? String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("dashboard/template.html"), encoding: .utf8)
        else { return nil }
        let html = Dashboard.build(active: mode, rows: h.all(), dict: dictSizes(), audioIDs: audioIDs(), template: tpl)
        let out = Setup.data.appendingPathComponent("dashboard-\(mode).html")
        try? html.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

/// Нативное окно с WKWebView для локального HTML (как webwindow.py): доступ на чтение к каталогу данных.
final class WebWindows {
    private var windows: [String: (NSWindow, WKWebView)] = [:]

    func show(title: String, file: URL) {
        let base = file.deletingLastPathComponent()
        if let (w, web) = windows[title] {
            web.loadFileURL(file, allowingReadAccessTo: base)
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
            return
        }
        let rect = NSRect(x: 0, y: 0, width: 1180, height: 820)
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false; w.center()
        let web = WKWebView(frame: rect)
        web.autoresizingMask = [.width, .height]
        web.loadFileURL(file, allowingReadAccessTo: base)
        w.contentView?.addSubview(web)
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
        windows[title] = (w, web)
    }
}
