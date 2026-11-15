import AppKit
import DictateCore
import Security

/// Автообновление из GitHub Releases kkdclaw/dictate-swift. Как у Python-версии: «О программе» → «Обновить»,
/// галка «Автообновление» и период (auto_update_every: day / week / month) — проверка через 3 мин после запуска,
/// дальше по периоду и только в простое. Отличие: ставится собранное .app из релиза, а не git pull + uv sync.
///
/// Безопасность: новое приложение принимается, только если оно подписано тем же сертификатом, что и текущее
/// (designated requirement самого себя) — подменённый архив не встанет. Репо приватный: токен только на чтение —
/// в связке ключей (служба dictate-swift-github); репо публичный — без токена.
final class Updater {
    static let repo = "kkdclaw/dictate-swift"
    static let keychainService = "dictate-swift-github"

    let config: Config
    var isIdle: () -> Bool = { true }
    private(set) var lastCheck: Date?
    private(set) var lastResult = "ещё не проверялось"
    private(set) var busy = false
    private var timer: Timer?

    init(config: Config) { self.config = config }

    var auto: Bool { config.bool("auto_update", true) }
    var period: TimeInterval {
        switch config.string("auto_update_every", "day") { case "week": 7 * 86400; case "month": 30 * 86400; default: 86400 }
    }

    func startSchedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in self?.tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard auto, !busy, isIdle() else { return }
        if let l = lastCheck, Date().timeIntervalSince(l) < period { return }
        log("Автообновление: пора проверить GitHub")
        check(manual: false)
    }

    static func token() -> String? {
        var item: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }, pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func request(_ url: URL, accept: String = "application/vnd.github+json") -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        if let t = Updater.token() { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    /// Проверить и (если есть новее) поставить. manual — окно с итогом; авто — только журнал, окно при провале.
    func check(manual: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { DispatchQueue.main.async { self.busy = false } }
            do {
                let (data, resp) = try await URLSession.shared.data(for: request(URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    throw Fail(code == 404 ? "релиз не найден (релизов ещё нет; для приватного репо — токен в связке ключей «\(Updater.keychainService)»)"
                                           : "GitHub ответил \(code)")
                }
                lastCheck = Date()
                guard let rel = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = rel["tag_name"] as? String else { throw Fail("непонятный ответ GitHub") }
                let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard Updater.newer(ver, than: AppInfo.version) else {
                    lastResult = "установлена последняя (\(AppInfo.version))"
                    log("Обновление: \(lastResult)")
                    if manual { await alert("Обновлений нет", "Установлена последняя версия \(AppInfo.version).") }
                    return
                }
                guard let assets = rel["assets"] as? [[String: Any]],
                      let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                      let apiURL = (asset["url"] as? String).flatMap(URL.init(string:)) else { throw Fail("в релизе \(tag) нет архива .zip") }
                log("Обновление: доступна \(ver) — ставлю…")
                let (zip, r2) = try await URLSession.shared.download(for: request(apiURL, accept: "application/octet-stream"))
                guard (r2 as? HTTPURLResponse)?.statusCode == 200 else { throw Fail("архив не скачался") }
                try install(zip: zip, version: ver)
                lastResult = "обновлено до \(ver)"
                log("Обновлено до \(ver) — перезапускаюсь")
                await MainActor.run { Updater.relaunch() }
            } catch {
                let why = (error as? Fail)?.why ?? error.localizedDescription
                lastResult = "ошибка — \(why)"
                log("Обновление: \(lastResult)")
                // вручную — всегда окно; фоном — только если сломалась установка (нет сети, GitHub молчит — лишь журнал)
                if manual || !(error is Fail || error is URLError) { await alert("Обновление не удалось", why) }
            }
        }
    }

    struct Fail: Error { let why: String; init(_ w: String) { why = w } }

    /// Распаковать, проверить подпись тем же сертификатом, заменить /Applications/Dictate.app.
    private func install(zip: URL, version: String) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, tmp.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Fail("архив не распаковался") }
        let newApp = tmp.appendingPathComponent("Dictate.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw Fail("в архиве нет Dictate.app") }
        try verifySameSigner(newApp)
        let newVer = Bundle(url: newApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard newVer == version else { throw Fail("в архиве версия \(newVer), а релиз \(version)") }
        let dest = URL(fileURLWithPath: "/Applications/Dictate.app")
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: newApp)
    }

    /// Новое приложение должно удовлетворять designated requirement текущего: тот же identifier и сертификат.
    func verifySameSigner(_ app: URL) throws {
        var selfCode: SecCode?, req: SecRequirement?, newCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyDesignatedRequirement(unsafeBitCast(selfCode, to: SecStaticCode.self), [], &req) == errSecSuccess, let req
        else { throw Fail("не прочитал собственную подпись") }
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else { throw Fail("подпись нового приложения не читается") }
        let st = SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req)
        guard st == errSecSuccess else { throw Fail("подпись нового приложения не та (код \(st)) — не ставлю") }
    }

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open '/Applications/Dictate.app'"]
        try? p.run()
        NSApp.terminate(nil)
    }

    @MainActor private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}
