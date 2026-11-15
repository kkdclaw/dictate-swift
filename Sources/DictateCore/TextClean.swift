import Foundation

/// Сегмент распознавания — для гейта титров по аудио.
public struct Segment: Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var noSpeechProb: Double
    public var avgLogprob: Double
    public init(text: String, start: Double, end: Double, noSpeechProb: Double = 0, avgLogprob: Double = 0) {
        self.text = text; self.start = start; self.end = end
        self.noSpeechProb = noSpeechProb; self.avgLogprob = avgLogprob
    }
}

/// Вырезать галлюцинации Whisper: петли и титры. Порт textclean.py Python-версии — правила те же.
public enum TextClean {
    // Whisper учился на субтитрах и на хвосте тишины дописывает титры. Ищем их только в самом конце
    static let tailJunk = ["продолжение следует", "субтитры сделал", "субтитры делал",
                           "субтитры создавал", "субтитры и перевод", "редактор субтитров",
                           "спасибо за просмотр", "подписывайтесь на канал", "ставьте лайки",
                           "thanks for watching", "thank you for watching",
                           "subtitles by", "amara.org"]
    // титры с подписью: после них идёт имя автора, там буквы ждём
    static let tailSigned: Set<String> = ["субтитры сделал", "субтитры делал", "субтитры создавал",
                                          "редактор субтитров", "subtitles by"]
    static let tailRest = try! NSRegularExpression(pattern: #"^[\s.!?…,;:\-–—"'»)]*$"#)
    static let tailNoSpeech = 0.4, tailGapSec = 1.0, tailLogprob = -1.0
    // кусок повторяется подряд 4 раза и больше; `.` ловит и склеенные повторы «ratosratos…»
    static let loopRE = try! NSRegularExpression(pattern: #"(.{2,30}?)\1{3,}"#, options: [.dotMatchesLineSeparators])
    static let loopMin = 12, loopShortUnit = 5, loopShortReps = 8
    static let letter = try! NSRegularExpression(pattern: #"[^\W\d_]"#)

    static func hasLetter(_ s: String) -> Bool {
        letter.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func tailIsJunk(_ text: String, _ i: Int, _ segments: [Segment]?) -> Bool {
        guard let segments, !segments.isEmpty else { return true }
        var pos = 0, prevEnd: Double? = nil, seg: Segment? = nil, gap = 0.0
        for (k, s) in segments.enumerated() {
            let end = pos + s.text.count
            if i < end || k == segments.count - 1 {
                seg = s
                if let prevEnd { gap = s.start - prevEnd }
                break
            }
            pos = end; prevEnd = s.end
        }
        guard let seg else { return true }
        return seg.noSpeechProb > tailNoSpeech || gap > tailGapSec || seg.avgLogprob < tailLogprob
    }

    /// (очищенный текст, что вырезали) — вырезанное идёт в журнал.
    public static func stripLoops(_ input: String, segments: [Segment]? = nil) -> (String, [String]) {
        var cut: [String] = []
        let ns = input as NSString
        var out = "", pos = 0
        for m in loopRE.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let unit = ns.substring(with: m.range(at: 1)), whole = ns.substring(with: m.range)
            let reps = whole.count / max(1, unit.count)
            if whole.count < loopMin || !hasLetter(unit) { continue }
            if unit.trimmingCharacters(in: .whitespaces).count < loopShortUnit && reps < loopShortReps { continue }
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            cut.append("«\(unit.trimmingCharacters(in: .whitespaces))»×\(reps)")
            pos = m.range.location + m.range.length
        }
        out += ns.substring(from: pos)
        var text = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        for _ in 0..<tailJunk.count {  // титров может быть несколько подряд
            let low = text.lowercased()
            var didCut = false
            for phrase in tailJunk {
                guard let r = low.range(of: phrase, options: .backwards) else { continue }
                let i = low.distance(from: low.startIndex, to: r.lowerBound)
                let restStart = text.index(text.startIndex, offsetBy: i + phrase.count)
                let rest = String(text[restStart...])
                let restOK = tailSigned.contains(phrase) ||
                    tailRest.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil
                // титры — в самом хвосте; i > 0 — одну фразу целиком не выбрасываем
                if i > 0 && rest.count <= 20 && restOK && tailIsJunk(text, i, segments) {
                    let at = text.index(text.startIndex, offsetBy: i)
                    cut.append(String(text[at...]).trimmingCharacters(in: .whitespaces))
                    text = String(text[..<at])
                    while let last = text.last, " \t,-–—".contains(last) { text.removeLast() }
                    didCut = true
                    break
                }
            }
            if !didCut { break }
        }
        return (text.trimmingCharacters(in: .whitespaces), cut)
    }
}
