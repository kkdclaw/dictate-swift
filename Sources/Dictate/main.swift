import AppKit
import DictateCore
import ServiceManagement
import SwiftUI

// MARK: - Диктовка: нажал → записал → распознал → вставил

final class Controller {
    enum State: Equatable { case loading(String), ready, recording, paused, off, noMic, error(String) }

    static let minDuration = 0.4   // сек: короче — случайное нажатие
    static let silentPeak: Float = 0.02  // говорил, а пик ниже — захват пустой (Python 0.17.2)

    let config: Config
    let terms: Terms
    let history: History?
    let recorder = Recorder()
    let paster = Paster()
    lazy var actions = Actions(paster: paster)
    lazy var hud = HUD(config: config)
    let sounds = Sounds()
    let cleaner = Cleaner()
    let review = ReviewWindow()
    let voice = VoicePrint()
    let enrollWin = EnrollWindow()
    private var enrolling: (enroll: Bool, started: Date, timer: Timer)?
    private(set) var vpLast: Double?
    let commands: DictateCore.Commands
    let tap: HotkeyTap
    private(set) var engine: WhisperEngine?
    private var appleAny: AnyObject?  // AppleEngine (macOS 26+)
    private(set) var parakeet: ParakeetEngine?
    var usesParakeet: Bool { [ParakeetEngine.ultra, ParakeetEngine.pro].contains(config.asrModel) }
    @available(macOS 26.0, *) var apple: AppleEngine? { appleAny as? AppleEngine }
    private let appleQueue = DispatchQueue(label: "asr-apple", qos: .userInitiated)
    /// Очередь распознавания текущего движка (VAD и отпечаток — на ней же, последовательно).
    var asrQueue: DispatchQueue { engine?.queue ?? appleQueue }
    var asrReady: Bool { engine != nil || appleAny != nil || parakeet != nil }
    var usesApple: Bool { config.asrModel == AppleASR.repo }
    private var vad: VAD?
    private(set) var state: State = .loading("запуск")
    private(set) var busy = 0
    private(set) var pythonActive = false
    private var recApp = ""
    private var pressTime = Date()
    private var toggleMode = false
    /// Запись идёт, а вход ещё отдаёт нули: сигнал «говорите» (звук, цветная капсула) отложен до onLive.
    private var waitLive = false
    /// Сколько после нажатия микрофон молчал нулями (с) — для строки «Диктовка:»; nil — был готов сразу.
    private var recMicDelay: Double?
    /// Отложенное закрытие микрофона после записи (тёплое окно mic_warm_sec).
    private var micClose: DispatchWorkItem?
    static let tapMax = 0.35  // сек: короче — «тап» (запись до второго тапа), дольше — push-to-talk
    private var loadingModel = false
    private var askedPermissions = false
    private var lastPermLine = ""
    var onChange: () -> Void = {}

    init() {
        Setup.prepareDataDir()
        config = Config(url: Setup.data.appendingPathComponent("config.json"))
        terms = Terms(dataDir: Setup.data)
        commands = DictateCore.Commands(url: Setup.data.appendingPathComponent("commands.json"))
        history = try? History(path: Setup.data.appendingPathComponent("history.sqlite3").path)
        tap = HotkeyTap(spec: HotkeySpec.parse(config.hotkey) ?? HotkeySpec.parse("alt_r")!)
        if let h = history {
            DispatchQueue.global(qos: .utility).async { [config] in
                HistoryTools.importPython(into: h, config: config)
                HistoryTools.rebuildAutoTerms(h)  // пересобирается при каждом старте, как в Python-версии
            }
        }
        tap.onPress = { [weak self] in self?.press() }
        tap.onEsc = { [weak self] in if self?.state == .recording { self?.cancelRecording("Esc") } }
        tap.onOtherKey = { [weak self] in
            // ⌘C на правом Command, ⌥-символ: сочетание с модификатором, а не диктовка
            if let self, self.state == .recording, !self.toggleMode { self.cancelRecording("клавиша использована как модификатор") }
        }
        recorder.onLevel = { [weak self] rms in self?.hud.pushLevel(rms) }
        recorder.onLive = { [weak self] in self?.micLive() }
        tap.onRelease = { [weak self] in self?.release() }
    }

    var missingPermissions: [Permission] { Permission.allCases.filter { !$0.granted } }

    /// Привести состояние к конфигу: выключено / пауза из-за Python / модель / разрешения / работа.
    func refresh() {
        pythonActive = Setup.pythonActive
        if !config.enabled { disarm(); engine = nil; set(.off); return }
        if pythonActive { disarm(); set(.paused); return }
        guard asrReady else { loadModel(); return }
        let permLine = Permission.allCases.map { "\($0.english) \($0.granted ? "✓" : "✗")" }.joined(separator: ", ")
        if permLine != lastPermLine { lastPermLine = permLine; log("Разрешения: \(permLine)") }
        if !missingPermissions.isEmpty {
            if !askedPermissions {  // один раз за запуск — системные запросы; дальше — меню «Разрешения»
                askedPermissions = true
                requestChain(missingPermissions)
            }
            disarm()
            set(.error("нет разрешений: " + missingPermissions.map(\.title).joined(separator: ", ")))
            return
        }
        // входа нет (Mac mini, Mac Studio без гарнитуры) — ждём микрофон; хоткей живой и отвечает сигналом ошибки
        if !Recorder.hasInput, state != .recording {
            if state != .noMic { log("Микрофон: в системе нет ни одного входа — диктовка ждёт микрофон") }
            micClose?.cancel(); micClose = nil
            if recorder.running && enrolling == nil { recorder.stop() }
            if !tap.active { _ = tap.start() }
            set(.noMic); return
        }
        arm()
    }

    func requestMissingPermissions() { requestChain(missingPermissions) }

    private func requestChain(_ list: [Permission]) {
        guard let first = list.first else { return }
        first.request { [weak self] in self?.requestChain(Array(list.dropFirst())) }
    }

    private func set(_ s: State) {
        guard state != s else { return }
        state = s
        DispatchQueue.main.async { self.onChange() }
    }

