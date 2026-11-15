import DictateCore
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// LLM-чистка и стили на MLX — модели из кэша Python-версии (~/.cache/huggingface) как есть.
/// Модель грузится по требованию и (галка unload_llm) выгружается после llm_idle_min минут простоя.
final class Cleaner: @unchecked Sendable {
    struct Stats: Sendable { var genTokens = 0; var tps = 0.0; var ms = 0.0 }
    struct Out: Sendable { let text: String; let tokens: Int; let tps: Double }

    private var container: ModelContainer?
    private(set) var repo: String?
    private(set) var loading = false
    private(set) var lastUse = Date()
    private let lock = NSLock()

    var loaded: Bool { lock.lock(); defer { lock.unlock() }; return container != nil }

    func load(repo: String) async throws {
        lock.lock()
        if container != nil && self.repo == repo { lock.unlock(); return }
        loading = true
        lock.unlock()
        defer { lock.lock(); loading = false; lock.unlock() }
        guard let dir = MLXConverter.cachedModel(repo: repo) else {
            throw NSError(domain: "Cleaner", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "модели чистки \(repo) нет в кэше ~/.cache/huggingface — скачайте её (окно «Модели»)"])
        }
        let t = Date()
        let c = try await LLMModelFactory.shared.loadContainer(from: dir, using: #huggingFaceTokenizerLoader())
        lock.lock(); container = c; self.repo = repo; lastUse = Date(); lock.unlock()
        log(String(format: "Чистка: %@ загружена за %.1f с", repo.split(separator: "/").last.map(String.init) ?? repo, Date().timeIntervalSince(t)))
    }

    func unload(_ why: String) {
        lock.lock(); let had = container != nil; container = nil; lock.unlock()
        guard had else { return }
        Memory.clearCache()
        log("Чистка: модель выгружена (\(why))")
    }

    /// system + user → ответ модели (жадно, без «думания»). maxFactor — бюджет токенов от длины user, как в Python.
    func run(system: String, user: String, maxFactor: Int = 2) async throws -> (String, Stats) {
        guard let c = { lock.lock(); defer { lock.unlock() }; return container }() else {
            throw NSError(domain: "Cleaner", code: 2, userInfo: [NSLocalizedDescriptionKey: "модель чистки не загружена"])
        }
        lastUse = Date()
        let t = Date()
        let out: Out = try await c.perform { (context: ModelContext) async throws -> Out in
            let userInput = UserInput(chat: [Chat.Message.system(system), Chat.Message.user(user)],
                                      additionalContext: ["enable_thinking": false])
            let input: LMInput = try await context.processor.prepare(input: userInput)
            let maxTokens: Int = context.tokenizer.encode(text: user).count * maxFactor + 40
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
            let r: GenerateResult = try MLXLMCommon.generate(input: input, parameters: params, context: context) {
                (_: [Int]) -> GenerateDisposition in .more
            }
            return Out(text: r.output, tokens: r.tokenIds.count, tps: r.tokensPerSecond)
        }
        let text = out.text
        let stats = Stats(genTokens: out.tokens, tps: out.tps, ms: 0)
        var s = stats; s.ms = Date().timeIntervalSince(t) * 1000
        lastUse = Date()
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), s)
    }
}
