import AVFoundation
import Combine
import Foundation

struct PlaybackSnapshot: Equatable, Sendable {
    var lessonID: UUID?
    var seconds: Double = 0
    var sampledAt: Double = 0
}

/// Coalesces actual media samples from the players. Only one main-thread delivery
/// may be queued; delivery reads the latest sample instead of replaying stale ticks.
@MainActor final class PlaybackClock: ObservableObject {
    @Published private(set) var snapshot = PlaybackSnapshot()
    private var observers: [(AVPlayer,Any)] = []
    private var token = UUID()
    private let delivery = ClockDeliveryGate()
    private var samples = MediaTimeSamples()
    var sampled: ((Double) -> Void)?
    func observe(_ sources: [(UUID,AVPlayer,Double)]) {
        detach();let current=token;let samples=self.samples
        for (id,player,offset) in sources {
            let observer=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.1,preferredTimescale:600),queue:DispatchQueue(label:"LecturePlayer.mediaClock.\(id)")) { [weak self, samples, delivery] time in
                // CMTime is supplied by AVFoundation on this background queue.
                // Never synchronously ask AVPlayer.currentTime() on the UI tick.
                guard time.seconds.isFinite else{return}
                samples.set(time.seconds-offset,id:id)
                guard samples.isSelected(id),delivery.begin() else{return}
                let queuedAt=ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { [weak self] in
                    delivery.end()
                    guard let self,self.token==current,let latest=samples.selectedTime else{return}
                    PerformanceTrace.record("clock.deliveryDelay",ProcessInfo.processInfo.systemUptime-queuedAt)
                    self.sampled?(max(0,latest))
                }
            }
            observers.append((player,observer))
        }
    }
    func select(_ id: UUID) {samples.select(id)}
    func latest(_ id: UUID?) -> Double? {id.flatMap{samples.value($0)}}
    func publish(_ seconds: Double, lesson: UUID?) {
        guard seconds.isFinite else { return }
        if snapshot.lessonID != lesson || abs(snapshot.seconds - seconds) > 0.001 {
            snapshot = PlaybackSnapshot(lessonID: lesson, seconds: max(0, seconds), sampledAt: ProcessInfo.processInfo.systemUptime)
        }
    }
    func detach() { token=UUID();for (player,observer) in observers {player.removeTimeObserver(observer)};observers.removeAll();samples=MediaTimeSamples() }
}
private final class MediaTimeSamples: @unchecked Sendable {
    private let lock=NSLock();private var times:[UUID:Double]=[:];private var selected:UUID?
    func set(_ time:Double,id:UUID) {lock.lock();times[id]=time;lock.unlock()}
    func select(_ id:UUID) {lock.lock();selected=id;lock.unlock()}
    func clear() {lock.lock();times.removeAll();selected=nil;lock.unlock()}
    func value(_ id:UUID)->Double? {lock.lock();defer{lock.unlock()};return times[id]}
    func isSelected(_ id:UUID)->Bool {lock.lock();defer{lock.unlock()};return selected==id}
    var selectedTime:Double? {lock.lock();defer{lock.unlock()};return selected.flatMap{times[$0]}}
}

final class ClockDeliveryGate: @unchecked Sendable {
    private let lock = NSLock(); private var pending = false
    func begin() -> Bool { lock.lock(); defer { lock.unlock() }; guard !pending else { return false }; pending = true; return true }
    func end() { lock.lock(); pending = false; lock.unlock() }
}

/// A late, missing or duplicated AVFoundation callback must not retain a task.
final class PlaybackCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private var timeout: DispatchWorkItem?
    private func install(_ continuation: CheckedContinuation<Bool, Never>, seconds: Double) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(returning: result); return }
        self.continuation = continuation
        let timeout = DispatchWorkItem { [weak self] in self?.finish(false) }; self.timeout = timeout
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: timeout)
    }
    func finish(_ value: Bool) {
        lock.lock(); guard result == nil else { lock.unlock(); return }
        result = value; let c = continuation; continuation = nil; timeout?.cancel(); timeout = nil; lock.unlock()
        c?.resume(returning: value)
    }
    static func wait(seconds: Double = 5, start: @escaping (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        let gate = PlaybackCallback()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { c in
                gate.install(c, seconds: seconds)
                if !Task.isCancelled { start { gate.finish($0) } } else { gate.finish(false) }
            }
        }, onCancel: { gate.finish(false) })
    }
}

struct PlaybackDriftPolicy {
    private var started: [UUID: Double] = [:]
    private var lastCorrection = -Double.infinity
    mutating func reset() { started.removeAll(); lastCorrection = -Double.infinity }
    mutating func needsCorrection(id: UUID, drift: Double, now: Double) -> Bool {
        guard drift.isFinite, abs(drift) > 0.25 else { started[id] = nil; return false }
        let since = started[id] ?? now; started[id] = since
        guard now - since >= 0.3, now - lastCorrection >= 2 else { return false }
        lastCorrection = now; started[id] = nil; return true
    }
}
enum PlaybackPhase: Equatable { case idle, preparing, paused, seeking, prerolling, playing, waiting, failed }