    private func loadModel() {
        guard !loadingModel else { return }
        loadingModel = true
        let repo = config.asrModel
        if usesParakeet {
            set(.loading(repo == ParakeetEngine.ultra ? "готовлю Parakeet Ultra (первый раз качает ~630 МБ)" : "готовлю Fluid Speech Pro"))
            Task.detached {
                do {
                    let p = try await ParakeetEngine.load(repo: repo)
                    let v = try? VAD(modelPath: Setup.vadModel.path)
                    log("Модель: \(repo) загружена (FluidAudio, нейроядро)")
                    await MainActor.run { self.parakeet = p; self.vad = v; self.loadingModel = false; self.refresh() }
                } catch {
                    log("Модель: \(error.localizedDescription)")
                    await MainActor.run { self.loadingModel = false; self.set(.error(error.localizedDescription)) }
                }
            }
            return
        }
        if repo == AppleASR.repo {
            guard #available(macOS 26.0, *) else { set(.error("встроенный распознаватель нужен macOS 26+")); loadingModel = false; return }
            set(.loading("готовлю встроенный распознаватель macOS"))
            let a = AppleEngine(language: config.asrLanguage)
            Task.detached {
                do {
                    log("Модель: встроенный распознаватель macOS — \(try await a.install())")
                    let v = try? VAD(modelPath: Setup.vadModel.path)
                    await MainActor.run { self.appleAny = a; self.vad = v; self.loadingModel = false; self.refresh() }
                } catch {
                    log("Модель: \(error.localizedDescription)")
                    await MainActor.run { self.loadingModel = false; self.set(.error(error.localizedDescription)) }
                }
            }
            return
        }
        set(.loading(Setup.fm.fileExists(atPath: Setup.ggmlPath(for: repo).path) ? "загружаю модель" : "перегоняю модель из кэша Python-версии"))
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let path = try Setup.ensureModel(repo: repo)
                let t = Date()
                let e = try WhisperEngine(modelPath: path.path)
                let v = try? VAD(modelPath: Setup.vadModel.path)
                if v == nil { log("VAD: модель не загрузилась — распознаю без проверки речи") }
                log(String(format: "Модель: %@ загружена за %.1f с", path.lastPathComponent, Date().timeIntervalSince(t)))
                DispatchQueue.main.async {
                    self.engine = e; self.vad = v; self.loadingModel = false; self.refresh()
                    if self.config.enhance && !self.config.unloadLLM { self.preloadLLM() }
                    if self.config.bool("only_my_voice", false) && self.voice.print != nil {
                        Task.detached { [voice = self.voice] in _ = try? await voice.ensureModel() }
                    }
                }
            } catch {
                log("Модель: \(error.localizedDescription)")
                DispatchQueue.main.async { self.loadingModel = false; self.set(.error(error.localizedDescription)) }
            }
        }
    }

    /// Микрофон только на время записи (по умолчанию): индикатор macOS не горит в простое,
    /// AirPods не застревают в режиме гарнитуры. Цена — открытие входа на старте записи.
    var micOnDemand: Bool { config.string("mic_mode", "on_demand") != "always" }

    func setMicOnDemand(_ on: Bool) {
        config.set("mic_mode", on ? "on_demand" : "always")
        micClose?.cancel(); micClose = nil
        if on, recorder.running, state != .recording, enrolling == nil { recorder.stop() }
        refresh()
    }

    /// Сколько держать микрофон открытым после записи в режиме on_demand (с; 0 — закрывать сразу).
    /// У AirPods каждое открытие заново поднимает канал гарнитуры — 0,2–1,3 с нулей, начало фразы теряется;
    /// серия диктовок с паузами короче окна идёт без этой потери. Цена — индикатор микрофона и режим
    /// гарнитуры AirPods на время окна.
    var micWarm: Double { (config.value("mic_warm_sec") as? Double) ?? Double(config.value("mic_warm_sec") as? Int ?? 60) }

    func setMicWarm(_ sec: Double) {
        config.set("mic_warm_sec", sec)
        log(sec > 0 ? String(format: "Микрофон: держу открытым %.0f с после диктовки", sec) : "Микрофон: закрываю сразу после диктовки")
        if micClose != nil { releaseMic() }  // окно уже идёт — пересчитать с новым сроком
    }

    /// Конец записи: в режиме on_demand микрофон закрывается не сразу, а после mic_warm_sec простоя.
    private func releaseMic() {
        guard micOnDemand else { return }
        micClose?.cancel(); micClose = nil
        let warm = micWarm
        guard warm > 0, recorder.running else { if recorder.running { recorder.stop() }; return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.micClose = nil
            if self.state != .recording, self.enrolling == nil, self.recorder.running { self.recorder.stop() }
        }
        micClose = w
        DispatchQueue.main.asyncAfter(deadline: .now() + warm, execute: w)
    }

    /// Вход отдал первый звук: если запись ждала его — теперь сигнал «говорите».
    private func micLive() {
        guard waitLive else { return }
        waitLive = false
        guard state == .recording else { return }
        recMicDelay = Date().timeIntervalSince(pressTime)
        sound("start")
        hud.setMode(.rec)
    }

    private func arm() {
        if micOnDemand {
            // открыт вне записи — закрыть, если это не тёплое окно после диктовки и не запись отпечатка
            if recorder.running && state != .recording && micClose == nil && enrolling == nil { recorder.stop() }
        } else if !recorder.running {
            do { try recorder.start(); log("Микрофон: \(recorder.deviceName)") } catch {
                set(.error("микрофон: \(error.localizedDescription)")); return
            }
        }
        if !tap.active {
            guard tap.start() else {
                // разрешение выдали, а перехват не создаётся — macOS ждёт перезапуска приложения
                set(.error("перехват клавиш не включился — перезапустите Dictate (пункт меню)")); return
            }
            log("Хоткей: \(tap.spec.label)")
        }
        if state != .recording { set(.ready) }
    }

    private func disarm() {
        tap.stop()
        micClose?.cancel(); micClose = nil
        if recorder.running { recorder.stop() }
    }

    /// Звук события: kind — start / done / error, имя звука — из config (sound_start…; «none» — без звука).
    private func sound(_ kind: String) {
        guard config.sounds else { return }
        sounds.play(kind, name: soundName(kind))
    }

    func soundName(_ kind: String) -> String {
        kind == "start" ? config.soundStart : kind == "done" ? config.soundDone : config.soundError
    }

    /// Выбран звук в меню — сохранить и сыграть, как прозвучит (тем же маршрутом, мимо Bluetooth).
    func setSound(_ kind: String, _ name: String) {
        config.set("sound_\(kind)", name)
        sounds.play(kind, name: name)
    }

    /// Язык распознавания: ru / en / "" — автоопределение (whisper сам, ~1 с дольше). Встроенный распознаватель
    /// macOS держит язык в себе — пересоздаём; Parakeet и whisper берут язык на каждой диктовке.
    func setLanguage(_ code: String) {
        guard code != config.asrLanguage else { return }
        config.set("asr_language", code)
        log("Язык распознавания: \(code.isEmpty ? "автоопределение" : code)")
        if config.asrModel == AppleASR.repo && state != .recording { disarm(); appleAny = nil; refresh() }
    }

    /// Пример капсулы: запись 3 с, затем «распознаю» 2 с — как выглядит при текущих настройках.
    func previewHUD() {
        guard state != .recording else { return }
        hud.show(.rec)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { if self.state != .recording { self.hud.setMode(.busy) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { if self.state != .recording { self.hud.hide() } }
    }

    private func press() {
        if state == .recording {
            // второй тап в toggle-режиме — стоп; в push-to-talk сюда попадаем, если отпускание потерялось
            if !toggleMode { log("  (отпускание не пришло — останавливаю по повторному нажатию)") }
            stopAndSubmit(); return
        }
        if state == .noMic {
            log("Диктовка: нет микрофона — подключите вход (Настройки → Звук → Вход)")
            sound("error"); return
        }
        guard state == .ready, enrolling == nil else { return }
        pressTime = Date(); toggleMode = false
        recApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        review.close(cancelled: true)
        micClose?.cancel(); micClose = nil
        recorder.begin()
        if !recorder.running {
            do { try recorder.start() } catch {
                log("Микрофон: не открылся — \(error.localizedDescription)")
                sound("error"); return
            }
        }
        recMicDelay = nil
        if recorder.isLive {
            waitLive = false
            sound("start")
            hud.show(.rec)
        } else {
            // вход ещё в нулях (AirPods поднимают канал гарнитуры) — серая капсула, звук начала — когда пойдёт звук
            waitLive = true
            hud.show(.wait)
        }
        set(.recording)
    }

    private func release() {
        guard state == .recording, !toggleMode else { return }
        let hold = Date().timeIntervalSince(pressTime)
        if hold < Controller.tapMax {
            toggleMode = true  // короткий тап: пишем дальше до второго тапа или Esc
            log(String(format: "  … toggle-режим (тап %.2f с): говори, ещё один тап %@ — стоп, Esc — отмена", hold, tap.spec.label))
            return
        }
        stopAndSubmit()
    }

    private func cancelRecording(_ reason: String) {
        guard state == .recording else { return }
        _ = recorder.end()
        waitLive = false
        releaseMic()
        toggleMode = false
        hud.hide()
        set(.ready)
        log("  ✗ запись отменена (\(reason))")
    }

    /// Смена хоткея из меню или окна захвата.
    func setHotkey(_ spec: String) {
        guard let hk = HotkeySpec.parse(spec) else { return }
        if state == .recording { stopAndSubmit() }
        config.set("hotkey", spec)
        tap.setSpec(hk)
        log("  горячая клавиша теперь: \(hk.label) (\(spec))")
        onChange()
    }

    private func stopAndSubmit() {
        guard state == .recording else { return }
        toggleMode = false
        let audio = recorder.end()
        let micDead = waitLive
        waitLive = false
        releaseMic()
        set(.ready)
        let dur = Double(audio.count) / 16000
        guard dur >= Controller.minDuration else { hud.hide(); return }
        if micDead {
            log(String(format: "Диктовка: микрофон не успел включиться за %.1f с (%@) — говорить после звука начала; не ожил и дальше — проверьте вход",
                       Date().timeIntervalSince(pressTime), recorder.deviceName))
            sound("error"); hud.hide()
            return
        }
        let micNote = recMicDelay.map { String(format: " · микрофон через %.2f с", $0) } ?? ""
        let peak = audio.reduce(Float(0)) { max($0, abs($1)) }
        if peak < Controller.silentPeak {
            log(String(format: "Диктовка: захват пустой (%.1f с, пик %.4f) — проверьте микрофон: %@", dur, peak, recorder.deviceName))
            sound("error"); hud.hide()
            return
        }
        guard asrReady else { hud.hide(); return }
        let engine = self.engine, appleAny = self.appleAny, parakeet = self.parakeet
        hud.setMode(.busy)
        let app = recApp, lang = config.asrLanguage
        let layer = terms.layer(for: app, profiles: config.termsProfiles, defaultLayer: config.defaultTerms)
        busy += 1; onChange()
        let vad = self.vad
        asrQueue.async { [terms] in
            // VAD: есть ли вообще речь, и если есть — обрезать тишину по краям (как Python-версия)
            var audio = audio
            if let vad {
                let spans = vad.spans(audio)
                guard let first = spans.first, let last = spans.last else {
                    DispatchQueue.main.async {
                        self.busy -= 1; self.onChange()
                        log(String(format: "Диктовка: ✗ речи не слышно (%.1f с, пик %.3f — сигнал есть, VAD речь не нашёл) — не вставляю", dur, peak))
                        if self.state != .recording { self.hud.hide() }
                        self.sound("error")
                    }
                    return
                }
                let a = max(0, Int((first.0 - 0.25) * 16000)), b = min(audio.count, Int((last.1 + 0.1) * 16000))
                if b > a { audio = Array(audio[a..<b]) }
            }
            // отпечаток голоса: чужую речь (ТВ, коллеги) не транскрибируем
            if self.config.bool("only_my_voice", false), let vp = self.voice.print, self.voice.ready {
                if let e = try? self.voice.embed(audio) {
                    let sim = VoicePrint.dot(e, vp.vec), thr = self.config.value("vp_threshold") as? Double ?? vp.threshold
                    DispatchQueue.main.async { self.vpLast = sim }
                    if sim < thr {
                        DispatchQueue.main.async {
                            self.busy -= 1; self.onChange()
                            log(String(format: "  ✗ не твой голос (сходство %.2f < %.2f) — не вставляю.%@", sim, thr,
                                       sim > thr - 0.1 ? "  Почти прошло — «Мой голос → Строгость» мягче или перезапиши отпечаток." : ""))
                            if self.state != .recording { self.hud.hide() }
                            self.sound("error")
                        }
                        return
                    }
                } else { log("  ⚠ отпечаток не сравнился — вставляю без проверки") }
            }
            var r: WhisperEngine.Result
            let hint: String
            if let engine {
                hint = terms.hint(layer: layer, count: engine.tokenCount)
                r = engine.run(audio, language: lang, prompt: hint)
            } else if let parakeet {
                // Parakeet: словаря-подсказки нет
                hint = ""
                let sem = DispatchSemaphore(value: 0)
                var out = ("", 0.0)
                Task { out = (try? await parakeet.transcribe(audio, language: lang)) ?? ("", 0); sem.signal() }
                sem.wait()
                r = WhisperEngine.Result(text: out.0, segments: [], ms: out.1)
            } else if #available(macOS 26.0, *), let apple = appleAny as? AppleEngine {
                // встроенный распознаватель: словарь — подсказкой contextualStrings, вероятностей слов нет
                hint = terms.hint(layer: layer, count: { $0.count / 3 + 1 })
                let list = terms.load(layer: layer, count: { $0.count / 3 + 1 }).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let sem = DispatchSemaphore(value: 0)
                var out = ("", 0.0)
                Task { out = (try? await apple.transcribe(audio, terms: list)) ?? ("", 0); sem.signal() }
                sem.wait()
                r = WhisperEngine.Result(text: out.0, segments: [], ms: out.1)
            } else { return }
            let (raw, cut) = TextClean.stripLoops(r.text, segments: r.segments)  // петли и титры — до всего
            DispatchQueue.main.async {
                self.busy -= 1; self.onChange()
                if !cut.isEmpty { log("  ✂ вырезал галлюцинацию: \(cut.joined(separator: ", ").prefix(160))") }
                log(String(format: "Диктовка: %.1f с звука · asr %.2f с · словарь:%@ · %@ · %d симв.%@",
                           dur, r.ms / 1000, layer.isEmpty ? "общий" : layer, app, raw.count, micNote))
                if self.state != .recording { self.hud.hide() }  // новая запись уже идёт — её капсулу не трогаем
                self.deliver(raw: raw, hint: hint, app: app, layer: layer, dur: dur, asrMs: r.ms, asrText: r.text, words: r.words, audio: audio)
            }
        }
    }

    /// После распознавания: защиты → голосовая команда → стиль/чистка → вставка → действие. Как ml_worker Python-версии.
    private func deliver(raw: String, hint: String, app: String, layer: String, dur: Double, asrMs: Double, asrText: String,
                         words: [Styles.Word], audio: [Float] = []) {
        guard !raw.isEmpty else { sound("error"); return }
        if Guards.isDictionaryEcho(raw, hint: hint) {
            log("  ✗ похоже на эхо словаря, не вставляю: \(raw)"); sound("error"); return
        }
        if let (top, cnt) = Guards.wordLoop(raw) {
            log("  ✗ распознавание зациклилось на «\(top)» (\(cnt) раз) — не вставляю"); sound("error"); return
        }
        let restore = config.restoreClipboard
        let cmd = config.bool("commands", true) ? commands.match(raw) : nil
        if let cmd, cmd.head.isEmpty {  // вся фраза — команда: действие вместо вставки
            runCommand(cmd, app: app, restore: restore, layer: layer)
            return
        }
        var style = config.style(for: app)
        var src = raw, snippetTail: String? = nil
        if let cmd {  // хвостовая форма: текст до команды идёт обычным путём
            src = cmd.head
            if cmd.isSnippet { snippetTail = cmd.snippet } else if cmd.id == "translate" { style = "translate" }
        }
        let doubtful = Styles.doubtful(words, raw: src)
        Task {
            let termsText = hint.hasSuffix(", задеплоить.") ? String(hint.dropLast(13)) : hint  // load_terms(layer), как в Python
            let (styled, st) = await self.render(style: style, raw: src, doubtful: doubtful, termsText: termsText)
            await MainActor.run {
                var text = Styles.polish(style: style, styled)
                if let snip = snippetTail { text += (snip.contains("\n") ? "\n" : " ") + snip }  // «пиши на, моя почта»
                if self.config.bool("review", false) && cmd == nil {
                    self.offerReview(raw: src, text: text, style: style, doubtful: doubtful, termsText: termsText,
                                     app: app, dur: dur, asrMs: asrMs, asrText: asrText, st: st, audio: audio)
                    return
                }
                if st.ms > 0 {
                    log(String(format: "  стиль %@ · llm %.2f с · %.0f т/с%@", style, st.ms / 1000, st.tps,
                               doubtful.isEmpty ? "" : " · сомнения: \(doubtful.joined(separator: ", "))"))
                }
                self.paster.paste(text, restore: restore)
                self.actions.remember(text, raw: src, app: app)
                let rid = self.history?.insert(text: text, raw: asrText, duration: dur, app: app, style: style, asrMs: asrMs,
                                     llmMs: st.ms, genTps: st.ms > 0 ? st.tps : nil, genTokens: st.ms > 0 ? st.genTokens : nil) ?? -1
                self.keepAudio(rid, audio)
                if let cmd, !cmd.isSnippet, cmd.id != "translate" {
                    // действие после вставки; пауза — чтобы Return не обогнал ⌘V
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.runCommand(cmd, app: app, restore: restore, layer: layer, after: true) }
                }
                self.sound("done")
            }
        }
    }

    /// Окно с вариантами: сырой и обычный — сразу, стили из ячеек review_styles досчитываются по очереди.
    /// Вставку и запись в историю делает клик по варианту.
    private func offerReview(raw: String, text: String, style: String, doubtful: [String], termsText: String,
                             app: String, dur: Double, asrMs: Double, asrText: String, st: Cleaner.Stats, audio: [Float] = []) {
        var vs = [ReviewWindow.Variant(key: "raw", title: "Как сказано · сырой Whisper", text: Styles.polish(style: "raw", raw))]
        if text != vs[0].text { vs.append(.init(key: style, title: "\(Styles.label(style)) · обычный результат", text: text)) }
        let slots = (config.value("review_styles") as? [Any]) ?? ["formal", "brief"]
        let extra = slots.compactMap { $0 as? String }.filter { k in !vs.contains { $0.key == k } }
        vs += extra.map { ReviewWindow.Variant(key: $0, title: Styles.label($0), text: nil) }
        let sid = review.show(vs, onPick: { [weak self] key, picked in
            guard let self else { return }
            let now = NSWorkspace.shared.frontmostApplication?.localizedName ?? app
            if now != app { log("  ⚠ фокус уже в «\(now)», а диктовали в «\(app)» — вставляю туда, где курсор") }
            self.paster.paste(picked, restore: self.config.restoreClipboard)
            self.actions.remember(picked, raw: raw, app: now)
            let rid = self.history?.insert(text: picked, raw: asrText, duration: dur, app: now, style: key, asrMs: asrMs,
                                 llmMs: st.ms, genTps: st.ms > 0 ? st.tps : nil, genTokens: st.ms > 0 ? st.genTokens : nil) ?? -1
            self.keepAudio(rid, audio)
            self.sound("done")
            log("  ⇢ постобработка: вставлен вариант «\(Styles.label(key))»")
        }, onCancel: { log("  ⇠ постобработка: ничего не вставлено") })
        log("  ⇢ окно постобработки: \(vs.count) вариант(а/ов), считаю \(extra.isEmpty ? "—" : extra.map(Styles.label).joined(separator: ", "))")
        Task {
            for k in extra {
                guard await MainActor.run(body: { self.review.isOpen(sid) }) else { log("  окно постобработки закрыли — остальные стили не считаю"); break }
                let t = Date()
                let (out, _) = await self.render(style: k, raw: raw, doubtful: doubtful, termsText: termsText)
                await MainActor.run { self.review.update(sid, key: k, text: Styles.polish(style: k, out)) }
                log(String(format: "  ⇢ %@ готов за %.1f с", Styles.label(k), Date().timeIntervalSince(t)))
            }
        }
    }

    /// Галка «Хранить аудио диктовок»: audio/<id>.wav, потолок audio_max_mb (по умолчанию 2000 МБ).
    private func keepAudio(_ id: Int64, _ audio: [Float]) {
        guard id > 0, config.bool("keep_audio", false), !audio.isEmpty else { return }
        let maxMB = config.value("audio_max_mb") as? Int ?? 2000
        DispatchQueue.global(qos: .utility).async { HistoryTools.saveAudio(id: id, audio, maxMB: maxMB) }
    }

    private func runCommand(_ cmd: DictateCore.Commands.Match, app: String, restore: Bool, layer: String, after: Bool = false) {
        // стили и перевод требуют модели — их выполняем здесь, остальное — Actions
        if cmd.id.hasPrefix("style_") {
            let st = String(cmd.id.dropFirst(6))
            var p = config.profiles; p[app] = st; config.set("profiles", p)
            log("  ⚡ команда «\(cmd.phrase)» → профиль \(app) → \(Styles.label(st))")
            sound("done"); return
        }
        if cmd.id == "translate" {
            guard let lp = actions.last else { log("  ⚡ «\(cmd.phrase)» не выполнена: нечего переводить — сначала продиктуй"); sound("error"); return }
            Task {
                let (out, _) = await self.render(style: "translate", raw: lp.raw, doubtful: [], termsText: "")
                await MainActor.run {
                    do {
                        _ = try self.actions.run(DictateCore.Commands.Match(id: "undo", phrase: "отмени", head: "", snippet: nil), app: app, restore: restore)
                        self.paster.paste(out, restore: restore)
                        self.actions.remember(out, raw: lp.raw, app: app)
                        log("  ⚡ команда «\(cmd.phrase)» → перевёл последнюю вставку: \(out)")
                        self.sound("done")
                    } catch {
                        log("  ⚡ «\(cmd.phrase)» не выполнена: \((error as? Actions.Failed)?.why ?? "\(error)")"); self.sound("error")
                    }
                }
            }
            return
        }
        do {
            let what = try actions.run(cmd, app: app, restore: restore)
            log("  ⚡ команда «\(cmd.phrase)» → \(what)" + (after ? "" : "  [\(app)]"))
            if !after { sound("done") }
        } catch {
            log("  ⚡ команда «\(cmd.phrase)» не выполнена: \((error as? Actions.Failed)?.why ?? "\(error)")")
            if !after { sound("error") }
        }
    }

    /// Текст в заданном стиле — одна точка входа и для вставки, и для окна постобработки (как render в Python).
    func render(style: String, raw: String, doubtful: [String], termsText: String) async -> (String, Cleaner.Stats) {
        let none = Cleaner.Stats()
        if style == "raw" { return (raw, none) }
        let auto = style == "clean" || style == "casual"
        if auto && !(config.enhance && (Styles.needsEnhance(raw) || !doubtful.isEmpty)) { return (raw, none) }
        if !cleaner.loaded {
            if auto {
                // холодная модель: автоправка не ждёт загрузку — сырой текст сразу, прогрев фоном (Python 0.15.7)
                log("  модель чистки не в памяти — вставляю без чистки, грею её фоном к следующей диктовке")
                preloadLLM()
                return (raw, none)
            }
            do { try await cleaner.load(repo: config.llmModel) } catch {
                log("Чистка: \(error.localizedDescription) — вставляю сырой"); return (raw, none)
            }
        }
        do {
            switch style {
            case "translate":
                let (out, st) = try await cleaner.run(system: Styles.translatePrompt, user: raw, maxFactor: 3)
                return (out.isEmpty ? raw : out, st)
            case "informal", "brief":
                let (task, limit) = style == "informal" ? (Styles.informalTask, 1.4) : (Styles.briefTask, 1.05)
                let (out, st) = try await cleaner.run(system: Styles.restyleSystem, user: Styles.restyleUser(task: task, raw: raw), maxFactor: 1)
                let (res, why) = Styles.checkRestyle(out, raw: raw, limit: limit)
                if let why { log("  ⛔ стиль «\(Styles.label(style))»: \(why) — оставил сырой") }
                return (res, st)
            default:  // clean, casual, formal
                var system = Styles.systemPrompt(terms: termsText) + (style == "formal" ? Styles.formalAddon : "")
                if !doubtful.isEmpty { system += Styles.doubtAddon(doubtful) }
                let (out0, st) = try await cleaner.run(system: system, user: raw)
                let out = Styles.checkEnhance(out0, raw: raw)
                if style == "formal" { return (out, st) }
                let tl = Set(termsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                let guarded = Styles.guardCorrection(raw: raw, out: out, terms: tl)
                if guarded != out { log("  ⛔ пост-контроль откатил часть правок LLM") }
                return (guarded, st)
            }
        } catch {
            log("Чистка: ошибка (\(error.localizedDescription)) — вставляю сырой")
            return (raw, none)
        }
    }

    func preloadLLM() {
        guard !cleaner.loading, !cleaner.loaded else { return }
        let repo = config.llmModel
        Task.detached { [cleaner] in
            do { try await cleaner.load(repo: repo) } catch { log("Чистка: \(error.localizedDescription)") }
        }
    }

    /// Сторож простоя: выгрузить модель чистки через llm_idle_min минут (галка unload_llm).
    func llmIdleTick() {
        guard config.unloadLLM, cleaner.loaded, Date().timeIntervalSince(cleaner.lastUse) > config.llmIdleMin * 60 else { return }
        cleaner.unload("простой \(Int(config.llmIdleMin)) мин")
    }

    /// Выбрать модель распознавания: перегнать из кэша, если надо, и перезагрузить движок.
    func switchModel(_ repo: String) {
        guard repo != config.asrModel || engine == nil else { return }
        log("Модели: выбрана \(repo)")
        config.set("asr_model", repo)
        disarm()
        engine = nil; appleAny = nil; parakeet = nil
        refresh()
    }

    /// Только речь (по VAD) — отпечаток и проверка обязаны идти через это (как speech_only Python-версии).
    private func speechOnly(_ audio: [Float]) -> [Float] {
        guard let vad else { return audio }
        let spans = asrQueue.sync { vad.spans(audio) }
        return spans.flatMap { sp -> [Float] in
            let a = max(0, Int(sp.0 * 16000)), b = min(audio.count, Int(sp.1 * 16000))
            return b > a ? Array(audio[a..<b]) : []
        }
    }

    /// Окно записи (enroll) или проверки отпечатка. Запись стартует кнопкой — человек успевает приготовиться.
    func openEnroll(_ enroll: Bool) {
        guard state == .ready else {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert(); a.messageText = "Отпечаток голоса"; a.informativeText = "Диктовка не готова: \(stateText)"; a.runModal(); return
        }
        let secs = enroll ? VoicePrint.recordSec : VoicePrint.checkSec
        enrollWin.onPrimary = { [weak self] in
            guard let self else { return }
            if self.enrolling != nil { self.finishEnroll(cancel: false) } else { self.beginEnroll(enroll, secs: secs) }
        }
        enrollWin.onSecondary = { [weak self] in
            guard let self else { return }
            if self.enrolling != nil { self.finishEnroll(cancel: true) } else { self.enrollWin.close() }
        }
        enrollWin.show(enroll: enroll, mic: recorder.deviceName, secs: secs)
        Task.detached { [voice] in _ = try? await voice.ensureModel() }  // модель качается/грузится, пока человек читает
    }

    var stateText: String {
        switch state { case .error(let e): e; case .loading(let w): w; case .off: "выключена"; case .paused: "пауза"; case .noMic: "нет микрофона"; default: "занята" }
    }

    private func beginEnroll(_ enroll: Bool, secs: Double) {
        micClose?.cancel(); micClose = nil
        recorder.begin()
        if !recorder.running { do { try recorder.start() } catch { enrollWin.finish(ok: false, "Микрофон не открылся: \(error.localizedDescription)", again: "Попробовать снова"); return } }
        sound("start")
        let started = Date()
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let e = self.enrolling else { return }
            let left = secs - Date().timeIntervalSince(e.started)
            if left <= 0 { self.finishEnroll(cancel: false) } else { self.enrollWin.recording(left: left, lvl: self.recorder.level / 12) }
        }
        enrolling = (enroll, started, t)
        log(enroll ? "Отпечаток: запись…" : "Отпечаток: проверка…")
    }

    private func finishEnroll(cancel: Bool) {
        guard let e = enrolling else { return }
        e.timer.invalidate(); enrolling = nil
        let audio = recorder.end()
        releaseMic()
        if cancel { enrollWin.close(); log("Отпечаток: отменено"); return }
        enrollWin.busy()
        let mic = recorder.deviceName
        Task.detached { [self] in
            do {
                _ = try await self.voice.ensureModel()
                let speech = self.speechOnly(audio)
                if e.enroll {
                    let p = try self.voice.make(speech: speech, device: mic)
                    self.voice.save(p)
                    await MainActor.run {
                        self.config.set("vp_threshold", p.threshold)  // порог от разброса, не с потолка
                        log(String(format: "Отпечаток голоса сохранён (%.0f с речи, окон %d, само-похожесть %.2f…%.2f, порог %.2f)", p.speechSec, p.windows, p.selfMin, p.selfMean, p.threshold))
                        self.enrollWin.finish(ok: true, String(format: "Отпечаток записан: %.0f с чистой речи, %d окон, микрофон «%@».\nОкна похожи друг на друга на %.2f…%.2f — порог подобран автоматически: %.2f.\nТеперь включи «Пропускать только мой голос» и при желании нажми «Проверить».", p.speechSec, p.windows, mic, p.selfMin, p.selfMean, p.threshold), again: "Записать заново")
                    }
                } else {
                    guard let vp = self.voice.print else { throw VoicePrint.Err("отпечаток ещё не записан") }
                    guard speech.count >= 16000 else { throw VoicePrint.Err("речи не слышно — скажи фразу вслух") }
                    let sim = VoicePrint.dot(try self.voice.embed(speech), vp.vec)
                    let thr = self.config.value("vp_threshold") as? Double ?? vp.threshold
                    await MainActor.run {
                        self.vpLast = sim
                        log(String(format: "  проверка голоса: сходство %.2f при пороге %.2f", sim, thr))
                        self.enrollWin.finish(ok: sim >= thr, String(format: "%@\nСходство %.2f при пороге %.2f, микрофон «%@». %@",
                            sim >= thr ? "Узнаю — это твой голос." : "Не узнаю — такую диктовку я бы отбросил.", sim, thr, mic,
                            sim >= thr + 0.1 ? "Запас хороший." : "Запас маленький: перезапиши отпечаток на этом микрофоне или сделай строгость мягче."), again: "Проверить ещё раз")
                    }
                }
            } catch {
                await MainActor.run {
                    log("  ✗ отпечаток: \(error.localizedDescription)")
                    self.enrollWin.finish(ok: false, "\(error.localizedDescription)\nЧитай текст непрерывно, обычным голосом, в тот же микрофон.", again: "Попробовать снова")
                }
            }
        }
    }

    func setEnabled(_ on: Bool) { config.set("enabled", on); refresh() }

    /// Перейти с Python-версии на эту (Python → 🌙) или обратно.
    func switchFromPython(_ toSwift: Bool) {
        DispatchQueue.global().async {
            do { try Setup.setPythonEnabled(!toSwift) } catch { log("Python-версия: не переключилась — \(error.localizedDescription)") }
            DispatchQueue.main.async {
                if !toSwift { self.config.set("enabled", false) } else { self.config.set("enabled", true) }
                self.askedPermissions = false
                self.refresh()
            }
        }
    }
}

