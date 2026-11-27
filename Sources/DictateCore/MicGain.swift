import Foundation

/// Программное усиление микрофона.
///
/// У части USB-микрофонов и переходников системный регулятор входа умеет только ослаблять (−60…0 дБ), а на
/// максимуме сигнал тихий: пик речи 0,02–0,03 вместо обычных 0,2–0,9. Распознаванию это не мешает — шум у таких
/// входов тоже низкий, — но столбики капсулы оставались точками, а запись с пиком ниже 0,02 уходила в
/// «захват пустой». Поэтому уровень поднимается уже после захвата:
///  • авто (по умолчанию) — тихая запись подтягивается к пику `targetPeak`, не больше чем в `maxAuto` раз;
///    пустым считается только мёртвый вход (`deadPeak`), а есть ли в записи речь — решает VAD;
///  • постоянный множитель из меню (×2…×16) или «выключено» (×1) — запись умножается на него, порог пустого
///    захвата прежний (`silentPeak`), но по усиленному сигналу.
/// Шкала капсулы берёт тот же множитель: в авто — выученный по прошлым записям этого входа (`learn`).
public enum MicGain {
    /// Пик, к которому автоусиление подтягивает тихую запись (речь в обычный микрофон даёт 0,2–0,9).
    public static let targetPeak: Float = 0.25
    /// Потолок автоусиления: ×32 ≈ +30 дБ. Больше — уже шум, а не тихий микрофон.
    public static let maxAuto: Float = 32
    /// Пик ниже — вход мёртв: нули или шумовой пол уснувшей гарнитуры (WH-1000XM5 — 0,0024). Усиливать нечего.
    public static let deadPeak: Float = 0.004
    /// Порог «захват пустой» при постоянном множителе, по усиленному сигналу (как в Python 0.17.2).
    public static let silentPeak: Float = 0.02
    /// Постоянные множители в меню (кроме «Выключено» = ×1).
    public static let manual: [Float] = [2, 4, 8, 16]

    /// Режим из config.json (`mic_gain`): ключа нет или "auto" — авто (nil); число — постоянный множитель, 1 — выключено.
    public static func fixed(_ value: Any?) -> Float? {
        let n: Double
        switch value {
        case let v as Double: n = v
        case let v as Float: n = Double(v)
        case let v as Int: n = Double(v)
        default: return nil
        }
        guard n.isFinite else { return nil }
        return Float(max(1, min(64, n)))
    }

    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    /// Запись пустая: в авто — только мёртвый вход, при постоянном множителе — прежний порог по усиленному сигналу.
    public static func isEmpty(peak: Float, fixed: Float?) -> Bool {
        if let fixed { return peak * max(1, fixed) < silentPeak }
        return peak < deadPeak
    }

    /// Во сколько раз усилить запись с таким пиком (1 — не трогать).
    public static func factor(peak: Float, fixed: Float?) -> Float {
        if let fixed { return max(1, fixed) }
        guard peak >= deadPeak, peak < targetPeak else { return 1 }
        return min(maxAuto, targetPeak / peak)
    }

    /// Усиленная копия записи; выбросы срезаются по ±1 (в авто их нет: множитель считается от пика).
    public static func amplified(_ samples: [Float], by gain: Float) -> [Float] {
        guard gain != 1 else { return samples }
        return samples.map { max(-1, min(1, $0 * gain)) }
    }

    /// Усиление входа для шкалы капсулы: первая запись с речью задаёт его целиком, дальше — скользящее среднее
    /// (в логарифмах, вес новой записи 0,3), чтобы одна громкая или тихая фраза не дёргала шкалу.
    public static func learn(old: Float?, recording: Float) -> Float {
        let g = max(1, min(maxAuto, recording))
        guard let old, old >= 1 else { return g }
        return exp(0.7 * log(old) + 0.3 * log(g))
    }

    /// «×9», «×2.5» — для меню и журнала.
    public static func label(_ gain: Float) -> String {
        let r = (gain * 10).rounded() / 10
        return r >= 9.95 || r == r.rounded() ? String(format: "×%.0f", r) : String(format: "×%.1f", r)
    }
}
