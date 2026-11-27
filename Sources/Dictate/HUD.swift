import AppKit
import ApplicationServices
import DictateCore

/// Капсула-индикатор у текстового курсора — порт hud.py Python-версии, ключи config.json те же
/// (hud, hud_size, hud_icon, hud_color, hud_bg, hud_pos). Панель без рамки поверх окон, не берёт фокус
/// и мышь. «rec» — значок уровня в акцентном цвете, «busy» — три пульсирующие точки. Позиция — у каретки
/// активного поля (Accessibility); каретка без координат — над самим полем; нет и поля — внизу экрана с мышью.
final class HUD {
    static let colors: [(String, String, NSColor)] = [
        ("red", "Красный", NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)),
        ("orange", "Оранжевый", NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.0, alpha: 1)),
        ("pink", "Розовый", NSColor(calibratedRed: 1.0, green: 0.18, blue: 0.33, alpha: 1)),
        ("purple", "Фиолетовый", NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.95, alpha: 1)),
        ("blue", "Синий", NSColor(calibratedRed: 0.0, green: 0.44, blue: 1.0, alpha: 1)),
        ("cyan", "Голубой", NSColor(calibratedRed: 0.2, green: 0.68, blue: 0.9, alpha: 1)),
        ("green", "Зелёный", NSColor(calibratedRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)),
        ("white", "Белый", NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1)),
    ]
    static let sizes: [(String, String, CGSize)] = [
        ("tiny", "Супермаленький", CGSize(width: 30, height: 12)),
        ("small", "Маленький", CGSize(width: 46, height: 20)),
        ("normal", "Обычный", CGSize(width: 64, height: 28)),
    ]
    static let icons: [(String, String)] = [("bars", "Столбики уровня"), ("dot", "Точка (пульсирует от громкости)"),
                                            ("ring", "Кольцо"), ("mic", "Микрофон"), ("wave", "Волна")]
    static let backgrounds: [(String, String)] = [("system", "Как в системе"), ("dark", "Тёмный"), ("light", "Светлый")]
    static let positions: [(String, String)] = [("caret", "У текстового курсора"), ("bottom", "Внизу экрана")]

    /// wait — запись идёт, но вход ещё отдаёт нули (AirPods поднимают канал гарнитуры): значок серый, говорить рано.
    enum Mode { case wait, rec, busy }

    let config: Config
    private var panel: NSPanel?
    private var view: HUDView?
    private var timer: Timer?
    private(set) var mode: Mode?
    var previewMode: Mode? { get { mode } set { mode = newValue } }  // для --hud-preview
    var levels: [Float] = []   // последние уровни (0…1), пишет запись
    /// Программное усиление текущего входа (MicGain): с тихим микрофоном RMS × 12 даёт 0,07–0,13 — столбики
    /// остаются точками. Ставится в начале каждой записи.
    var gain: Float = 1

    init(config: Config) { self.config = config }

    var enabled: Bool { config.bool("hud", true) }

    func pushLevel(_ rms: Float) {
        levels.append(min(1, rms * 12 * gain))
        if levels.count > 64 { levels.removeFirst(levels.count - 64) }
    }

    func show(_ m: Mode) {
        guard enabled else { return }
        mode = m
        if m == .rec || m == .wait { levels.removeAll() }
        ensurePanel()
        let size = HUD.sizes.first { $0.0 == config.string("hud_size", "small") }?.2 ?? HUD.sizes[1].2
        panel?.setFrame(targetFrame(size), display: true)
        panel?.orderFrontRegardless()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.view?.needsDisplay = true }
        }
    }

    /// Только смена режима (rec → busy), без пересчёта позиции.
    func setMode(_ m: Mode) { guard panel?.isVisible == true else { return }; mode = m; view?.needsDisplay = true }

    func hide() {
        mode = nil
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: .init(x: 0, y: 0, width: 46, height: 20),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = HUDView(); v.hud = self
        p.contentView = v
        panel = p; view = v
    }

    // MARK: позиция

    /// Прямоугольник каретки активного поля в координатах AppKit или nil.
    private func caretRect() -> CGRect? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)  // подвисшее приложение не должно держать главный поток
        var elRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &elRef) == .success,
              let elRef, CFGetTypeID(elRef) == AXUIElementGetTypeID() else { return nil }
        let el = elRef as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.25)
        var rngRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rngRef) == .success,
              let rngRef, CFGetTypeID(rngRef) == AXValueGetTypeID() else { return nil }
        var values = [rngRef as! AXValue]
        var r = CFRange()
        if AXValueGetValue(rngRef as! AXValue, .cfRange, &r), r.length == 0 {  // пустое выделение — символ справа/слева
            for cand in [CFRange(location: r.location, length: 1), CFRange(location: max(0, r.location - 1), length: 1)] {
                var c = cand
                if let v = AXValueCreate(.cfRange, &c) { values.append(v) }
            }
        }
        // AX: начало — левый верх главного экрана, ось Y вниз
        guard let primary = NSScreen.screens.first?.frame else { return nil }
        func appKit(_ rc: CGRect) -> CGRect {
            CGRect(x: rc.origin.x, y: primary.height - rc.origin.y - rc.height, width: max(2, rc.width), height: rc.height)
        }
        for val in values {
            var bRef: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, val, &bRef) == .success,
                  let bRef, CFGetTypeID(bRef) == AXValueGetTypeID() else { continue }
            var rc = CGRect.zero
            if AXValueGetValue(bRef as! AXValue, .cgRect, &rc), rc.height > 0, rc.height <= 120, rc.width <= max(12, rc.height * 1.5) {
                return appKit(rc)
            }
        }
        // Каретка без координат: Chromium/Electron (Mattermost и др.) на пустом поле отдаёт прямоугольник
        // нулевой высоты. Тогда — над самим полем, у левого края, где стоит курсор пустого поля.
        // Поле выше 240 pt (редактор на всё окно) — не опора: капсула уйдёт вниз экрана, как раньше.
        var fRef: CFTypeRef?
        var f = CGRect.zero
        if AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &fRef) == .success,
           let fRef, CFGetTypeID(fRef) == AXValueGetTypeID(),
           AXValueGetValue(fRef as! AXValue, .cgRect, &f), f.width >= 20, f.height >= 10, f.height <= 240 {
            return appKit(CGRect(x: f.minX + 12, y: f.minY, width: 2, height: min(f.height, 60)))
        }
        return nil
    }

    private func screen(for p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func targetFrame(_ s: CGSize) -> CGRect {
        let (w, h) = (s.width, s.height)
        var caret = config.string("hud_pos", "caret") == "caret" ? caretRect() : nil
        if let c = caret, !NSScreen.screens.contains(where: { $0.frame.contains(c.origin) }) { caret = nil }
        var x: CGFloat, y: CGFloat, vis: CGRect
        if let c = caret, let scr = screen(for: c.origin) {
            vis = scr.visibleFrame
            x = c.midX - w / 2
            y = c.maxY + 8
            if y + h > vis.maxY { y = c.minY - h - 8 }  // не влезает сверху — под строкой
        } else {
            let m = NSEvent.mouseLocation
            guard let scr = screen(for: m) else { return CGRect(x: 0, y: 0, width: w, height: h) }
            vis = scr.visibleFrame
            x = vis.midX - w / 2
            y = vis.minY + 56
        }
        x = min(max(x, vis.minX + 6), vis.maxX - w - 6)
        y = min(max(y, vis.minY + 6), vis.maxY - h - 6)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

final class HUDView: NSView {
    weak var hud: HUD?

    override func draw(_ dirty: NSRect) {
        guard let hud, let mode = hud.mode else { return }
        let b = bounds, w = b.width, h = b.height
        var bg = hud.config.string("hud_bg", "system")
        if bg == "system" {
            bg = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        }
        let (fill, stroke) = bg == "dark"
            ? (NSColor(calibratedWhite: 0.08, alpha: 0.86), NSColor(calibratedWhite: 1, alpha: 0.12))
            : (NSColor(calibratedWhite: 0.98, alpha: 0.92), NSColor(calibratedWhite: 0, alpha: 0.10))
        let path = NSBezierPath(roundedRect: b.insetBy(dx: 1, dy: 1), xRadius: h / 2, yRadius: h / 2)
        fill.setFill(); path.fill()
        stroke.setStroke(); path.lineWidth = 1; path.stroke()
        let key = hud.config.string("hud_color", "red")
        var accent = HUD.colors.first { $0.0 == key }?.2 ?? HUD.colors[0].2
        if bg == "light" && key == "white" { accent = NSColor(calibratedWhite: 0.25, alpha: 1) }  // белый на светлом не виден
        let t = Date().timeIntervalSinceReferenceDate
        let tiny = h < 16
        if mode == .wait {  // микрофон ещё не отдаёт звук — серый мерцающий значок вместо цветного
            accent = NSColor(calibratedWhite: bg == "dark" ? 0.62 : 0.45, alpha: 0.45 + 0.35 * (0.5 + 0.5 * sin(t * 9)))
        }
        switch mode {
        case .rec, .wait:
            let level = CGFloat(hud.levels.last ?? 0)
            switch hud.config.string("hud_icon", "bars") {
            case "dot":
                let d = h * (0.36 + 0.42 * min(1, level * 1.5))
                accent.setFill(); NSBezierPath(ovalIn: CGRect(x: (w - d) / 2, y: (h - d) / 2, width: d, height: d)).fill()
            case "ring":
                let d0 = h * 0.42
                accent.setFill(); NSBezierPath(ovalIn: CGRect(x: (w - d0) / 2, y: (h - d0) / 2, width: d0, height: d0)).fill()
                let ph = CGFloat((t * 1.6).truncatingRemainder(dividingBy: 1))  // расходящееся кольцо
                let d1 = d0 + h * 0.5 * ph
                accent.withAlphaComponent(1 - ph).setStroke()
                let ring = NSBezierPath(ovalIn: CGRect(x: (w - d1) / 2, y: (h - d1) / 2, width: d1, height: d1))
                ring.lineWidth = max(1, h * 0.08); ring.stroke()
            case let icon where icon == "mic" || icon == "wave":
                let cfg = NSImage.SymbolConfiguration(pointSize: h * 0.62, weight: .semibold)
                    .applying(.init(hierarchicalColor: accent))
                if let img = NSImage(systemSymbolName: icon == "mic" ? "mic.fill" : "waveform", accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg) {
                    let s = img.size
                    img.draw(in: CGRect(x: (w - s.width) / 2, y: (h - s.height) / 2, width: s.width, height: s.height),
                             from: .zero, operation: .sourceOver, fraction: 0.55 + 0.45 * min(1, level * 1.5))
                } else { drawBars(w, h, accent, t, tiny) }
            default: drawBars(w, h, accent, t, tiny)
            }
        case .busy:
            let n = tiny ? 1 : 3
            let d = h * (tiny ? 0.4 : 0.2), gap = d * 0.9
            let x0 = (w - (CGFloat(n) * d + CGFloat(n - 1) * gap)) / 2
            for i in 0..<n {
                let a = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 1.1))
                accent.withAlphaComponent(a).setFill()
                NSBezierPath(ovalIn: CGRect(x: x0 + CGFloat(i) * (d + gap), y: (h - d) / 2, width: d, height: d)).fill()
            }
        }
    }

    private func drawBars(_ w: CGFloat, _ h: CGFloat, _ accent: NSColor, _ t: Double, _ tiny: Bool) {
        guard let hud else { return }
        let n = tiny ? 3 : 5
        var lv = Array(hud.levels.suffix(n)).map { CGFloat($0) }
        lv = Array(repeating: 0, count: n - lv.count) + lv
        let gap = h * 0.14
        let bw = max(1.5, min(h * 0.18, (w - h) / CGFloat(n) - gap))
        let x0 = (w - (CGFloat(n) * bw + CGFloat(n - 1) * gap)) / 2
        accent.setFill()
        for (i, v) in lv.enumerated() {
            let pulse = 0.5 + 0.5 * sin(t * 6 + Double(i))  // лёгкое дыхание в тишине
            let bh = h * 0.2 + h * 0.55 * max(v, 0.08 * pulse)
            let r = CGRect(x: x0 + CGFloat(i) * (bw + gap), y: (h - bh) / 2, width: bw, height: bh)
            NSBezierPath(roundedRect: r, xRadius: bw / 2, yRadius: bw / 2).fill()
        }
    }
}
