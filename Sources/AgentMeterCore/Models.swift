import Foundation

public enum MeterError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct QuotaWindow: Codable, Equatable {
    public var usedPercent: Double
    public var windowDurationMins: Int?
    public var resetsAt: Double?
    public var remainingPercent: Int { Int(max(0, min(100, 100 - usedPercent)).rounded()) }
    public var label: String {
        guard let minutes = windowDurationMins else { return "额度" }
        if minutes == 10080 { return "每周" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }
}
public struct QuotaSnapshot: Codable, Equatable {
    public var primary: QuotaWindow?
    public var secondary: QuotaWindow?
    public var resetCards: Int?
    public var resetCardExpirations: [Double]? = nil
    public var resetCardExpiryIsPartial: Bool? = nil
    public func nextResetCardExpiration(at now: Date = Date()) -> Double? {
        guard (resetCards ?? 0) > 0 else { return nil }
        return resetCardExpirations?.filter { $0 > now.timeIntervalSince1970 }.min()
    }
    public var resetCardExpiryText: String? {
        guard let expiry = nextResetCardExpiration() else { return nil }
        return "重置卡\(resetCardExpiryIsPartial == true ? "已知" : "")最近到期：\(Format.reset(expiry))"
    }
    public var fetchedAt: Date
    public var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 300 }
}
public struct Account: Codable, Equatable, Identifiable {
    public var id: String
    public var alias: String
    public var provider: String = "codex"
    public var email: String
    public var plan: String
    public var profilePath: String
    public var managed: Bool
    public var quota: QuotaSnapshot?
    public var lastError: String?
    public var createdAt: Date = Date()
    public init(id: String = UUID().uuidString.lowercased(), alias: String, email: String, plan: String, profilePath: String, managed: Bool) {
        self.id = id; self.alias = alias; self.email = email; self.plan = plan
        self.profilePath = profilePath; self.managed = managed
    }
}
public struct DesktopSession: Codable {
    public var accountID: String
    public var processID: Int32
    public var nonce: String
    public var statePath: String
    public var appPath: String
    public var startedAt: Date
}
public struct Registry: Codable {
    public var version: Int = 1
    public var accounts: [Account] = []
    public var selectedID: String?
    public var desktop: DesktopSession?
    public init() {}
    public var selected: Account? { accounts.first { $0.id == selectedID } }
    public func account(_ name: String) throws -> Account {
        guard let account = accounts.first(where: { $0.id == name || $0.alias.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw MeterError.message("找不到账号：\(name)")
        }
        return account
    }
}
public struct BridgeState: Codable {
    public var nonce: String
    public var accountVerified: Bool
    public var activeTurns: Int
    public var trackingReliable: Bool
    public var bridgePID: Int32
    public var childPID: Int32
    public var updatedAt: Double
}

public enum Format {
    public static func reset(_ seconds: Double?) -> String {
        guard let seconds else { return "重置时间未知" }
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm" : "M/d HH:mm"
        return formatter.string(from: date)
    }
    public static func updated(_ date: Date?) -> String {
        guard let date else { return "尚未查询" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前更新" }
        return "\(seconds / 3600) 小时前更新"
    }
}
