import Foundation
import SQLite3

/// history.sqlite3 — та же схема, что у Python-версии (дашборды и compare_asr читают её же).
public final class History: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "History", code: 1, userInfo: [NSLocalizedDescriptionKey: "не открылась \(path)"])
        }
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS transcriptions (id INTEGER PRIMARY KEY, ts REAL, text TEXT, raw_text TEXT,
            duration REAL, app TEXT, style TEXT, asr_ms REAL, llm_ms REAL, gen_tps REAL, gen_tokens INTEGER, vp_sim REAL)
            """, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    public func insert(text: String, raw: String, duration: Double, app: String, style: String, asrMs: Double,
                       llmMs: Double = 0, genTps: Double? = nil, genTokens: Int? = nil) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "INSERT INTO transcriptions (ts, text, raw_text, duration, app, style, asr_ms, llm_ms, gen_tps, gen_tokens) VALUES (?,?,?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(st) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT
        sqlite3_bind_double(st, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(st, 2, text, -1, T)
        sqlite3_bind_text(st, 3, raw, -1, T)
        sqlite3_bind_double(st, 4, duration)
        sqlite3_bind_text(st, 5, app, -1, T)
        sqlite3_bind_text(st, 6, style, -1, T)
        sqlite3_bind_double(st, 7, asrMs)
        sqlite3_bind_double(st, 8, llmMs)
        if let genTps { sqlite3_bind_double(st, 9, genTps) } else { sqlite3_bind_null(st, 9) }
        if let genTokens { sqlite3_bind_int64(st, 10, Int64(genTokens)) } else { sqlite3_bind_null(st, 10) }
        guard sqlite3_step(st) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    public struct Row {
        public let id: Int64; public let ts: Double; public let text: String; public let raw: String
        public let duration: Double; public let app: String; public let style: String
        public let asrMs: Double?; public let llmMs: Double?; public let genTps: Double?; public let genTokens: Int?
    }

    /// Все строки, свежие первыми (как rows() в dashboard.py).
    public func all() -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "SELECT id, ts, text, raw_text, duration, app, style, asr_ms, llm_ms, gen_tps, gen_tokens FROM transcriptions ORDER BY ts DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        func s(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        func d(_ i: Int32) -> Double? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i) }
        var out: [Row] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(Row(id: sqlite3_column_int64(st, 0), ts: sqlite3_column_double(st, 1), text: s(2), raw: s(3),
                           duration: d(4) ?? 0, app: s(5), style: s(6), asrMs: d(7), llmMs: d(8), genTps: d(9),
                           genTokens: sqlite3_column_type(st, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, 10))))
        }
        return out
    }

    /// Строка из истории Python-версии (импорт): ts и замеры как были. Возвращает новый id.
    @discardableResult
    public func insertImported(_ r: Row) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "INSERT INTO transcriptions (ts, text, raw_text, duration, app, style, asr_ms, llm_ms, gen_tps, gen_tokens) VALUES (?,?,?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(st) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(st, 1, r.ts); sqlite3_bind_text(st, 2, r.text, -1, T); sqlite3_bind_text(st, 3, r.raw, -1, T)
        sqlite3_bind_double(st, 4, r.duration); sqlite3_bind_text(st, 5, r.app, -1, T); sqlite3_bind_text(st, 6, r.style, -1, T)
        for (i, v) in [(7, r.asrMs), (8, r.llmMs), (9, r.genTps)] as [(Int32, Double?)] {
            if let v { sqlite3_bind_double(st, i, v) } else { sqlite3_bind_null(st, i) }
        }
        if let g = r.genTokens { sqlite3_bind_int64(st, 10, Int64(g)) } else { sqlite3_bind_null(st, 10) }
        guard sqlite3_step(st) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    /// Открыть чужую базу (историю Python-версии) только для чтения строк.
    public static func readRows(path: String) -> [Row] {
        guard FileManager.default.fileExists(atPath: path), let h = try? History(path: path) else { return [] }
        return h.all()
    }

    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM transcriptions", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }
}
