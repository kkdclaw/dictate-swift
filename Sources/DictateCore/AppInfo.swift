import Foundation

public enum AppInfo {
    /// Версия из Info.plist собранного .app; вне бандла (swift run) — «dev».
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Сборка (коммит) из CFBundleVersion — build.sh пишет туда `git describe`.
    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    /// Каталог данных приложения: ~/Library/Application Support/Dictate.
    public static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
    }
}
