import Foundation
import CoreFoundation

public struct Identity {
    public let email: String
    public let plan: String
}

public enum QuotaDecoder {
    public static func decode(_ value: [String: Any], now: Date = Date()) throws -> QuotaSnapshot {
        func number(_ raw: Any?) -> Double? {
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        func integer(_ raw: Any?) -> Int? {
            guard let value = number(raw), value >= 0, value < Double(Int.max), value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        }
        guard let limits = ((value["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any])
            ?? value["rateLimits"] as? [String: Any] else { throw MeterError.message("官方未提供此账号的 Codex 额度。") }
        func window(_ raw: Any?) throws -> QuotaWindow? {
            guard let object = raw as? [String: Any] else { return nil }
            guard let used = number(object["usedPercent"]), used >= 0 else {
                throw MeterError.message("官方返回的额度格式无法识别。")
            }
            return QuotaWindow(usedPercent: used, windowDurationMins: integer(object["windowDurationMins"]).flatMap { $0 > 0 ? $0 : nil },
                               resetsAt: number(object["resetsAt"]).flatMap { $0 >= 0 ? $0 : nil })
        }
        let count = integer((value["rateLimitResetCredits"] as? [String: Any])?["availableCount"])
        return try QuotaSnapshot(primary: window(limits["primary"]), secondary: window(limits["secondary"]),
                                 resetCards: count.flatMap { $0 >= 0 ? $0 : nil }, fetchedAt: now)
    }
}

public final class AccountService {
    public let store: Store
    public let cancellation: Cancellation
    public init(store: Store, cancellation: Cancellation = Cancellation()) { self.store = store; self.cancellation = cancellation }
    public func identity(_ client: RPCClient) throws -> Identity {
        let result = try client.request("account/read", params: ["refreshToken": false])
        guard let account = result["account"] as? [String: Any],
              let email = account["email"] as? String, !email.isEmpty else {
            throw MeterError.message("此账号尚未完成 ChatGPT 登录，请重新登录。")
        }
        return Identity(email: email, plan: account["planType"] as? String ?? "未知套餐")
    }
    public func validate(_ account: Account) throws {
        let client = try RPCClient(profile: account.profilePath, cancellation: cancellation)
        defer { client.stop() }
        let identity = try identity(client)
        guard identity.email.caseInsensitiveCompare(account.email) == .orderedSame else {
            throw MeterError.message("此目录中的登录身份已改变，请重新添加账号。")
        }
        // account/read can return a cached identity. Check an authenticated endpoint
        // before replacing a working desktop or committing a new CLI default.
        _ = try client.request("account/rateLimits/read")
    }
    @discardableResult public func importProfile(alias: String, path: String) throws -> Account {
        try store.locked {
            var registry = try store.read()
            let alias = try store.uniqueAlias(alias, in: registry)
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw MeterError.message("所选配置目录不存在。")
            }
            guard !registry.accounts.contains(where: { URL(fileURLWithPath: $0.profilePath).resolvingSymlinksInPath() == url }) else {
                throw MeterError.message("此账号目录已经添加。")
            }
            let client = try RPCClient(profile: url.path, cancellation: cancellation)
            defer { client.stop() }
            let identity = try identity(client)
            var account = Account(alias: alias, email: identity.email, plan: identity.plan, profilePath: url.path, managed: false)
            do { account.quota = try QuotaDecoder.decode(client.request("account/rateLimits/read")) }
            catch { account.lastError = error.localizedDescription }
            registry.accounts.append(account)
            if registry.selectedID == nil { registry.selectedID = account.id }
            try store.write(registry)
            return account
        }
    }
    @discardableResult public func login(alias: String, openURL: (URL) throws -> Void) throws -> Account {
        try store.locked {
            var registry = try store.read()
            let alias = try store.uniqueAlias(alias, in: registry)
            let id = UUID().uuidString.lowercased()
            let profile = store.root.appendingPathComponent("profiles/\(id)", isDirectory: true)
            try Store.privateDirectory(profile)
            var committed = false
            defer { if !committed { try? FileManager.default.removeItem(at: profile) } }
            // Let the official client own token refresh. Each account has exactly one canonical home.
            let config = "cli_auth_credentials_store = \"file\"\n"
            try Data(config.utf8).write(to: profile.appendingPathComponent("config.toml"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.appendingPathComponent("config.toml").path)
            let client = try RPCClient(profile: profile.path, cancellation: cancellation)
            defer { client.stop() }
            let result = try client.request("account/login/start", params: ["type": "chatgpt"])
            guard let address = result["authUrl"] as? String, let url = URL(string: address),
                  url.scheme == "https", let host = url.host?.lowercased(),
                  ["auth.openai.com", "chatgpt.com", "auth0.openai.com"].contains(host),
                  let loginID = result["loginId"] as? String else { throw MeterError.message("官方客户端未返回受支持的官方登录地址。") }
            try openURL(url)
            try client.waitForLogin(loginID)
            let identity = try identity(client)
            let auth = profile.appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: auth.path) else { throw MeterError.message("登录成功，但官方凭据文件未写入。") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
            var account = Account(id: id, alias: alias, email: identity.email, plan: identity.plan, profilePath: profile.path, managed: true)
            do { account.quota = try QuotaDecoder.decode(client.request("account/rateLimits/read")) }
            catch { account.lastError = error.localizedDescription }
            registry.accounts.append(account)
            if registry.selectedID == nil { registry.selectedID = account.id }
            try store.write(registry); committed = true
            return account
        }
    }
    @discardableResult public func refresh(_ name: String? = nil) throws -> [Account] {
        try store.locked {
            var registry = try store.read()
            let selected = try name.map { try registry.account($0).id }
            var changed: [Account] = []
            for index in registry.accounts.indices where selected == nil || registry.accounts[index].id == selected {
                try cancellation.check()
                var account = registry.accounts[index]
                do {
                    let client = try RPCClient(profile: account.profilePath, cancellation: cancellation)
                    defer { client.stop() }
                    let identity = try identity(client)
                    guard identity.email.caseInsensitiveCompare(account.email) == .orderedSame else { throw MeterError.message("登录身份已改变，请重新添加账号。") }
                    account.plan = identity.plan
                    account.quota = try QuotaDecoder.decode(client.request("account/rateLimits/read"))
                    account.lastError = nil
                } catch {
                    try cancellation.check()
                    account.lastError = error.localizedDescription
                }
                registry.accounts[index] = account
                changed.append(account)
                try store.write(registry)
            }
            return changed
        }
    }
    public func remove(_ name: String) throws {
        try store.locked {
            var registry = try store.read()
            let account = try registry.account(name)
            if let session = registry.desktop, session.accountID == account.id,
               DesktopController.isAlive(session.processID) { throw MeterError.message("此账号的桌面端仍在运行，请先退出桌面端。") }
            // Remove the registration only. Keep credentials/history for running CLI sessions and recovery.
            registry.accounts.removeAll { $0.id == account.id }
            if registry.selectedID == account.id { registry.selectedID = registry.accounts.first?.id }
            try store.write(registry)
        }
    }
    public func selectCLI(_ name: String) throws {
        try store.locked {
            var registry = try store.read()
            let account = try registry.account(name)
            try validate(account)
            registry.selectedID = account.id
            try store.write(registry)
        }
    }
}