// MARK: - Меню-бар

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var ctl: Controller!
    var timer: Timer?
    var statusWindow: GridWindow?
    let capture = HotkeyCapture()
    let webs = WebWindows()
    var updater: Updater!
    var modelsWindow: GridWindow?
    var modelsPanel: (NSWindow, ModelsStore)?

    func applicationDidFinishLaunching(_ n: Notification) {
        Log.shared.open(Setup.data.appendingPathComponent("dictate.log"))
        log("Dictate \(AppInfo.version) (\(AppInfo.build), Swift) — запуск, данные: \(Setup.data.path)")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        ctl = Controller()
        ctl.onChange = { [weak self] in self?.updateIcon() }
        updater = Updater(config: ctl.config)
        updater.isIdle = { [weak self] in self?.ctl.state != .recording && self?.ctl.busy == 0 }
        updater.startSchedule()  // GitHub Releases публичного репо — без токена
        updateIcon()
        if Permission.microphone.granted == false { Permission.microphone.request { self.ctl.refresh() } }
        ctl.refresh()
        // разрешения выдают в Настройках, Python-версию могут выключить — проверяем раз в 3 с
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.ctl.state != .recording, self.ctl.busy == 0 else { return }
            self.ctl.refresh()
            self.ctl.llmIdleTick()
        }
    }

    func updateIcon() {
        let s: String
        // значки Python-версии: 🎙️ готов, 🟠 запись, ⏳ загрузка, ❌ ошибка, 🌙 выключено; ⏸ — диктует Python-версия
        switch ctl.state {
        case .recording: s = "🟠"
        case .loading: s = "⏳"
        case .off: s = "🌙"
        case .paused: s = "⏸"
        case .error: s = "❌"
        case .noMic: s = "🎙️⚠️"
        case .ready: s = "🎙️"
        }
        item.button?.title = s
    }

    /// Меню: сверху — состояние и ежедневное, ниже — модели и голос, внизу — настройки и служебное.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = ctl.config
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let asrName = Catalog.allASR.first { $0.repo == cfg.asrModel }?.name ?? String(cfg.asrModel.split(separator: "/").last ?? "")
        let llmName = Catalog.llm.first { $0.repo == cfg.llmModel }?.name ?? String(cfg.llmModel.split(separator: "/").last ?? "")

        // 1. состояние
        menu.addItem(info(statusText))
        menu.addItem(info("\(asrName) · чистка \(cfg.enhance ? llmName : "выключена") · стиль в «\(app)»: \(Styles.short(cfg.style(for: app)))"))
        menu.addItem(micMenu())
        let en = action("Диктовка включена", #selector(toggleEnabled)); en.state = cfg.enabled ? .on : .off
        menu.addItem(en)
        if !ctl.missingPermissions.isEmpty {
            menu.addItem(action("⚠️ Не хватает разрешений: " + ctl.missingPermissions.map(\.title).joined(separator: ", ") + " — выдать…", #selector(requestMissing)))
        }
        menu.addItem(.separator())

        // 2. каждый день
        menu.addItem(styleMenu())
        menu.addItem(commandsMenu())
        menu.addItem(historyMenu())
        menu.addItem(.separator())

        // 3. модели, голос, словарь
        menu.addItem(action("Модели…", #selector(openModels)))
        menu.addItem(languageMenu())
        menu.addItem(voiceMenu())
        menu.addItem(dictionaryMenu())
        menu.addItem(.separator())

        // 4. настройки и служебное
        menu.addItem(settingsMenu())
        menu.addItem(action("Состояние…", #selector(openStatus)))
        menu.addItem(aboutMenu(asrName))
        menu.addItem(action("Помощь", #selector(openHelp)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Индикатор микрофона: какой вход пишет и открыт ли он сейчас (горит ли индикатор macOS); входа нет — предупреждение.
    /// Список входов — для справки: выбирают их в Настройках macOS (Звук → Вход).
    func micMenu() -> NSMenuItem {
        let inputs = AppDelegate.inputDevices()
        let settings = action("Настройки звука…", #selector(openSoundSettings))
        guard Recorder.hasInput else {
            return sub("⚠️ Микрофона нет — подключите USB-микрофон, гарнитуру или AirPods",
                       [info(inputs.isEmpty ? "Входов в системе нет" : "Входы: " + inputs.joined(separator: ", ")), .separator(), settings])
        }
        let cur = ctl.recorder.deviceName
        let items = inputs.map { n -> NSMenuItem in let it = info(n); it.state = n == cur ? .on : .off; return it }
        return sub("Микрофон: \(cur)" + (ctl.recorder.running ? " · открыт" : ""), items + [.separator(), settings])
    }
    @objc func openSoundSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenu(); items.forEach { m.addItem($0) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); it.submenu = m
        return it
    }

    func commandsMenu() -> NSMenuItem {
        let on = action("Включены", #selector(toggleCommands)); on.state = ctl.config.bool("commands", true) ? .on : .off
        return sub("Голосовые команды", [on, action("Список команд…", #selector(showCommands)), action("Мои сниппеты (commands.json)…", #selector(openCommands))])
    }

    static let languages = [("ru", "Русский"), ("en", "English"), ("", "Автоопределение (медленнее)")]

    /// Язык распознавания — как в Python-версии: русский, английский, автоопределение (умеет только Whisper).
    func languageMenu() -> NSMenuItem {
        let cur = ctl.config.asrLanguage
        let m = NSMenu()
        for (code, label) in AppDelegate.languages {
            let it = NSMenuItem(title: label, action: #selector(setLanguage(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = code; it.state = cur == code ? .on : .off
            m.addItem(it)
        }
        let engine = Catalog.allASR.first { $0.repo == ctl.config.asrModel }?.engine ?? .whisper
        if engine != .whisper && cur.isEmpty {
            m.addItem(.separator())
            m.addItem(info("Автоопределение умеет только Whisper — эта модель пишет по-русски"))
        }
        let name = cur.isEmpty ? "авто" : AppDelegate.languages.first { $0.0 == cur }?.1 ?? cur
        let it = NSMenuItem(title: "Язык распознавания: \(name)", action: nil, keyEquivalent: ""); it.submenu = m
        return it
    }
    @objc func setLanguage(_ s: NSMenuItem) { if let c = s.representedObject as? String { ctl.setLanguage(c) } }

    /// Словарь и слои — как в Python-версии: слой для текущего приложения, слой по умолчанию, файлы.
    /// Слой = terms.d/<имя>.txt, идёт в подсказку раньше общего terms.txt (бюджет подсказки — 210 токенов).
    func dictionaryMenu() -> NSMenuItem {
        let cfg = ctl.config, terms = ctl.terms
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let layers = terms.layers()
        let cur = terms.layer(for: app, profiles: cfg.termsProfiles, defaultLayer: cfg.defaultTerms)
        let own = cfg.termsProfiles[app]
        let label = { (l: String) in l.isEmpty ? "только общий" : "«\(l)»" }

        let am = NSMenu()
        let rows: [(String?, String)] = [(nil, "Как по умолчанию (\(label(layers.contains(cfg.defaultTerms) ? cfg.defaultTerms : "")))"),
                                         ("", "— только общий —")] + layers.map { ($0, $0) }
        for (key, title) in rows {
            let it = NSMenuItem(title: title, action: app.isEmpty ? nil : #selector(setAppLayer(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = [app] + (key.map { [$0] } ?? [])
            it.state = (key == nil ? own == nil : own == key) ? .on : .off
            am.addItem(it)
        }
        let ai = NSMenuItem(title: "Слой для «\(app)»: \(own.map(label) ?? "как по умолчанию")", action: nil, keyEquivalent: ""); ai.submenu = am

        let dm = NSMenu()
        for (key, title) in [("", "— только общий —")] + layers.map({ ($0, $0) }) {
            let it = NSMenuItem(title: title, action: #selector(setDefaultLayer(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = key; it.state = cfg.defaultTerms == key ? .on : .off
            dm.addItem(it)
        }
        let di = NSMenuItem(title: "Слой по умолчанию: \(label(layers.contains(cfg.defaultTerms) ? cfg.defaultTerms : ""))", action: nil, keyEquivalent: ""); di.submenu = dm

        var items = [info("Сейчас: " + (cur.isEmpty ? "" : "слой «\(cur)» + ") + "terms.txt + автослой"), ai, di]
        if layers.isEmpty { items.append(info("Слоёв нет — файл terms.d/<имя>.txt, по слову на строку")) }
        items += [.separator(), action("Открыть словарь (terms.txt)…", #selector(openTerms))]
        let ol = action(cur.isEmpty ? "Слой не выбран — открывать нечего" : "Открыть слой «\(cur)»…", #selector(openLayer(_:)))
        ol.representedObject = cur
        if cur.isEmpty { ol.action = nil }
        items += [ol, action("Папка слоёв (terms.d)…", #selector(openLayersDir)), .separator(),
                  action("Пересобрать автословарь из истории", #selector(rebuildAutoTerms))]
        return sub(cur.isEmpty ? "Словарь терминов" : "Словарь терминов: слой «\(cur)»", items)
    }
    @objc func setAppLayer(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [String], let app = kv.first, !app.isEmpty else { return }
        var p = ctl.config.termsProfiles
        if kv.count > 1 { p[app] = kv[1] } else { p.removeValue(forKey: app) }
        ctl.config.set("terms_profiles", p)
        log("Словарь: слой для «\(app)» — \(kv.count > 1 ? (kv[1].isEmpty ? "только общий" : kv[1]) : "как по умолчанию")")
    }
    @objc func setDefaultLayer(_ s: NSMenuItem) {
        guard let k = s.representedObject as? String else { return }
        ctl.config.set("default_terms", k)
        log("Словарь: слой по умолчанию — \(k.isEmpty ? "только общий" : k)")
    }
    @objc func openLayer(_ s: NSMenuItem) {
        guard let l = s.representedObject as? String, !l.isEmpty else { return }
        NSWorkspace.shared.open(ctl.terms.layersDir.appendingPathComponent("\(l).txt"))
    }
    @objc func openLayersDir() {
        try? FileManager.default.createDirectory(at: ctl.terms.layersDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ctl.terms.layersDir)
    }

    static let soundEvents = [("start", "Начало записи"), ("done", "Текст вставлен"), ("error", "Ошибка")]

    /// Звуки — как в Python-версии: включены/выключены и свой системный звук на каждое событие (выбор сразу звучит).
    func soundsMenu() -> NSMenuItem {
        let m = NSMenu()
        let on = action("Включены", #selector(toggleSounds)); on.state = ctl.config.sounds ? .on : .off
        m.addItem(on)
        m.addItem(.separator())
        let names = ["none"] + Sounds.systemSounds()
        for (kind, title) in AppDelegate.soundEvents {
            let cur = ctl.soundName(kind)
            let sm = NSMenu()
            for n in names {
                let it = NSMenuItem(title: n == "none" ? "Без звука" : n, action: #selector(setSound(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = [kind, n]; it.state = cur == n ? .on : .off
                sm.addItem(it)
            }
            let it = NSMenuItem(title: "\(title): \(cur == "none" ? "без звука" : cur)", action: nil, keyEquivalent: ""); it.submenu = sm
            m.addItem(it)
        }
        let it = NSMenuItem(title: ctl.config.sounds ? "Звуки" : "Звуки: выключены", action: nil, keyEquivalent: ""); it.submenu = m
        return it
    }
    @objc func setSound(_ s: NSMenuItem) { if let kv = s.representedObject as? [String] { ctl.setSound(kv[0], kv[1]) } }

    func settingsMenu() -> NSMenuItem {
        let cfg = ctl.config
        let mic = action("Микрофон только во время записи", #selector(toggleMic)); mic.state = ctl.micOnDemand ? .on : .off
        let clip = action("Возвращать буфер обмена после вставки", #selector(toggleClipboard)); clip.state = cfg.restoreClipboard ? .on : .off
        let ka = action("Хранить аудио диктовок (для сравнения моделей)", #selector(toggleKeepAudio)); ka.state = cfg.bool("keep_audio", false) ? .on : .off
        let login = action("Запускать при входе", #selector(toggleLogin)); login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let perms = Permission.allCases.map { p -> NSMenuItem in
            let it = NSMenuItem(title: (p.granted ? "✓ " : "✗ ") + "\(p.title) (\(p.english))", action: #selector(requestPermission(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = p; return it
        }
        let pi = sub(ctl.missingPermissions.isEmpty ? "Разрешения: все выданы" : "Разрешения: не хватает \(ctl.missingPermissions.count)", perms)
        let micItems = ctl.micOnDemand ? [mic, micWarmMenu()] : [mic]
        return sub("Настройки", [hotkeyMenu()] + micItems + [hudMenu(), soundsMenu(), clip, .separator(), ka, login, pi])
    }

    static let warmChoices: [(Double, String)] = [(0, "Не держать — закрывать сразу"), (15, "15 с"), (30, "30 с"),
                                                  (60, "1 мин"), (120, "2 мин"), (300, "5 мин")]

    /// Тёплое окно микрофона: после диктовки вход не закрывается N секунд — следующая фраза серии не теряет
    /// начало на подключении AirPods (канал гарнитуры поднимается 0,2–1,3 с).
    func micWarmMenu() -> NSMenuItem {
        let cur = ctl.micWarm
        let items = AppDelegate.warmChoices.map { (s, t) -> NSMenuItem in
            let it = NSMenuItem(title: t, action: #selector(setMicWarm(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = s; it.state = cur == s ? .on : .off
            return it
        }
        let now = cur == 0 ? "нет" : AppDelegate.warmChoices.first { $0.0 == cur }?.1 ?? String(format: "%.0f с", cur)
        return sub("Держать микрофон после диктовки: \(now)", items)
    }
    @objc func setMicWarm(_ s: NSMenuItem) { if let v = s.representedObject as? Double { ctl.setMicWarm(v) } }

    @objc func requestMissing() { ctl.requestMissingPermissions() }
    @objc func toggleSounds() { ctl.config.set("sounds", !ctl.config.sounds) }
    @objc func toggleClipboard() { ctl.config.set("restore_clipboard", !ctl.config.restoreClipboard) }
    @objc func openTerms() {
        let f = Setup.data.appendingPathComponent("terms.txt")
        if !FileManager.default.fileExists(atPath: f.path) { try? "# по слову на строку — сверху важнее\n".write(to: f, atomically: true, encoding: .utf8) }
        NSWorkspace.shared.open(f)
    }

    func info(_ t: String) -> NSMenuItem { NSMenuItem(title: t, action: nil, keyEquivalent: "") }
    func action(_ t: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: t, action: sel, keyEquivalent: ""); it.target = self; return it
    }

    @objc func toggleEnabled() { ctl.setEnabled(!ctl.config.enabled) }
    /// Стили — как в Python-версии: по умолчанию, профиль текущего приложения, чистка, выгрузка, перевод всего.
    func styleMenu() -> NSMenuItem {
        let cfg = ctl.config
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let m = NSMenu()
        let prof = NSMenu()
        let cur = cfg.profiles[app]
        let d = NSMenuItem(title: "По умолчанию (\(Styles.short(cfg.defaultStyle)))", action: #selector(setProfile(_:)), keyEquivalent: "")
        d.target = self; d.representedObject = [app, ""]; d.state = cur == nil ? .on : .off
        prof.addItem(d)
        for (k, label) in Styles.all {
            let it = NSMenuItem(title: label, action: #selector(setProfile(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = [app, k]; it.state = cur == k ? .on : .off
            prof.addItem(it)
        }
        let pi = NSMenuItem(title: "Стиль в «\(app)»: \(cur.map(Styles.short) ?? "по умолчанию")", action: nil, keyEquivalent: "")
        pi.submenu = prof
        m.addItem(pi)
        let def = NSMenu()
        for (k, label) in Styles.all where k != "translate" {
            let it = NSMenuItem(title: label, action: #selector(setDefaultStyle(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = k; it.state = cfg.defaultStyle == k ? .on : .off
            def.addItem(it)
        }
        let di = NSMenuItem(title: "Стиль по умолчанию: \(Styles.short(cfg.defaultStyle))", action: nil, keyEquivalent: "")
        di.submenu = def
        m.addItem(di)
        m.addItem(.separator())
        let rv = action("Окно постобработки (выбор варианта)", #selector(toggleReview)); rv.state = cfg.bool("review", false) ? .on : .off
        m.addItem(rv)
        let slots = (cfg.value("review_styles") as? [Any]) ?? []
        for i in 0..<4 {
            let cur = i < slots.count ? slots[i] as? String : nil
            let sub = NSMenu()
            for (k, label) in [("", "— выключена")] + Styles.all.filter({ $0.0 != "raw" }) {
                let it = NSMenuItem(title: label, action: #selector(setReviewSlot(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = [String(i), k]; it.state = (cur ?? "") == k ? .on : .off
                sub.addItem(it)
            }
            let it = NSMenuItem(title: "    Ячейка \(i + 1): \(cur.map(Styles.short) ?? "— выключена")", action: nil, keyEquivalent: "")
            it.submenu = sub
            m.addItem(it)
        }
        m.addItem(.separator())
        let en = action("LLM-чистка паразитов", #selector(toggleEnhance)); en.state = cfg.enhance ? .on : .off
        m.addItem(en)
        let un = action("Выгружать модель чистки в простое", #selector(toggleUnload)); un.state = cfg.unloadLLM ? .on : .off
        m.addItem(un)
        let tr = action("Перевод всего → EN", #selector(toggleTranslateAll)); tr.state = cfg.bool("translate_all", false) ? .on : .off
        m.addItem(tr)
        m.addItem(info("Модель чистки: \(Catalog.llm.first { $0.repo == cfg.llmModel }?.name ?? String(cfg.llmModel.split(separator: "/").last ?? "")) · " + (ctl.cleaner.loaded ? "● в памяти" : ctl.cleaner.loading ? "⏳ грузится" : "○ не в памяти")))
        let it = NSMenuItem(title: "Стиль и чистка", action: nil, keyEquivalent: ""); it.submenu = m
        return it
    }
    @objc func setProfile(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [String] else { return }
        var p = ctl.config.profiles
        if kv[1].isEmpty { p.removeValue(forKey: kv[0]) } else { p[kv[0]] = kv[1] }
        ctl.config.set("profiles", p)
    }
    @objc func setDefaultStyle(_ s: NSMenuItem) { if let k = s.representedObject as? String { ctl.config.set("default_style", k) } }
    @objc func toggleEnhance() { ctl.config.set("enhance", !ctl.config.enhance); if ctl.config.enhance && !ctl.config.unloadLLM { ctl.preloadLLM() } }
    @objc func toggleUnload() {
        ctl.config.set("unload_llm", !ctl.config.unloadLLM)
        if ctl.config.unloadLLM { ctl.cleaner.unload("включена выгрузка в простое") } else if ctl.config.enhance { ctl.preloadLLM() }
    }
    /// «О программе»: версия, проверка обновлений, автообновление и период — как в Python-версии.
    func aboutMenu(_ model: String) -> NSMenuItem {
        let m = NSMenu()
        m.addItem(info("Dictate \(AppInfo.version) · сборка \(AppInfo.build)"))
        m.addItem(.separator())
        let up = action(updater.busy ? "Проверяю обновления…" : "Проверить обновления", #selector(updateNow))
        if updater.busy { up.action = nil }
        m.addItem(up)
        if updater.lastCheck != nil { m.addItem(info("    последняя проверка: \(updater.lastResult)")) }
        let au = action("Автообновление", #selector(toggleAutoUpdate)); au.state = updater.auto ? .on : .off
        m.addItem(au)
        let pm = NSMenu()
        for (k, label) in [("day", "Раз в день"), ("week", "Раз в неделю"), ("month", "Раз в месяц")] {
            let it = NSMenuItem(title: label, action: #selector(setUpdatePeriod(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = k; it.state = ctl.config.string("auto_update_every", "day") == k ? .on : .off
            pm.addItem(it)
        }
        let pi = NSMenuItem(title: "Проверять новую версию", action: nil, keyEquivalent: ""); pi.submenu = pm
        if !updater.auto { pi.isEnabled = false }
        m.addItem(pi)
        m.addItem(.separator())
        m.addItem(action("Открыть журнал", #selector(openLog)))
        m.addItem(action("Перезапустить Dictate", #selector(relaunch)))
        let it = NSMenuItem(title: "О программе (\(AppInfo.version))", action: nil, keyEquivalent: "")
        it.submenu = m
        return it
    }
    @objc func openHelp() {
        webs.show(title: "Dictate — помощь", file: Bundle.main.resourceURL!.appendingPathComponent("help/index.html"))
    }
    @objc func copyVersion() { handle("copy_version") }
    @objc func updateNow() { updater.check(manual: true) }
    @objc func toggleAutoUpdate() { ctl.config.set("auto_update", !updater.auto) }
    @objc func setUpdatePeriod(_ s: NSMenuItem) { if let k = s.representedObject as? String { ctl.config.set("auto_update_every", k) } }

    /// «Мой голос» — как в Python-версии: состояние, фильтр, запись, проверка, строгость.
    func voiceMenu() -> NSMenuItem {
        let cfg = ctl.config, have = ctl.voice.print != nil
        let m = NSMenu()
        m.addItem(info("Отпечаток: \(ctl.voice.summary)"))
        if let s = ctl.vpLast { m.addItem(info(String(format: "Последнее сравнение: %.2f", s))) }
        m.addItem(.separator())
        let on = action("Пропускать только мой голос", #selector(toggleOnlyMyVoice)); on.state = cfg.bool("only_my_voice", false) && have ? .on : .off
        m.addItem(on)
        m.addItem(action("Записать отпечаток заново…", #selector(enrollVoice)))
        let chk = action("Проверить: узнаю ли я тебя…", #selector(checkVoice)); chk.isEnabled = have
        if !have { chk.action = nil }
        m.addItem(chk)
        let st = NSMenu()
        let thr = cfg.value("vp_threshold") as? Double ?? 0.40
        for (label, t) in VoicePrint.strictness {
            let it = NSMenuItem(title: label, action: #selector(setStrictness(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = t; it.state = abs(thr - t) < 0.005 ? .on : .off
            st.addItem(it)
        }
        let si = NSMenuItem(title: "Строгость (порог \(String(format: "%.2f", thr)))", action: nil, keyEquivalent: ""); si.submenu = st
        m.addItem(si)
        let it = NSMenuItem(title: "Мой голос", action: nil, keyEquivalent: ""); it.submenu = m
        return it
    }
    @objc func toggleOnlyMyVoice() {
        if ctl.voice.print == nil && !ctl.config.bool("only_my_voice", false) { ctl.openEnroll(true); return }  // сначала запись
        let on = !ctl.config.bool("only_my_voice", false)
        ctl.config.set("only_my_voice", on)
        if on { Task.detached { [voice = ctl.voice] in _ = try? await voice.ensureModel() } }
    }
    @objc func enrollVoice() { ctl.openEnroll(true) }
    @objc func checkVoice() { ctl.openEnroll(false) }
    @objc func setStrictness(_ s: NSMenuItem) { if let t = s.representedObject as? Double { ctl.config.set("vp_threshold", t) } }

    func historyMenu() -> NSMenuItem {
        let m = NSMenu()
        m.addItem(action("Поиск истории…", #selector(openSearch)))
        m.addItem(action("Статистика…", #selector(openStats)))
        m.addItem(.separator())
        let recent = ctl.history?.all().prefix(5) ?? []
        if !recent.isEmpty {
            m.addItem(info("Последние (клик — скопировать):"))
            for r in recent {
                let t = r.text.replacingOccurrences(of: "\n", with: " ")
                let it = NSMenuItem(title: "  " + (t.count > 60 ? String(t.prefix(59)) + "…" : t), action: #selector(copyRecent(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = r.text
                m.addItem(it)
            }
        }
        let (n, mb) = HistoryTools.audioStats()
        if n > 0 { m.addItem(.separator()); m.addItem(info(String(format: "Аудио диктовок: %d файлов, %.0f МБ", n, mb))) }
        let it = NSMenuItem(title: "История (\(ctl.history?.count() ?? 0))", action: nil, keyEquivalent: ""); it.submenu = m
        return it
    }
    @objc func openSearch() { dashboard("search", "Поиск истории — Dictate") }
    @objc func openStats() { dashboard("stats", "Статистика — Dictate") }
    func dashboard(_ mode: String, _ title: String) {
        guard let h = ctl.history, let url = HistoryTools.dashboard(mode, history: h) else { log("История: страница не собралась"); return }
        webs.show(title: title, file: url)
    }
    @objc func copyRecent(_ s: NSMenuItem) {
        guard let t = s.representedObject as? String else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
    }
    @objc func toggleKeepAudio() { ctl.config.set("keep_audio", !ctl.config.bool("keep_audio", false)) }
    @objc func rebuildAutoTerms() {
        guard let h = ctl.history else { return }
        DispatchQueue.global(qos: .utility).async {
            let picked = HistoryTools.rebuildAutoTerms(h)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert(); a.messageText = "Автословарь"
                a.informativeText = picked.isEmpty ? "Пусто: в истории нет повторяющейся латиницы и устоявшихся исправлений."
                    : "auto_terms.txt (\(picked.count)): \(picked.joined(separator: ", ")).\nДействует со следующей диктовки; пересобирается сам при каждом запуске."
                a.runModal()
            }
        }
    }

    func hotkeyMenu() -> NSMenuItem {
        let cur = ctl.config.hotkey
        let m = NSMenu()
        var preset = false
        for (spec, label) in HotkeySpec.presets {
            let it = NSMenuItem(title: label, action: #selector(setHotkeyPreset(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = spec; it.state = spec == cur ? .on : .off
            preset = preset || spec == cur
            m.addItem(it)
        }
        m.addItem(.separator())
        let custom = action(preset ? "Своё сочетание…" : "Своё сочетание: \(ctl.tap.spec.label)…", #selector(captureHotkey))
        custom.state = preset ? .off : .on
        m.addItem(custom)
        m.addItem(action("Как это работает…", #selector(hotkeyHelp)))
        let it = NSMenuItem(title: "Горячая клавиша: \(ctl.tap.spec.label)", action: nil, keyEquivalent: ""); it.submenu = m
        return it
    }
    @objc func setHotkeyPreset(_ s: NSMenuItem) { if let spec = s.representedObject as? String { ctl.setHotkey(spec) } }
    @objc func captureHotkey() {
        log("  жду новое сочетание для диктовки…")
        capture.start(tap: ctl.tap, current: ctl.tap.spec.label) { [weak self] spec in
            if let spec { self?.ctl.setHotkey(spec) } else { log("  захват сочетания отменён") }
        }
    }
    @objc func hotkeyHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Горячая клавиша диктовки"
        a.informativeText = """
            Сейчас: \(ctl.tap.spec.label).

            Зажал — говоришь — отпустил: текст вставится. Короткий тап (<0.35 с) включает запись до второго тапа; Esc — отмена.

            Готовые варианты — в меню; «Своё сочетание…» ловит любое: одиночный модификатор, F-клавишу или клавишу с модификаторами (⌃ Space, ⌘⇧ D). Буквы запоминаются по физической кнопке — раскладка не важна.

            Fn / 🌐: в Настройках → Клавиатура поставь «При нажатии клавиши 🌐» = «Ничего не делать», иначе macOS будет открывать эмодзи. Сочетания вида ⌘C на выбранном модификаторе диктовку не запускают.

            В config.json это ключ hotkey (сейчас «\(ctl.config.hotkey)»).
            """
        a.runModal()
    }
    @objc func toggleReview() { ctl.config.set("review", !ctl.config.bool("review", false)) }
    @objc func setReviewSlot(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [String], let i = Int(kv[0]) else { return }
        var slots: [Any] = (ctl.config.value("review_styles") as? [Any]) ?? []
        while slots.count < 4 { slots.append(NSNull()) }
        slots[i] = kv[1].isEmpty ? NSNull() : kv[1]
        ctl.config.set("review_styles", slots)
    }
    @objc func toggleTranslateAll() { ctl.config.set("translate_all", !ctl.config.bool("translate_all", false)) }

    func hudMenu() -> NSMenuItem {
        let cfg = ctl.config
        let m = NSMenu()
        let on = action("Показывать капсулу", #selector(toggleHUD)); on.state = cfg.bool("hud", true) ? .on : .off
        m.addItem(on)
        m.addItem(action("Показать пример (5 с)", #selector(previewHUD)))
        m.addItem(.separator())
        func group(_ title: String, _ key: String, _ def: String, _ opts: [(String, String)]) {
            let sub = NSMenu()
            for (k, label) in opts {
                let it = NSMenuItem(title: label, action: #selector(setHUDOption(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = [key, k]
                it.state = cfg.string(key, def) == k ? .on : .off
                sub.addItem(it)
            }
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); it.submenu = sub
            m.addItem(it)
        }
        group("Размер", "hud_size", "small", HUD.sizes.map { ($0.0, $0.1) })
        group("Значок", "hud_icon", "bars", HUD.icons)
        group("Цвет", "hud_color", "red", HUD.colors.map { ($0.0, $0.1) })
        group("Фон", "hud_bg", "system", HUD.backgrounds)
        group("Где показывать", "hud_pos", "caret", HUD.positions)
        let it = NSMenuItem(title: "Капсула записи", action: nil, keyEquivalent: ""); it.submenu = m
        return it
    }
    @objc func toggleHUD() { ctl.config.set("hud", !ctl.config.bool("hud", true)) }
    @objc func previewHUD() { ctl.previewHUD() }
    @objc func setHUDOption(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [String] else { return }
        ctl.config.set(kv[0], kv[1])
        ctl.hud.show(.rec)  // показать, как выглядит
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if self.ctl.state != .recording { self.ctl.hud.hide() } }
    }
    @objc func toggleCommands() { ctl.config.set("commands", !ctl.config.bool("commands", true)) }
    @objc func showCommands() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Голосовые команды"
        a.informativeText = "Целой фразой или в конце диктовки («…, отправь»):\n\n" + ctl.commands.describeAll()
        a.addButton(withTitle: "OK")
        a.runModal()
    }
    @objc func openCommands() {
        ctl.commands.ensureFile()
        NSWorkspace.shared.open(ctl.commands.url)
    }
    @objc func toggleMic() { ctl.setMicOnDemand(!ctl.micOnDemand) }
    @objc func useSwift() { ctl.switchFromPython(true) }
    @objc func usePython() { ctl.switchFromPython(false) }
    @objc func requestPermission(_ s: NSMenuItem) {
        (s.representedObject as? Permission)?.request { self.ctl.refresh() }
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { log("Запуск при входе: \(error.localizedDescription)") }
    }
    @objc func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open '\(Bundle.main.bundlePath)'"]
        try? p.run()
        NSApp.terminate(nil)
    }
    @objc func openData() { NSWorkspace.shared.open(Setup.data) }
    @objc func openLog() { NSWorkspace.shared.open(Setup.data.appendingPathComponent("dictate.log")) }
}

// MARK: - Служебные режимы командной строки (проверка без микрофона)

let args = CommandLine.arguments
if args.count > 1 && args[1].hasPrefix("--") {
    Setup.prepareDataDir()
    let cfg = Config(url: Setup.data.appendingPathComponent("config.json"))
    switch args[1] {
    case "--convert":  // --convert [repo] — перегнать модель из кэша Python-версии
        let repo = args.count > 2 ? args[2] : cfg.asrModel
        do { print(try Setup.ensureModel(repo: repo).path) } catch { print("ошибка: \(error.localizedDescription)"); exit(1) }
    case "--transcribe":  // --transcribe manifest.json audioDir out.jsonl [dataDir] — путь приложения на корпусе
        struct Row: Decodable { let id: Int; let app: String }
        let dataDir = args.count > 5 ? URL(fileURLWithPath: args[5]) : Setup.data
        let rows = try! JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let profCfg = Config(url: dataDir.appendingPathComponent("config.json"))
        let terms = Terms(dataDir: dataDir)
        let e = try! WhisperEngine(modelPath: Setup.ensureModel(repo: cfg.asrModel).path)
        let vad = try? VAD(modelPath: Setup.vadModel.path)
        FileManager.default.createFile(atPath: args[4], contents: nil)
        let fh = try! FileHandle(forWritingTo: URL(fileURLWithPath: args[4]))
        for r in rows {
            var audio = try! WAV.read(URL(fileURLWithPath: "\(args[3])/\(r.id).wav"))
            if let vad {  // как в приложении: нет речи — пусто, есть — обрезать края
                let sp = e.queue.sync { vad.spans(audio) }
                if let f = sp.first, let l = sp.last {
                    let a = max(0, Int((f.0 - 0.25) * 16000)), b = min(audio.count, Int((l.1 + 0.1) * 16000))
                    if b > a { audio = Array(audio[a..<b]) }
                } else { audio = [] }
            }
            let layer = terms.layer(for: r.app, profiles: profCfg.termsProfiles, defaultLayer: profCfg.defaultTerms)
            if audio.isEmpty {
                fh.write(try! JSONSerialization.data(withJSONObject: ["id": r.id, "sec": 0, "dur": 0, "text": "", "raw": "", "prompt": ""]))
                fh.write("\n".data(using: .utf8)!); continue
            }
            let res = e.queue.sync { () -> (WhisperEngine.Result, String, String) in
                let hint = terms.hint(layer: layer, count: e.tokenCount)
                let res = e.run(audio, language: cfg.asrLanguage, prompt: hint)
                return (res, TextClean.stripLoops(res.text, segments: res.segments).0, hint)
            }
            let obj: [String: Any] = ["id": r.id, "sec": res.0.ms / 1000, "dur": Double(audio.count) / 16000,
                                      "text": res.1, "raw": res.0.text, "prompt": res.2]
            fh.write(try! JSONSerialization.data(withJSONObject: obj)); fh.write("\n".data(using: .utf8)!)
        }
        try! fh.close()
    case "--hud-preview":  // --hud-preview out.png — все значки и размеры капсулы на одной картинке
        _ = NSApplication.shared
        let tmp = Config(url: URL(fileURLWithPath: NSTemporaryDirectory() + "hud-preview.json"))
        let hud = HUD(config: tmp)
        for v: Float in [0.01, 0.03, 0.06, 0.04, 0.08, 0.05] { hud.pushLevel(v) }
        let rows: [(String, String, String, HUD.Mode)] = HUD.icons.map { ($0.0, "small", "dark", .rec) }
            + [("bars", "tiny", "dark", .rec), ("bars", "normal", "dark", .rec), ("bars", "small", "light", .rec), ("bars", "small", "dark", .busy)]
        let W: CGFloat = 120, H: CGFloat = 44
        let img = NSImage(size: NSSize(width: W, height: H * CGFloat(rows.count)))
        img.lockFocus()
        NSColor.gray.setFill(); NSRect(x: 0, y: 0, width: W, height: H * CGFloat(rows.count)).fill()
        for (i, (icon, size, bg, mode)) in rows.enumerated() {
            tmp.set("hud_icon", icon); tmp.set("hud_size", size); tmp.set("hud_bg", bg)
            hud.previewMode = mode
            let sz = HUD.sizes.first { $0.0 == size }!.2
            let v = HUDView(frame: NSRect(origin: .zero, size: sz)); v.hud = hud
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            rep.draw(in: NSRect(x: (W - sz.width) / 2, y: H * CGFloat(rows.count - 1 - i) + (H - sz.height) / 2, width: sz.width, height: sz.height))
        }
        img.unlockFocus()
        try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
    case "--window-preview":  // --window-preview status|models out.png — окно в картинку (проверка вёрстки)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if args[2] == "models2" {  // новое окно «Модели» (SwiftUI): обе вкладки, светлая и тёмная тема
            let d = AppDelegate(); d.ctl = Controller()
            let store = ModelsStore(app: d)
            MainActor.assumeIsolated {
            for (tab, scheme, suffix) in [(0, ColorScheme.light, "asr-light"), (1, ColorScheme.light, "llm-light"), (0, ColorScheme.dark, "asr-dark")] {
                let v = ModelsView(store: store, tab: tab, preview: true).frame(width: 780).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let r = ImageRenderer(content: v); r.scale = 1.5
                if let img = r.nsImage, let t = img.tiffRepresentation {
                    try! NSBitmapImageRep(data: t)!.representation(using: .png, properties: [:])!
                        .write(to: URL(fileURLWithPath: args[3].replacingOccurrences(of: ".png", with: "-\(suffix).png")))
                }
            }
            }
            exit(0)
        }
        if args[2] == "models3" {  // настоящее окно за экраном → снимок (кнопки и переключатель — системные)
            let d = AppDelegate(); d.ctl = Controller()
            let store = ModelsStore(app: d)
            let w = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 780, height: 980), styleMask: [.titled], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: args.count > 4 ? .darkAqua : .aqua)
            w.contentView = NSHostingView(rootView: ModelsView(store: store, tab: args.count > 5 ? 1 : 0))
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let v = w.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
            exit(0)
        }
        if args[2] == "review" {
            let r = ReviewWindow()
            _ = r.show([.init(key: "raw", title: "Как сказано · сырой Whisper", text: "ну короче надо еще раз проверить все ли работает"),
                        .init(key: "clean", title: "Чистка (по умолчанию) · обычный результат", text: "Надо ещё раз проверить, всё ли работает."),
                        .init(key: "formal", title: "Строгий (письменный)", text: "Необходимо ещё раз проверить, всё ли работает."),
                        .init(key: "brief", title: "Кратко (сжать до сути)", text: nil)], onPick: { _, _ in }, onCancel: {})
            let win = NSApp.windows.first { $0.title == "Что вставить?" }!
            win.appearance = NSAppearance(named: .aqua)
            win.contentView!.layoutSubtreeIfNeeded()
            try! win.contentView!.dataWithPDF(inside: win.contentView!.bounds).write(to: URL(fileURLWithPath: args[3]))
            exit(0)
        }
        let d = AppDelegate()
        d.ctl = Controller()
        let w = args[2] == "models"
            ? GridWindow(title: "Dictate — модели", width: 720, snapshot: { d.modelsSnapshot() }, onAction: { _ in })
            : GridWindow(title: "Dictate — состояние", snapshot: { d.statusSnapshot() }, onAction: { _ in })
        w.window.appearance = NSAppearance(named: .aqua)  // в PDF нет фона окна: светлая тема, чтобы текст был виден
        w.refresh()
        w.window.setFrame(NSRect(x: 0, y: 0, width: args[2] == "models" ? 720 : 640, height: 900), display: true)
        w.window.contentView?.layoutSubtreeIfNeeded()
        let v = w.window.contentView!
        try! v.dataWithPDF(inside: v.bounds).write(to: URL(fileURLWithPath: args[3]))
    case "--vad":  // --vad a.wav b.wav … — отрезки речи (проверка единиц и порога)
        let v = try! VAD(modelPath: Setup.vadModel.path)
        for f in args.dropFirst(2) {
            let a = try! WAV.read(URL(fileURLWithPath: f))
            print(String(format: "%@ %.2f с: ", (f as NSString).lastPathComponent, Double(a.count) / 16000)
                  + v.spans(a).map { String(format: "%.2f–%.2f", $0.0, $0.1) }.joined(separator: ", "))
        }
    case "--guard":  // --guard pairs.json — пост-контроль на парах {raw, out, terms[]} (сверка с Python-версией)
        let pairs = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
        for p in pairs {
            let r = Styles.guardCorrection(raw: p["raw"] as! String, out: p["out"] as! String, terms: Set(p["terms"] as! [String]))
            print(r.replacingOccurrences(of: "\n", with: "⏎"))
        }
    case "--clean":  // --clean [repo] — чистка нескольких фраз (проверка MLX внутри .app)
        let repo = args.count > 2 ? args[2] : cfg.string("llm_model", "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        let cl = Cleaner()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                try await cl.load(repo: repo)
                for raw in ["ну короче надо еще раз проверить все ли работает и вернутся к вопросу завтра",
                            "эээ я вчера ее видел она говорила что все хорошо", "проверь зиро тир на мини пожалуйста"] {
                    let (out, st) = try await cl.run(system: Styles.systemPrompt(terms: "ZeroTier, Mac mini"), user: raw)
                    let g = Styles.guardCorrection(raw: raw, out: Styles.checkEnhance(out, raw: raw), terms: ["zerotier", "mac mini"])
                    print(String(format: "%.0f мс · %.0f т/с · %@ → %@", st.ms, st.tps, raw, g))
                }
            } catch { print("ошибка: \(error)") }
            sem.signal()
        }
        sem.wait()
    case "--render":  // --render rows.json out.jsonl — стиль clean на парах {id, raw, terms} (сверка с историей Python-версии)
        let rows = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
        _ = NSApplication.shared
        let ctl = Controller()
        let sem = DispatchSemaphore(value: 0)
        FileManager.default.createFile(atPath: args[3], contents: nil)
        let fh = try! FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))
        Task {
            try? await ctl.cleaner.load(repo: ctl.config.llmModel)
            for r in rows {
                let raw = r["raw"] as! String
                let (out, st) = await ctl.render(style: r["style"] as? String ?? "clean", raw: raw, doubtful: [], termsText: r["terms"] as! String)
                let o: [String: Any] = ["id": r["id"]!, "out": Styles.polish(style: "clean", out), "ms": st.ms]
                fh.write(try! JSONSerialization.data(withJSONObject: o)); fh.write("\n".data(using: .utf8)!)
            }
            sem.signal()
        }
        sem.wait()
    case "--autoterms":  // --autoterms history.sqlite3 terms.txt — автослой словаря (сверка с Python-версией)
        let rows = History.readRows(path: args[2]).map { (raw: $0.raw, text: $0.text) }
        let known = Set(((try? String(contentsOfFile: args[3], encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { $0.lowercased() })
        print(AutoTerms.build(rows: rows, known: known).joined(separator: "\n"))
    case "--dashboard":  // --dashboard stats|search out.html [history.sqlite3] — страница истории
        let tpl = try! String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("dashboard/template.html"), encoding: .utf8)
        let rows = History.readRows(path: args.count > 4 ? args[4] : Setup.data.appendingPathComponent("history.sqlite3").path)
        try! Dashboard.build(active: args[2], rows: rows, dict: HistoryTools.dictSizes(), audioIDs: [], template: tpl)
            .write(toFile: args[3], atomically: true, encoding: .utf8)
    case "--check-signer":  // --check-signer path.app — примет ли автообновление это приложение (та же подпись?)
        do { try Updater(config: cfg).verifySameSigner(URL(fileURLWithPath: args[2])); print("ПРИНЯТО: подпись та же") }
        catch { print("ОТКЛОНЕНО: \((error as? Updater.Fail)?.why ?? "\(error)")") }
    case "--vp-test":  // --vp-test enroll.wav... -- probe.wav... — отпечаток из первых, сходство вторых
        let files = Array(args.dropFirst(2)); let sep = files.firstIndex(of: "--") ?? files.count
        let v = VoicePrint(), vad = try! VAD(modelPath: Setup.vadModel.path)
        func speech(_ f: String) -> [Float] {
            let a = try! WAV.read(URL(fileURLWithPath: f))
            return vad.spans(a).flatMap { sp -> [Float] in let x = max(0, Int(sp.0 * 16000)), y = min(a.count, Int(sp.1 * 16000)); return y > x ? Array(a[x..<y]) : [] }
        }
        let sem = DispatchSemaphore(value: 0)
        Task {
            _ = try! await v.ensureModel()
            let p = try! v.make(speech: files[..<sep].flatMap(speech), device: "test")
            print(String(format: "отпечаток: %.0f с речи, окон %d, само-похожесть %.2f…%.2f, порог %.2f", p.speechSec, p.windows, p.selfMin, p.selfMean, p.threshold))
            for f in files.dropFirst(sep + 1) {
                let sp = speech(f)
                let sim = sp.count >= 16000 ? (try? v.embed(sp)).map { VoicePrint.dot($0, p.vec) } : nil
                print(String(format: "%@ %.1f с речи: %@", (f as NSString).lastPathComponent, Double(sp.count) / 16000, sim.map { String(format: "%.2f", $0) } ?? "—"))
            }
            sem.signal()
        }
        sem.wait()
    case "--apple-test":  // --apple-test a.wav … — встроенный распознаватель тем же путём, что в приложении
        guard #available(macOS 26.0, *) else { print("нужна macOS 26+"); exit(1) }
        let a = AppleEngine(language: cfg.asrLanguage)
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                print(try await a.install())
                for f in args.dropFirst(2) {
                    let (t, ms) = try await a.transcribe(try WAV.read(URL(fileURLWithPath: f)), terms: ["GitHub", "API", "Mattermost", "push", "commit"])
                    print(String(format: "%@ %.0f мс: %@", (f as NSString).lastPathComponent, ms, t))
                }
            } catch { print("ошибка: \(error)") }
            sem.signal()
        }
        sem.wait()
    case "--llm-run":  // --llm-run set.json out.jsonl repo — чистка «clean» как в приложении: промпт → LLM → защита → пост-контроль
        let rows = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
        let repo = args[4]
        let cl = Cleaner()
        let sem = DispatchSemaphore(value: 0)
        FileManager.default.createFile(atPath: args[3], contents: nil)
        let fh = try! FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))
        Task {
            do {
                try await cl.load(repo: repo)
                _ = try await cl.run(system: "Ты корректор.", user: "прогрев")
                for r in rows {
                    let raw = r["raw"] as! String
                    let (llm, st) = try await cl.run(system: r["system"] as! String, user: raw)
                    let checked = Styles.checkEnhance(llm, raw: raw)
                    let tl = Set((r["terms"] as! String).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                    let guarded = Styles.guardCorrection(raw: raw, out: checked, terms: tl)
                    let o: [String: Any] = ["key": r["key"]!, "llm_raw": llm, "out": Styles.polish(style: "clean", guarded), "ms": st.ms,
                                            "tps": st.tps, "tokens": st.genTokens, "rolled_back": guarded != checked, "degraded": checked != llm]
                    fh.write(try JSONSerialization.data(withJSONObject: o)); fh.write("\n".data(using: .utf8)!)
                }
            } catch { print("ошибка: \(error)") }
            sem.signal()
        }
        sem.wait()
    case "--guard-set":  // --guard-set set.json llm.jsonl out.jsonl — пост-контроль к готовым ответам LLM (LFM3 из Python)
        let rows = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
        var byKey: [String: [String: Any]] = [:]
        for r in rows { byKey[r["key"] as! String] = r }
        FileManager.default.createFile(atPath: args[4], contents: nil)
        let fh = try! FileHandle(forWritingTo: URL(fileURLWithPath: args[4]))
        for line in try! String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n") {
            var o = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let r = byKey[o["key"] as! String]!, raw = r["raw"] as! String, llm = o["llm_raw"] as! String
            let checked = Styles.checkEnhance(llm, raw: raw)
            let tl = Set((r["terms"] as! String).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            let guarded = Styles.guardCorrection(raw: raw, out: checked, terms: tl)
            o["out"] = Styles.polish(style: "clean", guarded); o["rolled_back"] = guarded != checked; o["degraded"] = checked != llm
            fh.write(try! JSONSerialization.data(withJSONObject: o)); fh.write("\n".data(using: .utf8)!)
        }
    case "--parakeet-test":  // --parakeet-test repo a.wav … — Parakeet тем же путём, что в приложении
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let e = try await ParakeetEngine.load(repo: args[2])
                for f in args.dropFirst(3) {
                    let (t, ms) = try await e.transcribe(try WAV.read(URL(fileURLWithPath: f)), language: "ru")
                    print(String(format: "%@ %.0f мс: %@", (f as NSString).lastPathComponent, ms, t))
                }
            } catch { print("ошибка: \(error)") }
            sem.signal()
        }
        sem.wait()
    case "--menu-dump":  // дерево меню текстом (проверка порядка)
        _ = NSApplication.shared
        let d = AppDelegate(); d.ctl = Controller(); d.updater = Updater(config: d.ctl.config)
        let m = NSMenu(); d.menuNeedsUpdate(m)
        func dump(_ m: NSMenu, _ ind: String) {
            for it in m.items {
                if it.isSeparatorItem { print(ind + "────────"); continue }
                print(ind + (it.state == .on ? "✓ " : "  ") + it.title + (it.submenu != nil ? "  ▸" : ""))
                if let sm = it.submenu { dump(sm, ind + "      ") }
            }
        }
        dump(m, "")
    case "--match":  // --match file.txt — разбор голосовых команд по строкам (сверка с Python-версией)
        let c = DictateCore.Commands(url: Setup.data.appendingPathComponent("commands.json"))
        for line in (try! String(contentsOfFile: args[2], encoding: .utf8)).split(separator: "\n", omittingEmptySubsequences: false) {
            let m = c.match(String(line))
            print(m.map { "\($0.id)|\($0.head)" } ?? "-")
        }
    default:
        print("режимы: --convert [repo], --transcribe manifest audioDir out.jsonl [dataDir]")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
