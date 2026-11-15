import Foundation

/// Автослой словаря auto_terms.txt — порт suggest_terms.build_auto_terms (llm_run=None, как в Python-версии:
/// отбор жаргона 4B-моделью тянул обычные слова). Источники: латиница в русской речи (≥ 2 диктовок) и
/// устоявшиеся исправления LLM-чистки (≥ 2 раз). Зацикливания распознавания в расчёт не идут. Потолок — 40.
public enum AutoTerms {
    static let fillers: Set<String> = ["эээ", "эм", "ну", "короче", "м", "m", "типа", "мда", "в", "общем",
                                       "как", "бы", "это", "самое", "значит"]
    static let wordRE = try! NSRegularExpression(pattern: #"[\w-]+"#)
    static let latRE = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9-]{2,}"#)

    static func find(_ re: NSRegularExpression, _ s: String) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Одно слово занимает пол-фразы — зацикливание (галлюцинация → словарь → галлюцинация).
    public static func degenerate(_ text: String) -> Bool {
        let ws = find(wordRE, text).map { $0.lowercased() }
        guard ws.count >= 8 else { return false }
        let top = Dictionary(ws.map { ($0, 1) }, uniquingKeysWith: +).values.max() ?? 0
        return top >= 8 && Double(top) >= Double(ws.count) * 0.4
    }

    /// Пары (сырое → чистое) из пословного диффа: только замены, не регистр, не паразиты, созвучные (≥ 0,5).
    public static func correctionPairs(raw: String, clean: String) -> [(String, String)] {
        let a = find(wordRE, raw), b = find(wordRE, clean)
        var out: [(String, String)] = []
        for (op, i1, i2, j1, j2) in SequenceMatcher(a.map { $0.lowercased() }, b.map { $0.lowercased() }).opcodes() where op == "replace" {
            let src = a[i1..<i2].joined(separator: " "), dst = b[j1..<j2].joined(separator: " ")
            if src.lowercased() == dst.lowercased() { continue }
            if find(wordRE, src).allSatisfy({ fillers.contains($0.lowercased()) }) { continue }
            if SequenceMatcher(Array(src.lowercased()).map(String.init), Array(dst.lowercased()).map(String.init)).ratio() < 0.5 { continue }
            out.append((src, dst))
        }
        return out
    }

    /// rows — (raw_text, text) истории; known — слова ручного словаря (нижний регистр).
    public static func build(rows: [(raw: String, text: String)], known: Set<String>, cap: Int = 40) -> [String] {
        let raws = rows.map(\.raw).filter { !$0.isEmpty && !degenerate($0) }
        var picked: [String] = [], seen = Set<String>()
        func add(_ w: String) {
            let l = w.lowercased()
            if !w.isEmpty && !known.contains(l) && !seen.contains(l) { picked.append(w); seen.insert(l) }
        }
        // 1) латиница: один раз на диктовку, берём встреченное в ≥ 2 диктовках (порядок — как Counter.most_common)
        var lat: [String: (Int, Int)] = [:], order = 0
        for t in raws {
            for w in Set(find(latRE, t)) { let c = lat[w] ?? (0, order); lat[w] = (c.0 + 1, c.1); order += 1 }
        }
        for (w, _) in lat.sorted(by: { $0.value.0 != $1.value.0 ? $0.value.0 > $1.value.0 : $0.value.1 < $1.value.1 }) where lat[w]!.0 >= 2 {
            add(w)
        }
        // 2) устоявшиеся исправления чистки (≥ 2 раз, не длиннее двух слов, ≥ 3 букв)
        var counts: [String: (n: Int, first: Int, dst: String)] = [:]; order = 0
        for r in rows where r.raw != r.text && !degenerate(r.raw) {
            for (src, dst) in correctionPairs(raw: r.raw, clean: r.text) {
                let k = src.lowercased() + "\u{1}" + dst
                let c = counts[k] ?? (0, order, dst); counts[k] = (c.n + 1, c.first, dst); order += 1
            }
        }
        for (_, v) in counts.sorted(by: { $0.value.n != $1.value.n ? $0.value.n > $1.value.n : $0.value.first < $1.value.first }) {
            if v.n < 2 || known.contains(v.dst.lowercased()) || v.dst.count < 3 || find(wordRE, v.dst).count > 2 { continue }
            add(v.dst)
        }
        return Array(picked.prefix(cap))
    }
}
