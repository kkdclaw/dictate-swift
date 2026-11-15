import AppKit
import DictateCore

/// Окно постобработки «Что вставить?» — порт reviewwindow.py. Панель НЕактивирующая: фокус остаётся в поле,
/// куда вставляем, поэтому ⌘V после клика попадает туда же; плата — выбор только мышью. Варианты приходят по
/// мере готовности: сырой и обычный сразу, стили — «считаю…», потом дозаполняются через update().
final class ReviewWindow: NSObject, NSWindowDelegate {
    struct Variant { let key: String; let title: String; var text: String? }

    static let width: CGFloat = 620, margin: CGFloat = 20
    private var panel: NSPanel?
    private var stack: NSStackView!
    private var buttons: [NSButton] = []
    private var variants: [Variant] = []
    private var onPick: ((String, String) -> Void)?
    private var onCancel: (() -> Void)?
    private(set) var session = 0
    private var openSession: Int?
    private var closing = false

    func isOpen(_ s: Int) -> Bool { openSession == s }

    func show(_ vs: [Variant], onPick: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) -> Int {
        session += 1; openSession = session
        if panel == nil { build() }
        variants = vs; self.onPick = onPick; self.onCancel = onCancel
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        buttons = vs.enumerated().map { i, v in row(i, v) }
        buttons.forEach { stack.addArrangedSubview($0) }
        fit(); place()
        panel?.orderFrontRegardless()  // без активации приложения: фокус остаётся в поле
        return session
    }

    func update(_ s: Int, key: String, text: String) {
        guard s == openSession, let i = variants.firstIndex(where: { $0.key == key }) else { return }
        variants[i].text = text
        if i < buttons.count { fill(buttons[i], variants[i]) }
        fit()
    }

    func close(cancelled: Bool) {
        guard openSession != nil else { return }
        let cb = cancelled ? onCancel : nil
        onPick = nil; onCancel = nil; openSession = nil
        closing = true; panel?.close(); closing = false
        cb?()
    }

    func windowWillClose(_ n: Notification) {  // крестик — тоже отказ от вставки
        guard !closing, openSession != nil else { return }
        let cb = onCancel
        onPick = nil; onCancel = nil; openSession = nil
        cb?()
    }

    @objc private func pick(_ b: NSButton) {
        let i = b.tag
        guard i < variants.count, let text = variants[i].text else { return }  // строка ещё считается
        let cb = onPick, key = variants[i].key
        close(cancelled: false)
        cb?(key, text)
    }

    @objc private func cancel() { close(cancelled: true) }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ReviewWindow.width, height: 300),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "Что вставить?"
        p.isReleasedWhenClosed = false
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false        // меню-бар без Dock: окно не должно прятаться
        p.becomesKeyOnlyIfNeeded = true    // не отбирать фокус у поля ввода
        p.delegate = self
        let content = p.contentView!
        stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(wrappingLabelWithString: "Кликни вариант — он вставится в то же поле. Окно фокус не забирает, поэтому выбор мышью.")
        hint.font = .systemFont(ofSize: 11.5); hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(title: "Не вставлять", target: self, action: #selector(cancel))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        [stack, hint, cancel].forEach { content.addSubview($0) }
        let m = ReviewWindow.margin
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            hint.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            hint.widthAnchor.constraint(equalToConstant: ReviewWindow.width - 40 - 130),
            cancel.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            cancel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -m),
            hint.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -m),
        ])
        panel = p
    }

    private func row(_ i: Int, _ v: Variant) -> NSButton {
        let b = NSButton(frame: NSRect(x: 0, y: 0, width: ReviewWindow.width - 40, height: 44))
        b.bezelStyle = .regularSquare
        b.setButtonType(.momentaryPushIn)
        b.target = self; b.action = #selector(pick(_:)); b.tag = i
        (b.cell as? NSButtonCell)?.wraps = true
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: ReviewWindow.width - 40).isActive = true
        fill(b, v)
        return b
    }

    private func fill(_ b: NSButton, _ v: Variant) {
        let pending = v.text == nil
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping; para.alignment = .left; para.paragraphSpacing = 3
        let s = NSMutableAttributedString(string: v.title + "\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para])
        s.append(NSAttributedString(string: v.text ?? "считаю…", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: pending ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            .paragraphStyle: para]))
        b.attributedTitle = s
        b.isEnabled = !pending  // серую строку нельзя выбрать по ошибке
    }

    /// На экране, где мышь, ближе к низу — чтобы не накрывать то, что человек читает.
    private func place() {
        guard let p = panel else { return }
        let pt = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { $0.frame.contains(pt) } ?? NSScreen.main
        guard let vis = scr?.visibleFrame else { p.center(); return }
        p.setFrameOrigin(NSPoint(x: vis.minX + (vis.width - p.frame.width) / 2, y: vis.minY + vis.height * 0.25))
    }

    private func fit() {
        guard let p = panel, let content = p.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let h = max(content.fittingSize.height, 160)
        let old = p.frame
        if abs(h - old.height) > 1 {
            p.setFrame(NSRect(x: old.minX, y: old.minY + old.height - h, width: ReviewWindow.width, height: h), display: true)
        }
    }
}
