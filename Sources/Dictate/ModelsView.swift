import AppKit
import DictateCore
import FluidAudio
import SwiftUI

/// Окно «Модели» — карточки по ролям (распознавание / чистка): что это, цифры сравнения 14.11, состояние, одна
/// главная кнопка; «⋯» — Finder, удаление копии, страница на Hugging Face. Обновляется раз в секунду (прогресс закачки).
final class ModelsStore: ObservableObject {
    struct Card: Identifiable {
        var id: String { model.repo }
        let model: Catalog.Model
        let state: String       // «Активна», «Скачана · 1,6 ГБ», «Не скачана · ~630 МБ», «Качается 34 %»
        let active: Bool
        let action: String?     // «Выбрать» / «Скачать» / nil
        let actionKey: String?
        let hasCopy: Bool       // есть перегнанная копия ggml (можно удалить)
    }

    @Published var asr: [Card] = []
    @Published var llm: [Card] = []
    @Published var summary = ""
    weak var app: AppDelegate?
    private var timer: Timer?

    init(app: AppDelegate) {
        self.app = app
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard let app, let ctl = app.ctl else { return }
        let activeASR = ctl.config.asrModel, activeLLM = ctl.config.llmModel
        if #available(macOS 26.0, *) { let lang = ctl.config.asrLanguage; Task.detached { Catalog.appleInstalled = await AppleEngine.installed(lang) } }
        asr = Catalog.asr.map { m in
            let st = Catalog.status(m, active: activeASR)
            let progress = Downloader.shared.progress[m.repo]
            let copy = m.engine == .whisper && m.repo != activeASR && FileManager.default.fileExists(atPath: Setup.ggmlPath(for: m.repo).path)
            var state: String, action: String?, key: String?
            if let progress { state = "Качается: \(progress)"; action = nil; key = nil }
            else if m.repo == activeASR { state = ctl.asrReady ? "Активна · загружена" : "Активна · загружается…"; action = nil; key = nil }
            else if m.engine == .apple { state = Catalog.appleInstalled == true ? "Встроена в macOS" : "Встроена в macOS · модель скачает система"; action = "Выбрать"; key = "act:\(m.repo)" }
            else if m.engine == .parakeet && m.repo == ParakeetEngine.ultra { state = st.cached ? "Скачана" : "Скачается при выборе · ~630 МБ"; action = "Выбрать"; key = "act:\(m.repo)" }
            else if st.ready || st.cached { state = st.ready ? "Скачана" + (copy ? " · \(Catalog.mb(Setup.ggmlPath(for: m.repo)))" : "") : "Скачана · при выборе перегонится за секунды"; action = "Выбрать"; key = "act:\(m.repo)" }
            else { state = "Не скачана · ~\(Catalog.size(m.mb))"; action = "Скачать"; key = "dl:\(m.repo)" }
            return Card(model: m, state: state, active: m.repo == activeASR, action: action, actionKey: key, hasCopy: copy)
        }
        llm = Catalog.llm.map { m in
            let progress = Downloader.shared.progress[m.repo]
            let cached = MLXConverter.cachedModel(repo: m.repo) != nil
            var state: String, action: String?, key: String?
            if let progress { state = "Качается: \(progress)"; action = nil; key = nil }
            else if m.repo == activeLLM { state = ctl.cleaner.loaded ? "Активна · в памяти" : ctl.cleaner.loading ? "Активна · загружается…" : "Активна · загрузится при первой чистке"; action = nil; key = nil }
            else if !m.available { state = cached ? "Скачана · пока недоступна" : "Пока недоступна"; action = nil; key = nil }
            else if cached { state = "Скачана"; action = "Выбрать"; key = "llm:\(m.repo)" }
            else { state = "Не скачана · ~\(Catalog.size(m.mb))"; action = "Скачать"; key = "dl:\(m.repo)" }
            return Card(model: m, state: state, active: m.repo == activeLLM, action: action, actionKey: key, hasCopy: false)
        }
        // активная модель — всегда первой, остальные в порядке каталога
        asr = asr.filter(\.active) + asr.filter { !$0.active }
        llm = llm.filter(\.active) + llm.filter { !$0.active }
        let a = Catalog.allASR.first { $0.repo == activeASR }?.name ?? String(activeASR.split(separator: "/").last ?? "")
        let l = Catalog.llm.first { $0.repo == activeLLM }?.name ?? String(activeLLM.split(separator: "/").last ?? "")
        summary = "Сейчас: распознавание — \(a), чистка — \(l)" + (ctl.config.enhance ? "" : " (выключена)")
    }

