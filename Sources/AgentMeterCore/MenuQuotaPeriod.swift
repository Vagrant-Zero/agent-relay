import Foundation

public enum MenuQuotaPeriod: String, CaseIterable {
    case fiveHours, weekly, both
    public var title: String {
        switch self {
        case .fiveHours: return "5 小时"
        case .weekly: return "每周"
        case .both: return "同时显示"
        }
    }
    public func text(for quota: QuotaSnapshot?) -> String {
        let windows = [quota?.primary, quota?.secondary].compactMap { $0 }
        func value(_ minutes: Int, _ label: String) -> String {
            let percent = windows.first { $0.windowDurationMins == minutes }.map { "\($0.remainingPercent)%" } ?? "—"
            return "\(label) \(percent)"
        }
        switch self {
        case .fiveHours: return value(300, "5 小时")
        case .weekly: return value(10080, "每周")
        case .both: return value(300, "5 小时") + " · " + value(10080, "每周")
        }
    }
}
