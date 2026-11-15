import AppKit
import CoreGraphics
import DictateCore

/// Вставка: текст в буфер → ⌘V → через 0,6 с вернуть в буфер то, что там было (картинку, файлы, RTF — всё по типам).
/// Если за это время человек сам что-то скопировал (changeCount ушёл) — не трогаем. Как paste_text в Python-версии.
/// ⌘V синтезируется через CGEvent — нужно разрешение «Универсальный доступ».
final class Paster {
    static let settle = 0.6
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")  // менеджеры буфера не запоминают
    private var pendingSnapshot: [[(NSPasteboard.PasteboardType, Data)]]?
    private var pendingWork: DispatchWorkItem?

    func paste(_ text: String, restore: Bool) {
        let pb = NSPasteboard.general
        // предыдущий возврат ещё не прошёл — его снимок и есть настоящее содержимое буфера
        var saved = pendingSnapshot
        pendingWork?.cancel(); pendingWork = nil; pendingSnapshot = nil
        if restore && saved == nil { saved = snapshot(pb) }
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: Paster.transient)
        let change = pb.changeCount
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)  // 9 = kVK_ANSI_V
            ev?.flags = .maskCommand
            ev?.post(tap: .cghidEventTap)
        }
        guard restore, let saved else { return }
        pendingSnapshot = saved
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSnapshot = nil; self.pendingWork = nil
            guard pb.changeCount == change else { return }  // человек уже скопировал своё
            self.restore(pb, saved)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Paster.settle, execute: work)
    }

    private func snapshot(_ pb: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
            .filter { !$0.isEmpty }
    }

    private func restore(_ pb: NSPasteboard, _ items: [[(NSPasteboard.PasteboardType, Data)]]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let objs: [NSPasteboardItem] = items.map { entry in
            let it = NSPasteboardItem()
            for (t, d) in entry { it.setData(d, forType: t) }
            return it
        }
        pb.writeObjects(objs)
    }
}
