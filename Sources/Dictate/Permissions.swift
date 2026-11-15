import AppKit
import AVFoundation
import CoreGraphics
import IOKit.hid

/// Три разрешения macOS: Микрофон (запись), Мониторинг ввода (перехват хоткея), Универсальный доступ (⌘V).
/// Выдаются приложению Dictate.app, а не интерпретатору, как было у Python-версии.
enum Permission: CaseIterable {
    case microphone, inputMonitoring, accessibility

    var title: String {
        switch self {
        case .microphone: "Микрофон"
        case .inputMonitoring: "Мониторинг ввода"
        case .accessibility: "Универсальный доступ"
        }
    }

    /// Как пункт называется в английской macOS (System Settings → Privacy & Security).
    var english: String {
        switch self {
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        }
    }

    var why: String {
        switch self {
        case .microphone: "чтобы записывать голос, пока зажата горячая клавиша"
        case .inputMonitoring: "чтобы слышать горячую клавишу в любом приложении"
        case .accessibility: "чтобы вставлять распознанный текст (⌘V) в активное поле"
        }
    }

    var granted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .accessibility: AXIsProcessTrusted()
        }
    }

    /// Системный запрос. Если macOS его не показала (уже отказано, сменилась подпись сборки) —
    /// окно с объяснением и кнопкой в нужную панель Настроек.
    func request(_ done: @escaping () -> Void = {}) {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: done) }
                return
            }
        case .inputMonitoring:
            // IOHIDRequestAccess показывает запрос и вносит приложение в список «Мониторинг ввода»;
            // CGRequestListenEventAccess на новых macOS бывает молчит
            // попытка создать перехват — то, что вносит приложение в список «Мониторинга ввода»;
            // без неё Dictate в списке не появлялся (14.11, пришлось добавлять «+»)
            if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                         eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
                                         callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil) {
                CFMachPortInvalidate(t)
            }
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                _ = CGRequestListenEventAccess()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if !granted { explain() }; done() }
                return
            }
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if AXIsProcessTrustedWithOptions(opts) { done(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if !granted { explain() }; done() }
            return
        }
        if !granted { explain() }
        done()
    }

    /// Окно: что включить и где; кнопка открывает панель Настроек и показывает Dictate.app в Finder
    /// (если приложения нет в списке — «+» или перетащить его туда).
    func explain() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Dictate нужно разрешение «\(title)» (\(english))"
        a.informativeText = """
            Оно нужно, \(why).

            В Настройках → Конфиденциальность и безопасность → «\(title)» \
            (System Settings → Privacy & Security → \(english)) включите Dictate. \
            Если Dictate нет в списке — нажмите «+» и выберите Dictate в «Программах» \
            (или перетащите его из окна Finder, которое откроется рядом).
            """
        a.addButton(withTitle: "Открыть Настройки")
        a.addButton(withTitle: "Позже")
        if a.runModal() == .alertFirstButtonReturn {
            openSettings()
            if self != .microphone { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
        }
    }

    func openSettings() {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .accessibility: "Privacy_Accessibility"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
