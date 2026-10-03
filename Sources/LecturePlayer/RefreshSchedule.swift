import AppKit
import Core

extension AppStore {
    var refreshPreferenceKey:String { "directoryAttempt-" + digest(library.directoryRoot ?? "none") }
    var nextRefreshText:String {
        switch refreshPolicy {
        case .manual:return "仅在手动刷新或确认目录操作后扫描"
        case .automatic:return "文件变化后自动刷新"
        default:return lastDirectoryAttempt.map { "下次：" + $0.addingTimeInterval(refreshPolicy.interval!).formatted(date:.omitted,time:.shortened) } ?? "等待首次扫描"
        }
    }
    func setRefreshPolicy(_ policy:RefreshPolicy) {
        refreshPolicy=policy
        if watchesEnabled { UserDefaults.standard.set(policy.rawValue,forKey:"directoryRefreshPolicy") }
        configureRefreshSchedule()
        if policy != .manual { refreshIfDue() }
    }
    func configureRefreshSchedule() {
        refreshTimer?.invalidate();refreshTimer=nil
        if refreshPolicy != .automatic { directoryWatch.update([]);rescanRequested=false }
        else if watchesEnabled,let result=scanResult { directoryWatch.update([result.root,result.root.deletingLastPathComponent()]+result.directories) }
        guard watchesEnabled,refreshPolicy.interval != nil else { return }
        refreshTimer=Timer.scheduledTimer(withTimeInterval:30,repeats:true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshIfDue() }
        }
    }
    func refreshIfDue(startup:Bool=false) {
        if refreshPolicy.due(last:lastDirectoryAttempt,now:Date(),startup:startup) { refreshDirectory() }
    }
    func recordDirectoryAttempt() {
        lastDirectoryAttempt=Date()
        if watchesEnabled { UserDefaults.standard.set(lastDirectoryAttempt,forKey:refreshPreferenceKey) }
    }
}
