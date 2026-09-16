import Foundation
import CSQLite

public struct LocalSession: Codable {
    public let id: String
    public let title: String
    public let cwd: String
    public let updatedAt: Int64
    public let databaseHome: String
    public let rolloutPath: String
    public let source: String
    public let historyMode: String

    /// Keep authentication in the selected profile; history remains in its original database.
    public func resumeArguments(extra: [String] = []) throws -> [String] {
        guard FileManager.default.fileExists(atPath: databaseHome + "/state_5.sqlite") else {
            throw MeterError.message("原会话数据库已不存在，未创建空白会话。")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let quoted = String(data: try encoder.encode(databaseHome), encoding: .utf8)!
        return ["-c", "sqlite_home=\(quoted)", "resume", id] + extra
    }
}

public enum LocalSessions {
    public struct Scan {
        public let sessions: [LocalSession]
        public let warnings: [String]
        public let failedRoots: [String]
    }

    /// Read profiles independently. A locked/broken profile must not hide healthy
    /// profiles or erase the last successfully displayed rows from that profile.
    public static func scan(roots: [URL], retaining previous: [LocalSession] = []) -> Scan {
        var byID: [String: LocalSession] = [:]
        var warnings: [String] = []
        var failedRoots: [String] = []
        for root in roots {
            let rows: [LocalSession]
            do { rows = try list(roots: [root]) }
            catch {
                warnings.append(error.localizedDescription)
                failedRoots.append(root.path)
                rows = previous.filter { $0.databaseHome == root.path }
            }
            for row in rows where byID[row.id].map({ $0.updatedAt < row.updatedAt }) ?? true { byID[row.id] = row }
        }
        return Scan(sessions: byID.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt }, warnings: warnings, failedRoots: failedRoots)
    }
    public static func roots(store: Store, additional: [String] = []) throws -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent(".codex")]
        roots += try store.read().accounts.map { URL(fileURLWithPath: $0.profilePath) }
        for parent in [home.appendingPathComponent(".codex-profiles"), store.root.appendingPathComponent("profiles")] {
            roots += (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        }
        roots += additional.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        var seen = Set<String>()
        return roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { seen.insert($0.path).inserted }
    }

    public static func list(roots: [URL]) throws -> [LocalSession] {
        var sessions: [String: LocalSession] = [:]
        for root in roots {
            let path = root.appendingPathComponent("state_5.sqlite").path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
                if let db { sqlite3_close(db) }
                throw MeterError.message("无法读取会话数据库：\(path)（\(reason)）")
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 3000)
            var stmt: OpaquePointer?
            let sql = "SELECT id, title, cwd, updated_at, rollout_path, source, history_mode FROM threads WHERE archived = 0 ORDER BY updated_at DESC"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MeterError.message("无法读取会话索引：\(path)（\(String(cString: sqlite3_errmsg(db)))）")
            }
            defer { sqlite3_finalize(stmt) }
            func string(_ column: Int32) -> String {
                sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
            }
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
                let session = LocalSession(id: string(0), title: string(1), cwd: string(2), updatedAt: sqlite3_column_int64(stmt, 3), databaseHome: root.path, rolloutPath: string(4), source: string(5), historyMode: string(6))
                // Prefer the newest entry if a profile was previously copied.
                if sessions[session.id].map({ $0.updatedAt < session.updatedAt }) ?? true { sessions[session.id] = session }
                result = sqlite3_step(stmt)
            }
            guard result == SQLITE_DONE else { throw MeterError.message("读取会话中断：\(path)（\(String(cString: sqlite3_errmsg(db)))）") }
        }
        return sessions.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt }
    }
}
