import Foundation
public enum RefreshPolicy: String, CaseIterable, Identifiable, Sendable {
    case automatic, quarterHour, hourly, manual
    public var id: String { rawValue }
    public var title: String { switch self { case .automatic: return "自动";case .quarterHour:return "每 15 分钟";case .hourly:return "每小时";case .manual:return "仅手动" } }
    public var interval: TimeInterval? { switch self {case .quarterHour:return 900;case .hourly:return 3600;default:return nil} }
    public func due(last:Date?,now:Date,startup:Bool=false)->Bool {
        if self == .manual { return false }
        if self == .automatic { return startup || last == nil || now.timeIntervalSince(last!) >= 900 }
        guard let last else { return true };return now.timeIntervalSince(last) >= interval!
    }
}
