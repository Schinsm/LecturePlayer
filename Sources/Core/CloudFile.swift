import Foundation
import Darwin

/// Files in a synced cloud folder (Google Drive, OneDrive, iCloud Drive) can be online-only placeholders.
/// Reading one makes the provider download the whole file first, so scans, fingerprints and thumbnails
/// check here and leave such files alone; opening or transcribing a lesson downloads it explicitly.
public enum CloudFile {
    /// SF_DATALESS: the provider keeps the content in the cloud. Checked with lstat, which never downloads.
    static let datalessFlag: UInt32 = 0x40000000

    /// Tests stand in for the cloud app: which files are placeholders and what starting a download does.
    /// Each test only answers for its own temporary files, so other suites see the real file system.
    public struct Simulation: Sendable {
        public var isOnlineOnly: @Sendable (URL) -> Bool?
        public var startDownload: @Sendable (URL) throws -> Void
        public init(isOnlineOnly: @escaping @Sendable (URL) -> Bool?, startDownload: @escaping @Sendable (URL) throws -> Void) {
            self.isOnlineOnly = isOnlineOnly; self.startDownload = startDownload
        }
    }
    nonisolated(unsafe) public static var simulation: Simulation?

    public static func isOnlineOnly(_ url: URL) -> Bool {
        if let simulated = simulation?.isOnlineOnly(url) { return simulated }
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
        return info.st_flags & datalessFlag != 0
    }

    /// Asks the provider to keep a local copy without waiting for it.
    public static func requestDownload(_ url: URL) {
        guard isOnlineOnly(url) else { return }
        try? start(url)
    }

    /// Downloads an online-only file and reports progress (0…1). Returns at once for local files.
    /// Fails when the provider makes no progress for `stall` seconds; cancelling the task stops waiting.
    public static func download(_ url: URL, stall: Double = 60, poll: Duration = .milliseconds(250),
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard isOnlineOnly(url) else { return }
        let observed = ObservedProgress()
        let token = Progress.addSubscriber(forFileURL: url) { published in
            observed.attach(published); return { observed.detach() }
        }
        defer { Progress.removeSubscriber(token) }
        do { try start(url) }
        catch { throw Failure("无法从云端下载：" + error.localizedDescription) }
        var last = -1.0, lastChange = Date()
        progress(0)
        while isOnlineOnly(url) {
            try Task.checkCancellation()
            let value = observed.fraction
            if value > last { last = value; lastChange = Date(); progress(min(0.99, value)) }
            else if Date().timeIntervalSince(lastChange) > stall { throw Failure("云端下载没有进展，请检查网络或云盘应用后重试") }
            try await Task.sleep(for: poll)
        }
        progress(1)
    }
    private static func start(_ url: URL) throws {
        if let simulation, simulation.isOnlineOnly(url) != nil { try simulation.startDownload(url) }
        else { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
    }
}

/// The provider publishes download progress for the file; the subscriber may be called on any thread.
private final class ObservedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Progress?
    func attach(_ progress: Progress) { lock.lock(); current = progress; lock.unlock() }
    func detach() { lock.lock(); current = nil; lock.unlock() }
    var fraction: Double { lock.lock(); defer { lock.unlock() }; return max(0, current?.fractionCompleted ?? 0) }
}
