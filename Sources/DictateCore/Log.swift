import Foundation

/// Журнал dictate.log в каталоге данных: строка с меткой времени, как у Python-версии.
public final class Log: @unchecked Sendable {
    public static let shared = Log()
    private let queue = DispatchQueue(label: "log")
    private var handle: FileHandle?
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    public func open(_ url: URL) {
        queue.sync {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
        }
    }

    public func write(_ s: String) {
        let line = "[\(fmt.string(from: Date()))] \(s)\n"
        queue.async { [weak self] in
            if let d = line.data(using: .utf8) { self?.handle?.write(d) }
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
    }
}

public func log(_ s: String) { Log.shared.write(s) }
