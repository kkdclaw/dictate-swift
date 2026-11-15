import AppKit
import CoreGraphics
import DictateCore

/// Действия голосовых команд — порт run_command Python-версии.
final class Actions {
    /// Последняя вставка — для «отмени», «повтори», «переведи».
    struct LastPaste { var text: String; var raw: String; var app: String; var ts: Date }
    var last: LastPaste?
    static let undoWindow: TimeInterval = 300  // старше — «отмени» не трогает (курсор давно не там)
    // в терминале строку чистит ⌃U (zsh kill-whole-line, Claude Code тоже понимает)
    static let terminalApps: Set<String> = ["iTerm2", "Terminal", "Warp", "kitty", "Alacritty", "Ghostty", "WezTerm", "Hyper", "Tabby"]
    static let vk: [String: CGKeyCode] = ["a": 0, "c": 8, "v": 9, "x": 7, "u": 32, "return": 36, "tab": 48,
                                         "delete": 51, "esc": 53, "left": 123, "right": 124]

    let paster: Paster
    init(paster: Paster) { self.paster = paster }

    struct Failed: Error { let why: String }

    func key(_ name: String, _ flags: CGEventFlags = [], delay: TimeInterval = 0.03) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: Actions.vk[name]!, keyDown: down)
            ev?.flags = flags
            ev?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: delay)
    }

    func remember(_ text: String, raw: String, app: String) { last = LastPaste(text: text, raw: raw, app: app, ts: Date()) }

    private func undoLast(_ app: String) throws -> Int {
        guard let lp = last, lp.app == app, Date().timeIntervalSince(lp.ts) <= Actions.undoWindow else {
            throw Failed(why: "нечего отменять: последняя вставка была не сюда или давно")
        }
        let n = lp.text.count  // графемы — столько ⌫ стирает macOS
        for _ in 0..<n { key("delete", delay: 0.004) }
        last = nil  // второе «отмени» не должно стирать чужой текст
        return n
    }

    /// Выполнить команду (хвостовая часть текста к этому моменту уже вставлена). Возвращает строку для журнала.
    func run(_ m: Commands.Match, app: String, restore: Bool) throws -> String {
        if let snip = m.snippet {
            paster.paste(snip, restore: restore)
            remember(snip, raw: snip, app: app)
            return "сниппет (\(snip.count) симв.)"
        }
        switch m.id {
        case "delete_line":
            if Actions.terminalApps.contains(app) { key("u", .maskControl); return "строка стёрта (⌃U)" }
            key("right", .maskCommand); key("left", [.maskCommand, .maskShift]); key("delete")
            return "строка стёрта"
        case "undo": return "стёр последнюю вставку (\(try undoLast(app)) симв.)"
        case "delete_word": key("delete", .maskAlternate); return "слово стёрто"
        case "delete_all": key("a", .maskCommand); key("delete"); return "всё стёрто"
        case "select_all": key("a", .maskCommand); return "выделено всё"
        case "repeat":
            guard var lp = last else { throw Failed(why: "нечего повторять") }
            paster.paste(lp.text, restore: restore)
            lp.ts = Date(); lp.app = app; last = lp
            return "повторил последнюю вставку"
        case "send": key("return"); return "Return"
        case "new_line": key("return", .maskShift); return "перенос строки"
        case "paragraph": key("return", .maskShift); key("return", .maskShift); return "абзац"
        case "tab": key("tab"); return "tab"
        case "enter": key("return"); return "enter"
        case "esc": key("esc"); return "esc"
        case "copy": key("c", .maskCommand); return "⌘C"
        case "cut": key("x", .maskCommand); return "⌘X"
        case "paste": key("v", .maskCommand); return "⌘V"
        case "translate", "style_clean", "style_casual", "style_formal", "style_raw":
            throw Failed(why: "выполняется контроллером")
        default: throw Failed(why: "неизвестная команда \(m.id)")
        }
    }
}