    func run(_ key: String) { app?.handle(key); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() } }
}

struct ModelsView: View {
    @ObservedObject var store: ModelsStore
    @State var tab = 0
    var preview = false  // снимок для проверки вёрстки: без прокрутки

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $tab) {
                    Text("Распознавание речи").tag(0)
                    Text("Чистка текста").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(store.summary).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            Divider()
            if preview { cards } else { ScrollView { cards } }
            Divider()
            HStack(spacing: 12) {
                Text(tab == 0
                     ? "Цифры — сравнение 14.11 на 224 диктовках автора (MacBook Pro M5): время на фразу, расхождение с эталоном large-v3, сколько английских слов из 59 сохранено."
                     : "Цифры — сравнение 14.11 на 150 фразах автора: время правки, сколько поставлено «ё», сколько слов-паразитов убрано из 85.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Сравнение…") { store.run("compare") }
                Button("Папка моделей") { store.run("dir") }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    var cards: some View {
        VStack(spacing: 10) {
            ForEach(tab == 0 ? store.asr : store.llm) { card in
                CardView(card: card, run: store.run)
            }
        }
        .padding(16)
    }
}

struct CardView: View {
    let card: ModelsStore.Card
    let run: (String) -> Void

    var body: some View {
        let m = card.model
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(m.name).font(.headline)
                    if let b = m.badge {
                        Text(b).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15))).foregroundStyle(Color.accentColor)
                    }
                }
                Text(m.role).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    ForEach(Array(m.metrics.enumerated()), id: \.offset) { _, kv in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kv.0).font(.caption2).foregroundStyle(.tertiary)
                            Text(kv.1).font(.callout.monospacedDigit())
                        }
                    }
                }
                .padding(.top, 4)
                HStack(spacing: 5) {
                    Circle().fill(card.active ? Color.green : card.state.hasPrefix("Не скачана") || card.state.hasPrefix("Пока") ? Color.secondary.opacity(0.4) : Color.accentColor.opacity(0.7))
                        .frame(width: 7, height: 7)
                    Text(card.state).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    // управление — иконками, с подсказкой при наведении
                    IconButton(symbol: "folder", help: "Показать в Finder") { run("reveal:\(m.repo)") }
                    IconButton(symbol: "trash", help: card.hasCopy ? "Удалить перегнанную копию (исходник в кэше остаётся)" : "Удалять нечего: перегнанной копии нет",
                               enabled: card.hasCopy) { run("rm:\(m.repo)") }
                    if !m.repo.hasPrefix("apple/") {
                        IconButton(symbol: "globe", help: "Открыть страницу модели на Hugging Face") { run("hf:\(m.repo)") }
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing) {
                if card.active {
                    Label("Активна", systemImage: "checkmark.circle.fill").font(.callout.weight(.medium)).foregroundStyle(.green)
                } else if let a = card.action, let k = card.actionKey {
                    Button { run(k) } label: {
                        Label(a, systemImage: a == "Скачать" ? "arrow.down.circle" : "checkmark.circle")
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent).disabled(!m.available)
                    .help(a == "Скачать" ? "Скачать модель в кэш Hugging Face" : "Сделать эту модель активной")
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(card.active ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: card.active ? 2 : 1))
        .opacity(m.available ? 1 : 0.6)
    }
}

/// Иконка-кнопка карточки: без рамки, с подсказкой; неактивная — приглушена.
struct IconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
        .help(help)
    }
}
