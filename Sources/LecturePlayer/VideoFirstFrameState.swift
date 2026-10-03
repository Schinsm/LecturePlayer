import Foundation

/// A first-frame watchdog, independent of media readiness and the playback clock.
/// Each instance belongs to one load generation and one AVPlayerItem binding.
struct VideoFirstFrameState {
    enum Status: Equatable { case idle, waiting, loading, recovering, ready, failed }
    let generation: UUID
    let binding: UUID
    var revealDelay = 0.4
    var timeout = 5.0
    private(set) var status: Status = .idle
    private(set) var automaticRecoveryAttempted = false
    private var started: Double?
    private var recoveryStarted: Double?
    private var failed = false
    private var presented = false

    init(generation: UUID, binding: UUID) { self.generation = generation; self.binding = binding }

    /// Returns true once when an automatic recovery should be requested.
    mutating func observe(generation: UUID, binding: UUID, eligible: Bool, hasFrame: Bool, now: Double) -> Bool {
        guard self.generation == generation, self.binding == binding else { return false }
        if hasFrame && eligible {
            presented = true; status = .ready; started = nil; recoveryStarted = nil
            return false
        }
        guard eligible else { started = nil; status = .idle; return false }
        // Ready is current presentation state, not a permanent latch. A layer
        // can lose readiness after remounting even while audio keeps advancing.
        presented = false
        if failed { status = .failed; return false }
        if let recoveryStarted {
            if now - recoveryStarted >= timeout { failed = true; status = .failed }
            else { status = .recovering }
            return false
        }
        if started == nil { started = now }
        let elapsed = now - (started ?? now)
        status = elapsed >= revealDelay ? .loading : .waiting
        if elapsed >= timeout && automaticRecoveryAttempted { failed = true; status = .failed; return false }
        if elapsed >= timeout && !automaticRecoveryAttempted {
            automaticRecoveryAttempted = true; recoveryStarted = now; status = .recovering
            return true
        }
        return false
    }
    mutating func recoveryFinished(success: Bool) {
        guard !presented else { return }
        if !success { failed = true; status = .failed }
    }
    mutating func retry(now: Double) -> Bool {
        guard status == .failed else { return false }
        failed = false; automaticRecoveryAttempted = true; recoveryStarted = now; status = .recovering
        return true
    }
}
