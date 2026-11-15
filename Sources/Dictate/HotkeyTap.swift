import CoreGraphics
import DictateCore
import Foundation

/// Перехват горячей клавиши через CGEventTap (только слушает, события не глотает — как pynput в Python-версии).
/// Нужно разрешение «Мониторинг ввода».
final class HotkeyTap {
    var spec: HotkeySpec
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onEsc: () -> Void = {}
    /// Чужая клавиша, пока хоткей-модификатор зажат (⌘C на правом Command) — не диктовка.
    var onOtherKey: () -> Void = {}
    /// Захват своего сочетания: все события идут сюда (type, code, flags), хоткей не работает.
    var capture: ((CGEventType, UInt16, UInt64) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var down = false

    init(spec: HotkeySpec) { self.spec = spec }

    var active: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ref in
            let me = Unmanaged<HotkeyTap>.fromOpaque(ref!).takeUnretainedValue()
            me.handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        if down { down = false; onRelease() }
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("Хоткей: macOS отключила перехват (\(type == .tapDisabledByTimeout ? "таймаут" : "ввод")) — включил обратно")
            return
        }
        let code = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
        let flags = e.flags.rawValue
        if let capture { capture(type, code, flags); return }
        // наши же синтетические нажатия (⌘V вставки, ⌫ команд) — не действия человека
        let injected = e.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
        if type == .keyDown && code == HotkeySpec.escCode && flags & HotkeySpec.allMods == 0 && !injected { onEsc() }
        if spec.isModifierOnly && down && type == .keyDown && !injected && code != spec.keyCode && !HotkeySpec.isModifierKey(code) {
            onOtherKey()
        }
        if spec.isModifierOnly {
            guard type == .flagsChanged, code == spec.keyCode else { return }
            let pressed = flags & spec.deviceMask != 0
            if pressed && !down { down = true; onPress() }
            else if !pressed && down { down = false; onRelease() }
        } else {
            guard code == spec.keyCode else { return }
            if type == .keyDown {
                if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
                if !down && flags & HotkeySpec.allMods == spec.mods { down = true; onPress() }
            } else if type == .keyUp, down {
                down = false; onRelease()
            }
        }
    }
}

extension HotkeyTap {
    /// Сменить хоткей на лету.
    func setSpec(_ s: HotkeySpec) { if down { down = false; onRelease() }; spec = s }
}
