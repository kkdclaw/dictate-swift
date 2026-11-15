import Foundation

/// Страница «Поиск» + «Статистика» — порт dashboard.py: те же подсчёты (compute), те же SVG-графики и тот же
/// шаблон страницы (Resources/dashboard/template.html, извлечён из dashboard.PAGE как есть).
public enum Dashboard {
    static func r0(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }          // round() Python
    static func r1(_ x: Double) -> Double { (x * 10).rounded(.toNearestOrEven) / 10 }  // round(x, 1)
    static func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
    static func num(_ x: Double) -> String { x == x.rounded() && abs(x) < 1e15 ? String(format: "%.1f", x) : "\(x)" }
    static func n1(_ x: Double) -> String { String(format: "%.1f", x) }
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }
    static let wordRE = try! NSRegularExpression(pattern: #"\w+"#)
    static func countWords(_ s: String) -> Int { wordRE.numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) }

    static func day(_ ts: Double) -> String { fmt("yyyy-MM-dd", ts) }
    static func fmt(_ f: String, _ ts: Double) -> String {
        let d = DateFormatter(); d.dateFormat = f; d.locale = Locale(identifier: "en_US_POSIX")
        return d.string(from: Date(timeIntervalSince1970: ts))
    }

    // MARK: SVG

    static func barsH(_ data: [(String, Int)]) -> String {
        guard !data.isEmpty else { return "<p class=\"empty\">нет данных</p>" }
        let mx = Double(data.map(\.1).max() ?? 1), rowh = 26.0, gap = 8.0, labelw = 150.0, valw = 56.0, w = 620.0
        let barw = w - labelw - valw
        var svg = "<svg viewBox=\"0 0 \(Int(w)) \(Int(Double(data.count) * (rowh + gap)))\" class=\"chart\">"
        for (i, (label, val)) in data.enumerated() {
            let y = Double(i) * (rowh + gap), bw = max(3, barw * Double(val) / max(mx, 1))
            svg += "<text x=\"\(num(labelw - 10))\" y=\"\(num(y + rowh / 2 + 4))\" text-anchor=\"end\" class=\"lbl\">\(esc(String(label.prefix(20))))</text>"
            svg += "<rect x=\"\(num(labelw))\" y=\"\(num(y + 2))\" width=\"\(bw)\" height=\"\(num(rowh - 4))\" rx=\"4\" fill=\"var(--series)\"/>"
            svg += "<text x=\"\(labelw + bw + 8)\" y=\"\(num(y + rowh / 2 + 4))\" class=\"val\">\(val)</text>"
        }
        return svg + "</svg>"
    }

    static func timeline(_ byDay: [(String, Int, Int)]) -> String {
        guard !byDay.isEmpty else { return "<p class=\"empty\">нет данных</p>" }
        let w = 620.0, h = 180.0, pad = 28.0, n = Double(byDay.count)
        let mx = Double(max(1, byDay.map(\.1).max() ?? 1))
        let slot = (w - pad) / max(n, 1), bw = min(28, slot * 0.7)
        var svg = "<svg viewBox=\"0 0 \(Int(w)) \(Int(h))\" class=\"chart\">"
        for gy in [0.0, 0.5, 1.0] {
            let yy = pad + (h - 2 * pad) * (1 - gy)
            svg += "<line x1=\"\(Int(pad))\" y1=\"\(yy)\" x2=\"\(Int(w))\" y2=\"\(yy)\" class=\"grid\"/><text x=\"2\" y=\"\(yy + 4)\" class=\"tick\">\(r0(mx * gy))</text>"
        }
        for (i, (d, tot, corr)) in byDay.enumerated() {
            let x = pad + slot * Double(i) + (slot - bw) / 2
            let ht = (h - 2 * pad) * Double(tot) / mx, hc = (h - 2 * pad) * Double(corr) / mx
            svg += "<rect x=\"\(x)\" y=\"\(h - pad - ht)\" width=\"\(bw)\" height=\"\(ht)\" rx=\"4\" fill=\"var(--series2)\"><title>\(d): \(tot) диктовок</title></rect>"
            if corr > 0 { svg += "<rect x=\"\(x)\" y=\"\(h - pad - hc)\" width=\"\(bw)\" height=\"\(hc)\" rx=\"4\" fill=\"var(--accent)\"><title>\(corr) исправлено</title></rect>" }
            if byDay.count <= 20 || i % 2 == 0 {
                let dd = Array(d)
                svg += "<text x=\"\(x + bw / 2)\" y=\"\(h - pad + 14)\" text-anchor=\"middle\" class=\"tick\">\(String(dd[8...9])).\(String(dd[5...6]))</text>"
            }
        }
        return svg + "</svg>"
    }

    static func perfTimeline(_ days: [(String, Double, Double, Int)]) -> String {
        guard !days.isEmpty else { return "<p class=\"empty\">нет замеров</p>" }
        let w = 620.0, h = 180.0, pad = 28.0, n = Double(days.count)
        let mx = max(days.map { max($0.1, $0.2) }.max() ?? 1, 1e-9)
        let slot = (w - pad) / max(n, 1), bw = min(14, slot * 0.36)
        var svg = "<svg viewBox=\"0 0 \(Int(w)) \(Int(h))\" class=\"chart\">"
        for gy in [0.0, 0.5, 1.0] {
            let yy = pad + (h - 2 * pad) * (1 - gy)
            svg += "<line x1=\"\(Int(pad))\" y1=\"\(yy)\" x2=\"\(Int(w))\" y2=\"\(yy)\" class=\"grid\"/><text x=\"2\" y=\"\(yy + 4)\" class=\"tick\">\(r1(mx * gy))</text>"
        }
        for (i, (d, asr, dur, cnt)) in days.enumerated() {
            let x = pad + slot * Double(i) + (slot - 2 * bw - 2) / 2
            let hd = (h - 2 * pad) * dur / mx, ha = (h - 2 * pad) * asr / mx
            let dd = Array(d), dm = "\(String(dd[8...9])).\(String(dd[5...6]))"
            let tip = "\(dm): фраза \(dur) с, распознавание \(asr) с (\(cnt) шт.)"
            svg += "<rect x=\"\(x)\" y=\"\(h - pad - hd)\" width=\"\(bw)\" height=\"\(max(0, hd))\" rx=\"3\" fill=\"var(--series2)\"><title>\(tip)</title></rect>"
            svg += "<rect x=\"\(x + bw + 2)\" y=\"\(h - pad - ha)\" width=\"\(bw)\" height=\"\(max(0, ha))\" rx=\"3\" fill=\"var(--series)\"><title>\(tip)</title></rect>"
            if days.count <= 20 || i % 2 == 0 { svg += "<text x=\"\(x + bw + 1)\" y=\"\(h - pad + 14)\" text-anchor=\"middle\" class=\"tick\">\(dm)</text>" }
        }
        return svg + "</svg>"
    }

    static func hours(_ byHour: [Int]) -> String {
        let w = 620.0, h = 120.0, pad = 22.0, mx = Double(max(1, byHour.max() ?? 1))
        let slot = (w - pad) / 24, bw = slot * 0.7
        var svg = "<svg viewBox=\"0 0 \(Int(w)) \(Int(h))\" class=\"chart\">"
        for (hh, v) in byHour.enumerated() {
            let x = pad + slot * Double(hh) + (slot - bw) / 2, ht = (h - 2 * pad) * Double(v) / mx
            svg += "<rect x=\"\(x)\" y=\"\(h - pad - ht)\" width=\"\(bw)\" height=\"\(max(0, ht))\" rx=\"3\" fill=\"var(--series)\"><title>\(hh):00 — \(v)</title></rect>"
            if hh % 3 == 0 { svg += "<text x=\"\(x + bw / 2)\" y=\"\(h - pad + 13)\" text-anchor=\"middle\" class=\"tick\">\(hh)</text>" }
        }
        return svg + "</svg>"
    }

    static func sparkline(_ vals: [Double], unit: String) -> String {
        guard !vals.isEmpty else { return "<p class=\"empty\">пока нет замеров LLM — подиктуй фразы с чисткой</p>" }
        let w = 620.0, h = 150.0, pad = 26.0
        let mx = vals.max()!, mn = vals.min()!, rng = (mx - mn) == 0 ? 1 : mx - mn, n = vals.count
        let step = (w - 2 * pad) / Double(max(n - 1, 1))
        let pts = vals.enumerated().map { (pad + Double($0.offset) * step, h - pad - (h - 2 * pad) * ($0.element - mn) / rng) }
        let d = "M" + pts.map { "\(n1($0.0)),\(n1($0.1))" }.joined(separator: " L")
        let area = d + " L\(n1(pts.last!.0)),\(Int(h - pad)) L\(n1(pts[0].0)),\(Int(h - pad)) Z"
        let avg = vals.reduce(0, +) / Double(n)
        let ya = h - pad - (h - 2 * pad) * (avg - mn) / rng
        var svg = "<svg viewBox=\"0 0 \(Int(w)) \(Int(h))\" class=\"chart\">"
        svg += "<path d=\"\(area)\" fill=\"var(--series)\" opacity=\"0.10\"/>"
        svg += "<line x1=\"\(Int(pad))\" y1=\"\(n1(ya))\" x2=\"\(Int(w - pad))\" y2=\"\(n1(ya))\" class=\"grid\"/>"
        svg += "<text x=\"\(Int(w - pad))\" y=\"\(n1(ya - 5))\" text-anchor=\"end\" class=\"tick\">среднее \(r0(avg))\(unit)</text>"
        svg += "<path d=\"\(d)\" fill=\"none\" stroke=\"var(--series)\" stroke-width=\"2\" stroke-linejoin=\"round\"/>"
        let (lx, ly) = pts.last!
        svg += "<circle cx=\"\(n1(lx))\" cy=\"\(n1(ly))\" r=\"4\" fill=\"var(--series)\"/>"
        svg += "<text x=\"\(n1(lx))\" y=\"\(n1(ly - 9))\" text-anchor=\"end\" class=\"val\">\(r0(vals.last!))\(unit)</text>"
        return svg + "</svg>"
    }

    static func donut(_ rate: Int) -> String {
        let c = 2 * 3.14159 * 52, off = c * (1 - Double(rate) / 100)
        return """
            <svg viewBox="0 0 140 140" class="donut">
              <circle cx="70" cy="70" r="52" fill="none" stroke="var(--track)" stroke-width="16"/>
              <circle cx="70" cy="70" r="52" fill="none" stroke="var(--accent)" stroke-width="16"
                stroke-linecap="round" stroke-dasharray="\(n1(c))" stroke-dashoffset="\(n1(off))"
                transform="rotate(-90 70 70)"/>
              <text x="70" y="66" text-anchor="middle" class="donut-num">\(rate)%</text>
              <text x="70" y="86" text-anchor="middle" class="donut-lbl">исправлено</text>
            </svg>
            """
    }

    static func tile(_ label: String, _ value: String, _ sub: String = "") -> String {
        "<div class=\"tile\"><div class=\"tile-l\">\(label)</div><div class=\"tile-v\">\(value)</div><div class=\"tile-s\">\(sub)</div></div>"
    }

    // MARK: страница

    /// rows — история (свежие первыми); dict — (ручных, авто); audioIDs — у кого лежит audio/<id>.wav.
    public static func build(active: String, rows rs: [History.Row], dict: (Int, Int), audioIDs: Set<Int64>,
                             template: String, now: Date = Date()) -> String {
        let total = rs.count
        let words = rs.reduce(0) { $0 + countWords($1.text) }
        let secs = rs.reduce(0.0) { $0 + $1.duration }
        let corrected = rs.filter { $0.text != $0.raw }.count
        var appCount: [String: (Int, Int)] = [:]
        for (i, r) in rs.enumerated() { let a = r.app.isEmpty ? "?" : r.app; let c = appCount[a] ?? (0, i); appCount[a] = (c.0 + 1, c.1) }
        let apps = appCount.sorted { $0.value.0 != $1.value.0 ? $0.value.0 > $1.value.0 : $0.value.1 < $1.value.1 }.prefix(8).map { ($0.key, $0.value.0) }
        var byDay: [String: (Int, Int)] = [:], byHour = [Int](repeating: 0, count: 24)
        for r in rs {
            let d = day(r.ts); var v = byDay[d] ?? (0, 0); v.0 += 1; if r.text != r.raw { v.1 += 1 }; byDay[d] = v
            byHour[Int(fmt("H", r.ts)) ?? 0] += 1
        }
        let tps = rs.compactMap { $0.genTps }.filter { $0 != 0 }
        let asr = rs.compactMap { $0.asrMs }.filter { $0 != 0 }
        let llm = rs.compactMap { $0.llmMs }.filter { $0 != 0 }
        func avg(_ xs: [Double]) -> Int { xs.isEmpty ? 0 : r0(xs.reduce(0, +) / Double(xs.count)) }
        var perf: [String: ([Double], [Double])] = [:]
        for r in rs { if let a = r.asrMs, a != 0 { let d = day(r.ts); var p = perf[d] ?? ([], []); p.0.append(a); p.1.append(r.duration); perf[d] = p } }
        let perfDays = perf.sorted { $0.key < $1.key }.map { ($0.key, r1(median($0.value.0) / 1000), r1(median($0.value.1)), $0.value.0.count) }
        let today = day(now.timeIntervalSince1970)
        let asrMed = r0(median(asr)), asrToday = perf[today].map { r0(median($0.0)) } ?? 0
        let corrRate = total > 0 ? r0(100 * Double(corrected) / Double(total)) : 0
        let avgWords = total > 0 ? r1(Double(words) / Double(total)) : 0
        let wpm = secs > 0 ? r0(Double(words) / (secs / 60)) : 0
        let mins = r0(secs / 60)
        let asrSeries = Array(asr.reversed().suffix(60)), tpsSeries = Array(tps.reversed().suffix(40))
        var wordsStr = "", digits = Array(String(words))
        for (i, ch) in digits.enumerated() { if i > 0 && (digits.count - i) % 3 == 0 { wordsStr += " " }; wordsStr.append(ch) }  // 16 909
        let genTps = avg(tps), llmAvg = avg(llm)

        let stats = """
              <div class="tiles">
                \(tile("Всего слов надиктовано", wordsStr, "\(total) диктовок · \(mins) мин речи"))
                \(tile("В среднем за диктовку", "\(avgWords)", "слов"))
                \(tile("Темп речи", "\(wpm)", "слов/мин"))
                \(tile("Словарь", "\(dict.0)+\(dict.1)", "ручных + авто"))
              </div>
              <div class="grid2">
                <div class="card"><h3>Диктовок по дням
                  <span class="key"><i class="sw2"></i>всего <i class="swa"></i>исправлено</span></h3>
                  \(timeline(byDay.sorted { $0.key < $1.key }.map { ($0.key, $0.value.0, $0.value.1) }))</div>
                <div class="card center"><h3>Доля исправлений LLM</h3>
                  \(donut(corrRate))
                  <p class="note">\(corrected) из \(total) фраз правились чисткой</p></div>
              </div>
              <div class="grid2">
                <div class="card"><h3>Куда диктуешь</h3>\(barsH(apps))</div>
                <div class="card"><h3>В какое время суток</h3>\(hours(byHour))</div>
              </div>
              <h2 class="sec">Производительность</h2>
              <div class="tiles">
                \(tile("Скорость генерации LLM", genTps > 0 ? "\(genTps)" : "—", "токенов/с в среднем"))
                \(tile("Распознавание", asrMed > 0 ? "\(asrMed) мс" : "—", asrToday > 0 ? "медиана на фразу · сегодня \(asrToday) мс" : "медиана на фразу"))
                \(tile("LLM-чистка", llmAvg > 0 ? "\(llmAvg) мс" : "—", "когда включается"))
                \(tile("Модели", "whisper.cpp + MLX", "Whisper на Metal + чистка на MLX"))
              </div>
              <div class="card"><h3>Распознавание по дням
                <span class="key"><i class="sw2"></i>длина фразы, с <i class="sw1"></i>время ASR, с</span></h3>
                \(perfTimeline(perfDays))
                <p class="note">Медианы за день. Тёмный столбик выше светлого — распознавание
                  идёт дольше самой фразы; для одной машины смотри тренд, для разных — сравни высоту.</p></div>
              <div class="card"><h3>Распознавание по фразам
                <span class="key">мс, последние \(asrSeries.count)</span></h3>
                \(sparkline(asrSeries, unit: " мс"))</div>
              <div class="card"><h3>Скорость генерации LLM по фразам
                <span class="key">токенов/с, последние \(tpsSeries.count)</span></h3>
                \(sparkline(tpsSeries, unit: " т/с"))</div>
            """
        let search: [[String: Any]] = rs.map { r in
            [
                "id": r.id, "t": fmt("dd.MM HH:mm", r.ts), "app": r.app.isEmpty ? "?" : r.app, "text": r.text,
                "raw": r.raw != r.text ? r.raw : "",
                "asr": r.asrMs.map { $0 != 0 ? String(format: "%.1f с → %.1f с", r.duration, $0 / 1000) : "" } ?? "",
                "audio": audioIDs.contains(r.id),
            ]
        }
        let json = (try? JSONSerialization.data(withJSONObject: search, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let safe = json.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")  // «</script>» в диктовке
        return template.replacingOccurrences(of: "__ACTIVE__", with: active)
            .replacingOccurrences(of: "__STATS__", with: stats)
            .replacingOccurrences(of: "__DATA__", with: safe)
    }
}
