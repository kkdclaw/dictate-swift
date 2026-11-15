import AppKit
import CoreGraphics
import DictateCore

/// Окно захвата своей горячей клавиши — порт hotkeywindow.py: «нажми сочетание» + живой показ зажатого.
/// Клавишу с модификаторами принимаем сразу, одиночный модификатор — на отпускании, если ничего другого
/// не нажали; Esc или «Отмена» — оставить как было.
final class HotkeyCapture: NSObject {
    private var panel: NSPanel?
    private let held = NSTextField(labelWithString: "…")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var heldModifier: UInt16?
    private var done: ((String?) -> Void)?

    func start(tap: HotkeyTap, current: String, done: @escaping (String?) -> Void) {
        self.done = done
        heldModifier = nil
        build()
        held.stringValue = "…"
        status.stringValue = "Сейчас: \(current). Ожидаю нажатия… Esc или «Отмена» — оставить как было."
        status.textColor = .secondaryLabelColor
        panel?.center()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        tap.capture = { [weak self, weak tap] type, code, flags in
            DispatchQueue.main.async { if let self, let tap { self.event(tap, type, code, flags) } }
        }
    }

    private func event(_ tap: HotkeyTap, _ type: CGEventType, _ code: UInt16, _ flags: UInt64) {
        if type == .keyDown && code == HotkeySpec.escCode && flags & HotkeySpec.allMods == 0 { finish(tap, nil); return }
        if type == .flagsChanged {
            if HotkeySpec.isModifierKey(code) {
                let downNow = heldModifier != code
                if downNow { heldModifier = code; held.stringValue = HotkeySpec.heldDescription(code: code, flags: flags) }
                else if let spec = HotkeySpec.specFromPress(code: code, flags: 0) { finish(tap, spec) }  // отпустили одиночный модификатор
            }
            return
        }
        guard type == .keyDown else { return }
        heldModifier = nil  // модификатор был частью сочетания, а не хоткеем
        if let spec = HotkeySpec.specFromPress(code: code, flags: flags) { finish(tap, spec); return }
        held.stringValue = HotkeySpec.heldDescription(code: code, flags: flags)
        status.stringValue = "Так не годится: одиночная буква, цифра или пробел сработают при обычном наборе. Добавь модификатор или возьми F-клавишу."
        status.textColor = .systemOrange
    }

    private func finish(_ tap: HotkeyTap, _ spec: String?) {
        tap.capture = nil
        if let spec, let hk = HotkeySpec.parse(spec) {
            held.stringValue = hk.label
            status.stringValue = "Принято — уже работает."
            status.textColor = .systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.panel?.orderOut(nil) }
        } else {
            panel?.orderOut(nil)
        }
        let cb = done; done = nil
        cb?(spec)
    }

    @objc private func cancel() {
        // Esc ловит перехват; кнопка — для мыши
        if let cb = done { done = nil; panel?.orderOut(nil); cb(nil) }
    }

    private func build() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Горячая клавиша диктовки"
        p.isReleasedWhenClosed = false
        p.level = .floating
        let head = NSTextField(labelWithString: "Нажми сочетание клавиш"); head.font = .boldSystemFont(ofSize: 17)
        let hint = NSTextField(wrappingLabelWithString: "Подойдёт одиночный модификатор (Option, Command, Control, Shift, Fn/🌐), клавиша F1–F20 или любая клавиша с модификаторами (⌃ Space, ⌘⇧ D…). Одиночная буква или пробел не годятся — сработают при обычном наборе.")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        held.font = .boldSystemFont(ofSize: 26); held.alignment = .center
        status.font = .systemFont(ofSize: 12)
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel)); cancel.keyEquivalent = ""
        let stack = NSStackView(views: [head, hint, held, status, cancel])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        held.widthAnchor.constraint(equalToConstant: 420).isActive = true
        hint.preferredMaxLayoutWidth = 420; status.preferredMaxLayoutWidth = 420
        p.contentView = stack
        panel = p
    }
}
