import Foundation

/// Строка хоткея из config.json — формат Python-версии (hotkey.py): токены через «+», последний — клавиша,
/// остальные — модификаторы ctrl/alt/shift/cmd. Клавиша: alt_r, cmd_r, fn, space, f13… или символ US-раскладки
/// (по нему берётся физический код kVK_ANSI_*, поэтому «cmd+shift+d» работает и в русской раскладке).
public struct HotkeySpec: Equatable, Sendable {
    public let keyCode: UInt16
    /// Маска модификаторов CGEvent, которые должны быть зажаты ровно (для сочетаний).
    public let mods: UInt64
    /// Одиночный модификатор (Option, Command, Fn…): ловится по flagsChanged.
    public let isModifierOnly: Bool
    /// Маска флага конкретной клавиши (левый/правый) для одиночного модификатора.
    public let deviceMask: UInt64
    public let label: String

    // маски CGEventFlags
    public static let shift: UInt64 = 0x20000, ctrl: UInt64 = 0x40000, alt: UInt64 = 0x80000, cmd: UInt64 = 0x100000
    public static let secondaryFn: UInt64 = 0x800000
    public static let allMods = shift | ctrl | alt | cmd

    static let modTokens: [String: UInt64] = ["ctrl": ctrl, "alt": alt, "shift": shift, "cmd": cmd]
    static let modGlyph: [(String, String)] = [("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]

    // одиночные модификаторы: код клавиши, флаг устройства (NX_DEVICE*KEYMASK), подпись
    static let modifierKeys: [String: (UInt16, UInt64, String)] = [
        "alt_r": (0x3D, 0x40, "Правый Option ⌥"), "alt_l": (0x3A, 0x20, "Левый Option ⌥"),
        "cmd_r": (0x36, 0x10, "Правый Command ⌘"), "cmd_l": (0x37, 0x08, "Левый Command ⌘"),
        "ctrl_r": (0x3E, 0x2000, "Правый Control ⌃"), "ctrl_l": (0x3B, 0x01, "Левый Control ⌃"),
        "shift_r": (0x3C, 0x04, "Правый Shift ⇧"), "shift_l": (0x38, 0x02, "Левый Shift ⇧"),
        "fn": (0x3F, secondaryFn, "Fn / 🌐"),
    ]
    static let special: [String: (UInt16, String)] = [
        "space": (0x31, "Space"), "tab": (0x30, "Tab"), "enter": (0x24, "Return"), "esc": (0x35, "Esc"),
        "backspace": (0x33, "Delete ⌫"), "delete": (0x75, "Forward Delete ⌦"),
        "up": (0x7E, "↑"), "down": (0x7D, "↓"), "left": (0x7B, "←"), "right": (0x7C, "→"),
        "home": (0x73, "Home"), "end": (0x77, "End"), "page_up": (0x74, "PgUp"), "page_down": (0x79, "PgDn"),
        "caps_lock": (0x39, "Caps Lock"),
        "f1": (0x7A, "F1"), "f2": (0x78, "F2"), "f3": (0x63, "F3"), "f4": (0x76, "F4"), "f5": (0x60, "F5"),
        "f6": (0x61, "F6"), "f7": (0x62, "F7"), "f8": (0x64, "F8"), "f9": (0x65, "F9"), "f10": (0x6D, "F10"),
        "f11": (0x67, "F11"), "f12": (0x6F, "F12"), "f13": (0x69, "F13"), "f14": (0x6B, "F14"),
        "f15": (0x71, "F15"), "f16": (0x6A, "F16"), "f17": (0x40, "F17"), "f18": (0x4F, "F18"),
        "f19": (0x50, "F19"), "f20": (0x5A, "F20"),
    ]
    static let usVK: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B,
        "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
        ".": 0x2F, "`": 0x32,
    ]

    /// Готовые варианты в меню — как PRESETS Python-версии.
    public static let presets: [(String, String)] = [
        ("alt_r", "Правый Option ⌥  — по умолчанию"), ("alt_l", "Левый Option ⌥"), ("cmd_r", "Правый Command ⌘"),
        ("ctrl_r", "Правый Control ⌃"), ("shift_r", "Правый Shift ⇧"), ("fn", "Fn / 🌐"),
        ("ctrl+space", "⌃ Space"), ("alt+space", "⌥ Space"),
    ]
    public static let escCode: UInt16 = 0x35

    static func modifierName(_ code: UInt16) -> String? { modifierKeys.first { $0.value.0 == code }?.key }
    static func keyName(_ code: UInt16) -> String? {
        special.first { $0.value.0 == code }?.key ?? usVK.first { $0.value == code }?.key
    }
    public static func isModifierKey(_ code: UInt16) -> Bool { modifierName(code) != nil }

    /// Строка хоткея из нажатия при захвате «своего сочетания»; nil — из этого нажатия хоткей не сделать
    /// (голая буква, цифра или пробел сработают при обычном наборе; F1–F20 можно и без модификаторов).
    public static func specFromPress(code: UInt16, flags: UInt64) -> String? {
        if let m = modifierName(code) { return m }
        guard let key = keyName(code) else { return nil }
        let names = modGlyph.map(\.0).filter { flags & modTokens[$0]! != 0 }
        if names.isEmpty && !(key.hasPrefix("f") && Int(key.dropFirst()) != nil) { return nil }
        return (names + [key]).joined(separator: "+")
    }

    /// Что показывать в окне захвата, пока клавиши зажаты: «⌘⇧» + клавиша.
    public static func heldDescription(code: UInt16?, flags: UInt64) -> String {
        if let code, let m = modifierName(code) { return modifierKeys[m]!.2 }
        var parts = modGlyph.filter { flags & modTokens[$0.0]! != 0 }.map(\.1)
        if let code, let k = keyName(code) { parts.append(special[k]?.1 ?? k.uppercased()) }
        return parts.isEmpty ? "…" : parts.joined(separator: " ")
    }

    public static func parse(_ s: String) -> HotkeySpec? {
        let toks = s.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = toks.last, !key.isEmpty else { return nil }
        var mods: UInt64 = 0
        for t in toks.dropLast() {
            guard let m = modTokens[t] else { return nil }
            mods |= m
        }
        let glyphs = modGlyph.filter { mods & modTokens[$0.0]! != 0 }.map(\.1).joined()
        if mods == 0, let (code, dev, label) = modifierKeys[key] {
            return HotkeySpec(keyCode: code, mods: 0, isModifierOnly: true, deviceMask: dev, label: label)
        }
        if let (code, label) = special[key] {
            return HotkeySpec(keyCode: code, mods: mods, isModifierOnly: false, deviceMask: 0, label: glyphs + label)
        }
        if let code = usVK[key] {
            return HotkeySpec(keyCode: code, mods: mods, isModifierOnly: false, deviceMask: 0, label: glyphs + key.uppercased())
        }
        return nil
    }
}
