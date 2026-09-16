import Foundation

/// Cache-aware polling every 30 seconds; prioritize the selected account.
/// Failed requests also respect the interval, so a network failure cannot cause a retry loop.
public struct QuotaRefreshSchedule {
    private var attempts: [String: Date] = [:]
    public init() {}
    public func next(in registry: Registry, now: Date = Date()) -> String? {
        let due = registry.accounts.filter { account in
            let latest = max(account.quota?.fetchedAt ?? .distantPast, attempts[account.id] ?? .distantPast)
            let interval: TimeInterval = 30
            return now.timeIntervalSince(latest) >= interval
        }
        return due.sorted { lhs, rhs in
            if lhs.id == registry.selectedID { return true }
            if rhs.id == registry.selectedID { return false }
            let left = max(lhs.quota?.fetchedAt ?? .distantPast, attempts[lhs.id] ?? .distantPast)
            let right = max(rhs.quota?.fetchedAt ?? .distantPast, attempts[rhs.id] ?? .distantPast)
            return left == right ? lhs.id < rhs.id : left < right
        }.first?.id
    }
    public mutating func started(_ id: String, now: Date = Date()) { attempts[id] = now }
}
