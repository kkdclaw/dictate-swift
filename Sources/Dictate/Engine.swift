import DictateCore
import Foundation
import whisper

/// whisper.cpp: модель ggml, подсказка-словарь через initial_prompt — как mlx_whisper.transcribe в Python-версии.
/// Контекст не потокобезопасен — все вызовы на своей очереди.
final class WhisperEngine {
    let modelPath: String
    let queue = DispatchQueue(label: "asr", qos: .userInitiated)
    private var ctx: OpaquePointer?

    struct Result {
        var text: String
        var segments: [Segment]
        var ms: Double
        var words: [Styles.Word] = []  // слова с вероятностью (среднее по токенам) — для «сомнений»
    }

    init(modelPath: String) throws {
        self.modelPath = modelPath
        whisper_log_set({ _, _, _ in }, nil)
        var cp = whisper_context_default_params()
        cp.use_gpu = true
        cp.flash_attn = true
        guard let c = whisper_init_from_file_with_params(modelPath, cp) else {
            throw NSError(domain: "Engine", code: 1, userInfo: [NSLocalizedDescriptionKey: "модель не загрузилась: \(modelPath)"])
        }
        ctx = c
        _ = run([Float](repeating: 0, count: 8000), language: "ru", prompt: nil)  // прогрев: первый вызов компилирует ядра Metal
    }

    deinit { if let ctx { whisper_free(ctx) } }

    /// Длина текста в токенах Whisper — для бюджета словаря. Вызывать на queue.
    func tokenCount(_ s: String) -> Int {
        guard let ctx else { return s.count / 3 }
        let n = whisper_tokenize(ctx, s, nil, 0)
        return n < 0 ? Int(-n) : Int(n)
    }

    /// Распознать (вызывать на queue).
    func run(_ audio: [Float], language: String, prompt: String?) -> Result {
        guard let ctx else { return Result(text: "", segments: [], ms: 0) }
        let t0 = Date()
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.print_progress = false; p.print_realtime = false; p.print_timestamps = false; p.print_special = false
        p.n_threads = 4
        p.no_context = true
        let lang = strdup(language.isEmpty ? "auto" : language); defer { free(lang) }
        p.language = UnsafePointer(lang)
        let pr = prompt.flatMap { $0.isEmpty ? nil : strdup($0) }; defer { if let pr { free(pr) } }
        if let pr { p.initial_prompt = UnsafePointer(pr) }
        let rc = audio.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
        let ms = Date().timeIntervalSince(t0) * 1000
        guard rc == 0 else { return Result(text: "", segments: [], ms: ms) }
        var segs: [Segment] = [], text = "", words: [Styles.Word] = []
        var cur = "", probs: [Double] = []
        func flush() {
            if !cur.trimmingCharacters(in: .whitespaces).isEmpty, !probs.isEmpty {
                words.append(Styles.Word(text: cur, prob: probs.reduce(0, +) / Double(probs.count)))
            }
            cur = ""; probs = []
        }
        for i in 0..<whisper_full_n_segments(ctx) {
            for j in 0..<whisper_full_n_tokens(ctx, i) {
                let td = whisper_full_get_token_data(ctx, i, j)
                guard td.id < whisper_token_eot(ctx), let cs = whisper_full_get_token_text(ctx, i, j) else { continue }
                let t = String(cString: cs)
                if t.hasPrefix(" ") { flush() }  // слово начинается с пробела
                cur += t; probs.append(Double(td.p))
            }
            let s = String(cString: whisper_full_get_segment_text(ctx, i))
            let n = whisper_full_n_tokens(ctx, i)
            var lp = 0.0, k = 0
            for j in 0..<n {
                let td = whisper_full_get_token_data(ctx, i, j)
                if td.id < whisper_token_eot(ctx) { lp += Double(td.plog); k += 1 }
            }
            segs.append(Segment(text: s,
                                start: Double(whisper_full_get_segment_t0(ctx, i)) / 100,
                                end: Double(whisper_full_get_segment_t1(ctx, i)) / 100,
                                noSpeechProb: 0, avgLogprob: k > 0 ? lp / Double(k) : 0))
            text += s
        }
        flush()
        return Result(text: text.trimmingCharacters(in: .whitespaces), segments: segs, ms: ms, words: words)
    }
}

/// Детектор речи Silero (v6.2, как у Python-версии): есть ли речь и где её края. Порог 0.35, отступ 150 мс.
/// Запись без речи не распознаётся вовсе (иначе Whisper пишет «ДИНАМИЧНАЯ МУЗЫКА» на тишине),
/// у записи с речью обрезаются только края: 0,25 с до первой речи и 0,1 с после последней.
final class VAD {
    private var ctx: OpaquePointer?

    init(modelPath: String) throws {
        var cp = whisper_vad_default_context_params()
        cp.n_threads = 2
        cp.use_gpu = false
        guard let c = whisper_vad_init_from_file_with_params(modelPath, cp) else {
            throw NSError(domain: "VAD", code: 1, userInfo: [NSLocalizedDescriptionKey: "модель VAD не загрузилась: \(modelPath)"])
        }
        ctx = c
    }

    deinit { if let ctx { whisper_vad_free(ctx) } }

    /// Отрезки речи в секундах (вызывать на очереди распознавания).
    func spans(_ audio: [Float]) -> [(Double, Double)] {
        guard let ctx, !audio.isEmpty else { return [] }
        var p = whisper_vad_default_params()
        let env = ProcessInfo.processInfo.environment
        p.threshold = Float(env["VAD_THRESHOLD"] ?? "") ?? 0.35
        p.speech_pad_ms = 150
        p.min_speech_duration_ms = Int32(env["VAD_MIN_SPEECH_MS"] ?? "") ?? 250
        p.min_silence_duration_ms = 100
        guard let segs = audio.withUnsafeBufferPointer({ whisper_vad_segments_from_samples(ctx, p, $0.baseAddress, Int32($0.count)) })
        else { return [] }
        defer { whisper_vad_free_segments(segs) }
        return (0..<whisper_vad_segments_n_segments(segs)).map {
            (Double(whisper_vad_segments_get_segment_t0(segs, $0)) / 100, Double(whisper_vad_segments_get_segment_t1(segs, $0)) / 100)
        }
    }
}
