import Foundation
import AgentMeterCore
import CSQLite

final class CoreTests {
    func testQuotaRefreshSchedule() {
        let now = Date(timeIntervalSince1970: 1800000000)
        var registry = Registry()
        registry.accounts = ["a", "b"].map { Account(id: $0, alias: $0, email: "test@example.invalid", plan: "pro", profilePath: "/tmp/" + $0, managed: false) }
        registry.selectedID = "b"
        var schedule = QuotaRefreshSchedule()
        expectEqual(schedule.next(in: registry, now: now), "b")
        schedule.started("b", now: now)
        expectEqual(schedule.next(in: registry, now: now), "a")
        schedule.started("a", now: now)
        expectNil(schedule.next(in: registry, now: now.addingTimeInterval(29)))
        expectEqual(schedule.next(in: registry, now: now.addingTimeInterval(30)), "b")
        // A manual refresh postpones the next background request for that account.
        let data = Data("{\"fetchedAt\":\(now.addingTimeInterval(20).timeIntervalSinceReferenceDate)}".utf8)
        registry.accounts[1].quota = try! JSONDecoder().decode(QuotaSnapshot.self, from: data)
        expectEqual(schedule.next(in: registry, now: now.addingTimeInterval(30)), "a")
        schedule.started("a", now: now.addingTimeInterval(30))
        expectNil(schedule.next(in: registry, now: now.addingTimeInterval(49)))
        expectEqual(schedule.next(in: registry, now: now.addingTimeInterval(50)), "b")
    }

    func testSessionScanRetainsRowsAndRecoversAfterLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = [root.appendingPathComponent("a"), root.appendingPathComponent("b")]
        for (index, directory) in roots.enumerated() {
            try Store.privateDirectory(directory)
            var db: OpaquePointer?
            expectEqual(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let sql = "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,updated_at INTEGER,rollout_path TEXT,source TEXT,history_mode TEXT,archived INTEGER); INSERT INTO threads VALUES('\(index)','test','/tmp',1,'/tmp/rollout','cli','paginated',0);"
            expectEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        let initial = LocalSessions.scan(roots: roots)
        expectEqual(initial.sessions.count, 2)
        var locked: OpaquePointer?
        expectEqual(sqlite3_open(roots[1].appendingPathComponent("state_5.sqlite").path, &locked), SQLITE_OK)
        defer { sqlite3_close(locked) }
        expectEqual(sqlite3_exec(locked, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        let firstOpen = LocalSessions.scan(roots: roots)
        expectEqual(firstOpen.sessions.count, 1)
        expectEqual(firstOpen.failedRoots, [roots[1].path])
        let refresh = LocalSessions.scan(roots: roots, retaining: initial.sessions)
        expectEqual(refresh.sessions.count, 2)
        expectEqual(refresh.warnings.count, 1)
        expectEqual(sqlite3_exec(locked, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        let recovered = LocalSessions.scan(roots: roots)
        expectEqual(recovered.sessions.count, 2)
        expectEqual(recovered.warnings.count, 0)
    }
    func testQuotaDistinguishesUnknownAndZeroResetCards() throws {
        let limits: [String: Any] = ["primary": ["usedPercent": 25.0, "windowDurationMins": 300, "resetsAt": 1_800_000_000.0]]
        let unknown = try QuotaDecoder.decode(["rateLimits": limits, "rateLimitResetCredits": NSNull()])
        let zero = try QuotaDecoder.decode(["rateLimits": limits, "rateLimitResetCredits": ["availableCount": 0, "credits": []]])
        let countOnly = try QuotaDecoder.decode(["rateLimits": limits, "rateLimitResetCredits": ["availableCount": 7, "credits": []]])
        expectNil(unknown.resetCards)
        expectEqual(zero.resetCards, 0)
        expectEqual(countOnly.resetCards, 7)
        expectEqual(unknown.primary?.remainingPercent, 75)
    }
    func testCodexBucketAndVariableWindows() throws {
        let value: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 90.0]],
                                   "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 10.0, "windowDurationMins": 60]]]]
        let result = try QuotaDecoder.decode(value)
        expectEqual(result.primary?.remainingPercent, 90)
        expectEqual(result.primary?.label, "1 小时")
        expectNil(result.secondary)
        expectNil(result.primary?.resetsAt)
    }
    func testInvalidQuotaNeverBecomesFullQuota() throws {
        expectThrows(try QuotaDecoder.decode([:]))
        expectThrows(try QuotaDecoder.decode(["rateLimits": ["primary": ["usedPercent": "broken"]]]))
        expectThrows(try QuotaDecoder.decode(["rateLimits": ["primary": ["usedPercent": -5.0]]]))
        expectThrows(try QuotaDecoder.decode(["rateLimits": ["primary": ["usedPercent": true]]]))
        let exhausted = try QuotaDecoder.decode(["rateLimits": ["primary": ["usedPercent": 110.0]]])
        expectEqual(exhausted.primary?.remainingPercent, 0)
    }
    func testStorePermissionsAtomicityAndLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        var registry = Registry()
        registry.accounts = [Account(alias: "个人", email: "test@example.com", plan: "pro", profilePath: "/tmp/example", managed: true)]
        registry.selectedID = registry.accounts[0].id
        try store.locked {
            try store.write(registry)
            let second = try Store(root: root)
            expectThrows(try second.locked {})
        }
        expectEqual(try store.read().selected?.alias, "个人")
        let mode = try FileManager.default.attributesOfItem(atPath: store.registryURL.path)[.posixPermissions] as? Int
        expectEqual(mode, 0o600)
        expectThrows(try store.uniqueAlias("个人", in: registry))
        expectThrows(try store.uniqueAlias("\n", in: registry))
    }
    func testCancellation() throws {
        let cancellation = Cancellation()
        expectNoThrow(try cancellation.check())
        cancellation.cancel()
        expectThrows(try cancellation.check())
    }
    func testCredentialOverridesAreRemoved() {
        let environment = CodexEnvironment.clean(profile: "/example/profile")
        expectEqual(environment["CODEX_HOME"], "/example/profile")
        for key in ["OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_CLI_PATH", "CODEX_APP_SERVER_WS_URL"] { expectNil(environment[key]) }
    }
}

func expectEqual<T: Equatable>(_ value: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    guard value == expected else { fatalError("Expected \(expected), got \(value)", file: file, line: line) }
}
func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    guard value == nil else { fatalError("Expected nil", file: file, line: line) }
}
func expectThrows<T>(_ operation: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try operation() } catch { return }
    fatalError("Expected an error", file: file, line: line)
}
func expectNoThrow<T>(_ operation: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try operation() } catch { fatalError("Unexpected error: \(error)", file: file, line: line) }
}

@main struct CoreChecks {
    static func main() throws {
        let checks = CoreTests()
        try checks.testQuotaDistinguishesUnknownAndZeroResetCards()
        try checks.testCodexBucketAndVariableWindows()
        try checks.testInvalidQuotaNeverBecomesFullQuota()
        try checks.testStorePermissionsAtomicityAndLock()
        try checks.testCancellation()
        checks.testCredentialOverridesAreRemoved()
        try checks.testSessionScanRetainsRowsAndRecoversAfterLock()
        checks.testQuotaRefreshSchedule()
        print("8 core checks passed")
    }
}
