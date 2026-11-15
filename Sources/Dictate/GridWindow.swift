import AppKit

/// Окно «таблица по разделам» — как statuspanel.py / modelswindow.py Python-версии: строка = подпись · значение ·
/// кнопка. Содержимое отдаёт snapshot(); пересборка сетки — только при смене формы (набор строк и кнопок),
/// иначе меняются тексты: прогресс закачки не дёргает кнопку под мышью.
final class GridWindow: NSObject, NSWindowDelegate {
    struct Row { var label: String; var value: String; var button: String? = nil; var action: String? = nil }
    typealias Section = (String, [Row])

    let window: NSWindow
    private let grid = NSGridView()
    private let snapshot: () -> [Section]
    private let onAction: (String) -> Void
    private var shape = ""
    private var valueFields: [NSTextField] = []
    private var timer: Timer?

    init(title: String, width: CGFloat = 640, snapshot: @escaping () -> [Section], onAction: @escaping (String) -> Void) {
        self.snapshot = snapshot; self.onAction = onAction
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        grid.rowSpacing = 6; grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -14),
        ])
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = doc
        window.contentView = scroll
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    }

    func show() {
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ n: Notification) { timer?.invalidate(); timer = nil }

    func refresh() {
        let secs = snapshot()
        let newShape = secs.map { s in s.0 + "|" + s.1.map { "\($0.label)#\($0.button ?? "")#\($0.action ?? "")" }.joined(separator: ";") }
            .joined(separator: "\n")
        if newShape != shape { rebuild(secs); shape = newShape; return }
        var i = 0
        for (_, rows) in secs { for r in rows { if i < valueFields.count, valueFields[i].stringValue != r.value { valueFields[i].stringValue = r.value }; i += 1 } }
    }

    private func label(_ s: String, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 12)
        if secondary { f.textColor = .secondaryLabelColor }
        f.isSelectable = true
        f.preferredMaxLayoutWidth = 380
        return f
    }

    private func rebuild(_ secs: [Section]) {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        valueFields = []
        for (title, rows) in secs {
            let head = label(title, bold: true)
            grid.addRow(with: [head, NSGridCell.emptyContentView, NSGridCell.emptyContentView])
            grid.row(at: grid.numberOfRows - 1).topPadding = grid.numberOfRows > 1 ? 10 : 0
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 3), verticalRange: NSRange(location: grid.numberOfRows - 1, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: grid.numberOfRows - 1).xPlacement = .leading
            for r in rows {
                let v = label(r.value)
                valueFields.append(v)
                var btn: NSView = NSGridCell.emptyContentView
                if let b = r.button, let a = r.action {
                    let button = NSButton(title: b, target: self, action: #selector(clicked(_:)))
                    button.bezelStyle = .rounded; button.controlSize = .small
                    button.identifier = NSUserInterfaceItemIdentifier(a)
                    btn = button
                }
                let l = label(r.label, secondary: true); l.preferredMaxLayoutWidth = 150; l.alignment = .right
                grid.addRow(with: [l, v, btn])
            }
        }
        grid.column(at: 0).width = 150
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 380
        grid.rowAlignment = .firstBaseline
    }

    @objc private func clicked(_ b: NSButton) {
        if let a = b.identifier?.rawValue { onAction(a) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
    }
}

/// Документ прокрутки, растущий сверху вниз (иначе таблица прижата к низу окна).
final class FlippedView: NSView { override var isFlipped: Bool { true } }
