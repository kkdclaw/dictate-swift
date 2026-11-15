import AppKit
import AVFoundation
import DictateCore
import SwiftUI

/// Окна «Состояние» и «Модели» — содержимое и кнопки.
extension AppDelegate {
    static let started = Date()

    var statusText: String {
        switch ctl.state {
        case .ready: return ctl.busy > 0 ? "Распознаю…" : "Готово — зажмите \(ctl.tap.spec.label)"
        case .recording: return "Запись…"
        case .loading(let what): return "Подождите: \(what)…"
        case .off: return "Диктовка выключена"
        case .paused: return "Пауза: диктует Python-версия"
        case .error(let e): return "⚠️ \(e)"
        }
    }

    static func inputDevices() -> [String] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map(\.localizedName)
    }

    static func fmtUptime(_ s: TimeInterval) -> String {
        let m = Int(s) / 60
        return m < 60 ? "\(m) мин" : m < 1440 ? "\(m / 60) ч \(m % 60) мин" : "\(m / 1440) д \(m / 60 % 24) ч"
    }

    func statusSnapshot() -> [GridWindow.Section] {
        let c = ctl!, cfg = c.config
        var service: [GridWindow.Row] = [
            .init(label: "Состояние", value: statusText, button: "Перезапустить", action: "restart"),
            .init(label: "Версия", value: "\(AppInfo.version) · сборка \(AppInfo.build) · whisper.cpp", button: "Скопировать", action: "copy_version"),
            .init(label: "Процесс", value: "PID \(getpid()) · работает \(AppDelegate.fmtUptime(Date().timeIntervalSince(AppDelegate.started)))\nданные: \(Setup.data.path)",
                  button: "Журнал…", action: "log"),
            .init(label: "Горячая клавиша", value: "\(c.tap.spec.label) — зажать и говорить · буфер обмена "
                  + (cfg.restoreClipboard ? "возвращается после вставки" : "не возвращается")),
        ]
        if c.pythonActive { service.append(.init(label: "Python-версия", value: "диктует она — эта на паузе", button: "Перейти на эту", action: "use_swift")) }
        let perms: [GridWindow.Row] = Permission.allCases.map {
            .init(label: $0.title, value: ($0.granted ? "✓ выдано" : "✗ нет") + " — нужно, \($0.why)\n(\($0.english))",
                  button: $0.granted ? nil : "Выдать", action: $0.granted ? nil : "perm:\($0.english)")
        }
        let mic: [GridWindow.Row] = [
            .init(label: "Пишем с", value: c.recorder.deviceName),
            .init(label: "Режим", value: c.micOnDemand ? "открывается только на время записи (индикатор не горит в простое)"
                  : "открыт всё время, пока диктовка включена", button: "Переключить", action: "mic_mode"),
            .init(label: "Входы в системе", value: AppDelegate.inputDevices().joined(separator: ", ")),
        ]
        let layers = c.terms.layers()
        let n = c.terms.load(layer: "", budget: 100_000, count: { _ in 1 }).split(separator: ",").count
        let models: [GridWindow.Row] = [
            .init(label: "Распознавание", value: (c.usesApple ? "встроенный распознаватель macOS" : "\(cfg.asrModel.split(separator: "/").last ?? "")") + "\n"
                  + (c.asrReady ? "● готов" : "○ не загружен"), button: "Модели…", action: "models"),
            .init(label: "Словарь", value: "terms.txt + auto_terms: \(n) терминов (в подсказку — до 210 токенов)"
                  + (layers.isEmpty ? "" : "\nслои: \(layers.joined(separator: ", "))"), button: "Папка", action: "data"),
            .init(label: "Чистка", value: "\(cfg.llmModel.split(separator: "/").last ?? "")\n" + (c.cleaner.loaded ? "● в памяти" : c.cleaner.loading ? "⏳ грузится" : "○ не в памяти")
                  + (cfg.unloadLLM ? " · выгружается после \(Int(cfg.llmIdleMin)) мин простоя" : "") + (cfg.enhance ? "" : " · LLM-чистка выключена")),
            .init(label: "История", value: "\(c.history?.count() ?? 0) диктовок"),
        ]
        let (_, route) = c.sounds.routeUID()
        let hud: [GridWindow.Row] = [
            .init(label: "Капсула", value: cfg.bool("hud", true) ? "показывается · \(cfg.string("hud_size", "small")) · \(cfg.string("hud_icon", "bars"))" : "выключена",
                  button: "Проверить", action: "hud_test"),
            .init(label: "Звуки", value: cfg.sounds ? "включены · \(route.isEmpty ? "вывод по умолчанию" : route)" : "выключены"),
        ]
        let vp: [GridWindow.Row] = [
            .init(label: "Состояние", value: (cfg.bool("only_my_voice", false) ? "фильтр включён — вставляю только твой голос" : "фильтр выключен — вставляю любую речь")
                  + "\nотпечаток: \(c.voice.summary)", button: c.voice.print == nil ? "Записать" : "Записать заново", action: "vp_enroll"),
        ] + (c.vpLast.map { [GridWindow.Row(label: "Последнее сравнение", value: String(format: "сходство %.2f при пороге %.2f", $0, cfg.value("vp_threshold") as? Double ?? 0.40))] } ?? [])
        return [("Служба", service), ("Разрешения", perms), ("Микрофон", mic), ("Мой голос", vp), ("Модели", models), ("Капсула и звуки", hud)]
    }

    func modelsSnapshot() -> [GridWindow.Section] {
        let active = ctl.config.asrModel
        let lang = ctl.config.asrLanguage
        if #available(macOS 26.0, *) { Task.detached { Catalog.appleInstalled = await AppleEngine.installed(lang) } }
        var rows: [GridWindow.Row] = []
        for m in Catalog.asr {
            let st = Catalog.status(m, active: active)
            var button: String? = nil, act: String? = nil
            if Downloader.shared.progress[m.repo] != nil { }
            else if m.engine == .parakeet && m.repo == ParakeetEngine.pro && !st.cached && m.repo != active { button = "Скачать"; act = "dl:\(m.repo)" }
            else if m.repo == active { button = "Папка"; act = "dir" }
            else if st.ready || st.cached { button = "Выбрать"; act = "act:\(m.repo)" }
            else { button = "Скачать"; act = "dl:\(m.repo)" }
            rows.append(.init(label: m.name, value: "\(m.title)\n\(st.text)", button: button, action: act))
        }
        var files: [GridWindow.Row] = []
        for m in Catalog.asr where m.repo != active {
            let p = Setup.ggmlPath(for: m.repo)
            if FileManager.default.fileExists(atPath: p.path) {
                files.append(.init(label: m.name, value: "\(Catalog.mb(p)) — перегнанная копия; исходник в кэше Hugging Face не трогаю",
                                   button: "Удалить", action: "rm:\(m.repo)"))
            }
        }
        files.append(.init(label: "Папка", value: Setup.models.path, button: "Открыть", action: "dir"))
        var llm: [GridWindow.Row] = []
        let activeLLM = ctl.config.llmModel
        for m in Catalog.llm {
            let (txt, cached) = Catalog.llmStatus(m, active: activeLLM, loaded: ctl.cleaner.loaded)
            var button: String? = nil, act: String? = nil
            if Downloader.shared.progress[m.repo] != nil || m.repo == activeLLM || m.repo.contains("GigaChat") { }  // GigaChat в Swift пока не грузится
            else if cached { button = "Выбрать"; act = "llm:\(m.repo)" }
            else { button = "Скачать"; act = "dl:\(m.repo)" }
            llm.append(.init(label: m.name, value: "\(m.title)\n\(txt)", button: button, action: act))
        }
        return [("Распознавание", rows), ("Чистка текста", llm), ("Файлы ggml", files)]
    }

    func handle(_ a: String) {
        switch a {
        case "restart": relaunch()
        case "copy_version":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Dictate \(AppInfo.version) (\(AppInfo.build))", forType: .string)
        case "log": openLog()
        case "use_swift": useSwift()
        case "mic_mode": toggleMic()
        case "models": openModels()
        case "vp_enroll": ctl.openEnroll(true)
        case "data": openData()
        case "dir": NSWorkspace.shared.open(Setup.models)
        case "compare":
            let page = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Dictate-сравнение-2026-11-14/распознавание.html")
            if FileManager.default.fileExists(atPath: page.path) { NSWorkspace.shared.open(page) }
        case let s where s.hasPrefix("reveal:"):
            let repo = String(s.dropFirst(7))
            let ggml = Setup.ggmlPath(for: repo)
            if FileManager.default.fileExists(atPath: ggml.path) { NSWorkspace.shared.activateFileViewerSelecting([ggml]) }
            else if let snap = MLXConverter.cachedSnapshot(repo: repo) { NSWorkspace.shared.activateFileViewerSelecting([snap]) }
            else { NSWorkspace.shared.open(Setup.models) }
        case let s where s.hasPrefix("hf:"):
            if let u = URL(string: "https://huggingface.co/\(s.dropFirst(3))") { NSWorkspace.shared.open(u) }
        case "hud_test":
            ctl.hud.show(.rec)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if self.ctl.state != .recording { self.ctl.hud.hide() } }
        case let s where s.hasPrefix("perm:"):
            Permission.allCases.first { "perm:\($0.english)" == s }?.request { self.ctl.refresh() }
        case let s where s.hasPrefix("act:"):
            ctl.switchModel(String(s.dropFirst(4)))
        case let s where s.hasPrefix("llm:"):
            let repo = String(s.dropFirst(4))
            ctl.config.set("llm_model", repo)
            ctl.cleaner.unload("выбрана другая модель")
            log("Модели: модель чистки — \(repo)")
            if ctl.config.enhance && !ctl.config.unloadLLM { ctl.preloadLLM() }
        case let s where s.hasPrefix("dl:"):
            let repo = String(s.dropFirst(3))
            log("Модели: качаю \(repo)…")
            Downloader.shared.download(repo) { err in
                log("Модели: \(repo) — " + (err.map { "не скачалась: \($0.localizedDescription)" } ?? "скачана"))
            }
        case let s where s.hasPrefix("rm:"):
            let repo = String(s.dropFirst(3))
            let a = NSAlert()
            a.messageText = "Удалить перегнанную модель \(repo.split(separator: "/").last ?? "")?"
            a.informativeText = "Удаляется только копия в формате ggml (\(Catalog.mb(Setup.ggmlPath(for: repo)))). Исходник в кэше Python-версии остаётся — «Выбрать» перегонит её снова за секунды."
            a.addButton(withTitle: "Удалить"); a.addButton(withTitle: "Отмена")
            if a.runModal() == .alertFirstButtonReturn {
                try? FileManager.default.removeItem(at: Setup.ggmlPath(for: repo))
                log("Модели: удалил \(Setup.ggmlPath(for: repo).lastPathComponent)")
            }
        default: break
        }
    }

    @objc func openStatus() {
        if statusWindow == nil {
            statusWindow = GridWindow(title: "Dictate — состояние", snapshot: { [unowned self] in self.statusSnapshot() },
                                      onAction: { [unowned self] in self.handle($0) })
        }
        statusWindow?.show()
    }

    @objc func openModels() {
        if modelsPanel == nil {
            let store = ModelsStore(app: self)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Модели — Dictate"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ModelsView(store: store))
            w.center()
            modelsPanel = (w, store)
        }
        modelsPanel?.1.refresh()
        NSApp.activate(ignoringOtherApps: true)
        modelsPanel?.0.makeKeyAndOrderFront(nil)
    }
}
