import AVFoundation
import Foundation
import Core

final class MediaAccessLease: @unchecked Sendable {
    let url: URL
    private let lock=NSLock()
    private var scoped: Bool
    init(_ url: URL) { self.url=url; scoped=url.startAccessingSecurityScopedResource() }
    func release() { lock.lock();defer{lock.unlock()};if scoped {url.stopAccessingSecurityScopedResource();scoped=false} }
    deinit {release()}
}
struct PreparedMedia: @unchecked Sendable { let lease: MediaAccessLease; let asset: AVURLAsset; let duration: Double; let hasAudio: Bool }
private final class MediaResult: @unchecked Sendable {
    private let lock=NSLock();private var value: Result<PreparedMedia,Error>?
    func set(_ value: Result<PreparedMedia,Error>) {lock.lock();self.value=value;lock.unlock()}
    func get() throws -> PreparedMedia {lock.lock();defer{lock.unlock()};return try value?.get() ?? {throw Failure("媒体准备超时，请重试载入")}()}
}
enum MediaPreparation {
    static func load(_ source: MediaSource, timeout: Double) async throws -> PreparedMedia {
        let result=MediaResult()
        // Race callback completion with the same cancellable five-second gate used
        // for seeks. No continuation is left waiting for a filesystem/AV callback.
        let taskBox=PreparationTaskBox()
        let ok=await PlaybackCallback.wait(seconds:timeout) { done in
            let task=Task.detached(priority:.userInitiated) {
                do {
                    var stale=false
                    let url=try source.bookmark.map {try URL(resolvingBookmarkData:$0,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)} ?? URL(fileURLWithPath:source.path)
                    let lease=MediaAccessLease(url);try Task.checkCancellation();try ImportPlanner.requireLocal(url)
                    let asset=AVURLAsset(url:url)
                    let value=try await withTaskCancellationHandler(operation: {
                        guard try await asset.load(.isPlayable) else {throw Failure("无法播放此媒体编码")}
                        let duration=try await asset.load(.duration).seconds
                        let audio=try await asset.loadTracks(withMediaType:.audio)
                        try Task.checkCancellation()
                        return PreparedMedia(lease:lease,asset:asset,duration:duration,hasAudio:!audio.isEmpty)
                    }, onCancel:{asset.cancelLoading()})
                    result.set(.success(value));done(true)
                } catch {result.set(.failure(error));done(true)}
            }
            taskBox.set(task)
        }
        if !ok {taskBox.cancel();try Task.checkCancellation();throw Failure("媒体准备超时，请重试载入")}
        return try result.get()
    }
}
private final class PreparationTaskBox: @unchecked Sendable {
    private let lock=NSLock();private var task:Task<Void,Never>?;private var cancelled=false
    func set(_ task:Task<Void,Never>) {lock.lock();defer{lock.unlock()};self.task=task;if cancelled {task.cancel()}}
    func cancel() {lock.lock();defer{lock.unlock()};cancelled=true;task?.cancel()}
}
