import Foundation
import Darwin

public final class Store {
    public let root: URL
    public var registryURL: URL { root.appendingPathComponent("accounts.json") }
    public init(root: URL? = nil) throws {
        self.root = root ?? ProcessInfo.processInfo.environment["AGENT_METER_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Meter Preview", isDirectory: true)
        try Self.privateDirectory(self.root)
    }
    public static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    public func read() throws -> Registry {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return Registry() }
        let data = try Data(contentsOf: registryURL)
        guard data.count < 2_000_000 else { throw MeterError.message("账号文件过大，停止读取。") }
        let result = try JSONDecoder().decode(Registry.self, from: data)
        guard result.version == 1 else { throw MeterError.message("账号文件版本不兼容。") }
        return result
    }
    public func write(_ registry: Registry) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try data.write(to: registryURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registryURL.path)
        DistributedNotificationCenter.default().postNotificationName(.init("dev.local.agent-meter.changed"), object: nil, userInfo: nil, deliverImmediately: true)
    }
    public func locked<T>(_ operation: () throws -> T) throws -> T {
        let path = root.appendingPathComponent("operation.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MeterError.message("无法锁定账号存储。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MeterError.message("另一个登录、刷新或切换正在进行，请稍后重试。") }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
    public func uniqueAlias(_ alias: String, in registry: Registry) throws -> String {
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 48, !clean.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else {
            throw MeterError.message("账号别名需为 1–48 个可见字符。")
        }
        guard !registry.accounts.contains(where: { $0.alias.caseInsensitiveCompare(clean) == .orderedSame }) else {
            throw MeterError.message("此别名已存在。")
        }
        guard registry.accounts.count < 100 else { throw MeterError.message("预览版最多管理 100 个账号。") }
        return clean
    }
}

public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func check() throws { if isCancelled { throw MeterError.message("操作已取消。") } }
}

public enum CodexEnvironment {
    public static func clean(profile: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["CODEX_HOME", "CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_APP_SERVER_WS_URL", "CODEX_CLI_PATH", "CODEX_ELECTRON_USER_DATA_PATH", "CODEX_APP_SERVER_FORCE_CLI", "ELECTRON_RUN_AS_NODE"] {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = profile
        return environment
    }
    public static func executable() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENT_METER_CODEX"] {
            guard FileManager.default.isExecutableFile(atPath: override) else { throw MeterError.message("AGENT_METER_CODEX 指定的文件不可执行。") }
            return URL(fileURLWithPath: override)
        }
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: path) }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw MeterError.message("未找到官方 Codex CLI。请安装 Codex，或设置 AGENT_METER_CODEX。")
    }
}
