import AVFoundation
import Combine
import Core

@MainActor final class Playback: ObservableObject {
    let clock = PlaybackClock()
    var position: Double { get { clock.snapshot.seconds } set { clock.publish(newValue, lesson: lectureID) } }
    @Published private(set) var phase: PlaybackPhase = .idle
    private var driftPolicy = PlaybackDriftPolicy()
    private var waitingStarted: Double?
    @Published private(set) var beforeStart: Set<UUID> = []
    private var followerFailures: [UUID:Int] = [:]
    private var correctionTask: Task<Void, Never>?
    private(set) var correctionCount = 0
    // Injectable AV command completions, also used by failure/timeout regression tests.
    var commandTimeout = 5.0
    var seekCommand: ((AVPlayer, Double, @escaping @Sendable (Bool) -> Void) -> Void)?
    var prerollCommand: ((AVPlayer, Float, @escaping @Sendable (Bool) -> Void) -> Void)?
    let player = AVPlayer()
    let secondaryPlayer = AVPlayer()
    @Published private(set) var displaySizes: [UUID: CGSize] = [:]
    private var sizeObservers: [NSKeyValueObservation] = []
    private var sizeCache: [String: CGSize] = [:]
    // Temporary probes prove that the *current* item has decoded a frame. A view
    // can briefly retain readyForDisplay=true from its previous item.
    private var firstFrameOutputs: [UUID: AVPlayerItemVideoOutput] = [:]
    private var firstFrameItems: [UUID: AVPlayerItem] = [:]
    private var displayedFrames: Set<UUID> = []
    private var frameRecoveries: [UUID: UUID] = [:]
    private var automaticFrameRecoveries: Set<UUID> = []
    var displayGeneration: UUID { generation }
    var canRecoverFirstFrame: Bool { ready && pendingSeek == nil && !synchronizing && correctionTask == nil }
    func matchesDisplayBinding(sourceID: UUID, generation token: UUID, item: AVPlayerItem) -> Bool {
        generation == token && firstFrameItems[sourceID] === item
            && views.first(where: { $0.id == sourceID }).map { player(for: $0).currentItem === item } == true
    }
    func hasCurrentItemFrame(sourceID: UUID, generation token: UUID, item: AVPlayerItem) -> Bool {
        guard matchesDisplayBinding(sourceID: sourceID, generation: token, item: item) else { return false }
        if displayedFrames.contains(sourceID) { return true }
        guard let output = firstFrameOutputs[sourceID], let source = views.first(where: { $0.id == sourceID }) else { return false }
        let time = player(for: source).currentTime()
        return time.seconds.isFinite && output.hasNewPixelBuffer(forItemTime: time)
    }
    func confirmDisplayedFrame(sourceID: UUID, generation token: UUID, item: AVPlayerItem) {
        guard matchesDisplayBinding(sourceID: sourceID, generation: token, item: item), !displayedFrames.contains(sourceID) else { return }
        displayedFrames.insert(sourceID)
        if let output = firstFrameOutputs.removeValue(forKey: sourceID) { item.remove(output) }
        PerformanceTrace.record("video.firstFrameReady", 1)
    }
    /// Recover only the affected video; do not call the public seek path, alter
    /// completion records, or persist a synthetic progress change.
    func recoverFirstFrame(sourceID: UUID, generation token: UUID, item: AVPlayerItem, manual: Bool = false) async -> Bool {
        guard canRecoverFirstFrame, matchesDisplayBinding(sourceID: sourceID, generation: token, item: item),
              let source = views.first(where: { $0.id == sourceID }), eligible(source, at: position), frameRecoveries[sourceID] == nil,
              manual || !automaticFrameRecoveries.contains(sourceID) else { return false }
        if !manual { automaticFrameRecoveries.insert(sourceID) }
        let operation = seekGeneration, recovery = UUID(), p = player(for: source)
        frameRecoveries[sourceID] = recovery
        defer { if frameRecoveries[sourceID] == recovery { frameRecoveries[sourceID] = nil } }
        let canonical = actualPosition.isFinite ? actualPosition : position
        let local = max(0, min(localTime(source, canonical), lengths[sourceID] ?? 0))
        let started = ProcessInfo.processInfo.systemUptime
        PerformanceTrace.record("video.firstFrameRecoveryStarted", 1)
        let success = await seekPlayer(p, to: local)
        guard matchesDisplayBinding(sourceID: sourceID, generation: token, item: item), seekGeneration == operation else { return false }
        // A user pause/seek changes seekGeneration and takes precedence. The
        // current intent, rather than a captured rate, governs resuming audio.
        if intentPlaying && !Task.isCancelled { p.rate = Float(targetSpeed) }
        else { p.pause() }
        PerformanceTrace.record("video.firstFrameRecoverySeconds", ProcessInfo.processInfo.systemUptime - started)
        return success && !Task.isCancelled
    }
    @Published var ready = false; @Published var playing = false;  @Published var duration = 0.0; @Published var error: String?
    @Published private(set) var volume: Double = 1
    @Published private(set) var views: [MediaSource] = []
    @Published private(set) var ended: Set<UUID> = []
    @Published private(set) var missing: Set<UUID> = []
    @Published private(set) var audioID: UUID?
    @Published private(set) var waiting = false
    @Published private(set) var naturallyEnded = false
    var completionChanged:((UUID,Bool)->Void)?
    var shouldContinueOnSwitch:Bool {intentPlaying || naturallyEnded}
    private var naturalEndEligible=false
    private var lastAudibleVolume = 1.0
    private let preferences: UserDefaults
    var lectureID: UUID?; var targetSpeed = 1.0
    var save: ((UUID, Double, Double) -> Void)?
    private var generation = UUID(); private var seekGeneration = UUID(); private var pendingSeek: Double?
    private var loadTask: Task<Void, Never>?; private var loop: Task<Void, Never>?; private var controlTask: Task<Void, Never>?
    private var mediaLeases: [MediaAccessLease] = []; private var lengths: [UUID: Double] = [:]; private var audible: Set<UUID> = []
    private var intentPlaying = false; private var synchronizing = false; private var lastSave = Date.distantPast
    private var lastPersisted:(UUID,Double,Double)?
    private var clockID: UUID?
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        clock.sampled = { [weak self] value in
            guard let self, self.ready, !self.synchronizing, self.pendingSeek == nil, self.views.contains(where:{self.eligible($0,at:self.position)}) else { return }
            self.position = value
        }
        let saved = preferences.object(forKey: "playbackVolume") == nil ? 1 : preferences.double(forKey: "playbackVolume")
        volume = saved.isFinite ? min(1, max(0, saved)) : 1
        let last = preferences.object(forKey: "lastAudibleVolume") == nil ? 1 : preferences.double(forKey: "lastAudibleVolume")
        lastAudibleVolume = last.isFinite ? min(1, max(0.01, last)) : 1
        for p in players { p.automaticallyWaitsToMinimizeStalling = false; p.volume = 0 }
    }
    private var players: [AVPlayer] { [player, secondaryPlayer] }
    func player(for source: MediaSource) -> AVPlayer { views.first?.id == source.id ? player : secondaryPlayer }
    private func localTime(_ source: MediaSource, _ canonical: Double) -> Double { canonical + source.relativeOffset }
    private func eligible(_ source: MediaSource, at time: Double) -> Bool { !missing.contains(source.id) && localTime(source, time) >= 0 && localTime(source, time) < (lengths[source.id] ?? 0) }
    private var clockSource: MediaSource? { views.first { $0.id == clockID } }
    private var actualPosition: Double { guard views.contains(where: { eligible($0, at: position) }), let source = clockSource else { return position }; return player(for: source).currentTime().seconds - source.relativeOffset }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }; volume = min(1, max(0, value)); if volume > 0 { lastAudibleVolume = volume }
        preferences.set(volume, forKey: "playbackVolume"); preferences.set(lastAudibleVolume, forKey: "lastAudibleVolume"); applyAudio()
    }
    func toggleMute() { setVolume(volume > 0 ? 0 : lastAudibleVolume) }
    func selectAudio(_ id: UUID) { guard audible.contains(id) else { return }; audioID = id; applyAudio(); chooseClock(at: position) }
    func hasAudio(_ id: UUID) -> Bool { audible.contains(id) }
    private func applyAudio() { for source in views { player(for: source).volume = source.id == audioID ? Float(volume) : 0 } }
    func load(_ lecture: Lecture,autoplay:Bool=false,restart:Bool=false) {
        close(); let token = UUID(); generation = token; lectureID = lecture.id; position = lecture.state.position; targetSpeed = lecture.state.speed; views = lecture.mediaSources; error = nil
        intentPlaying=autoplay; phase = .preparing
        loadTask = Task { [weak self] in
            guard let self else { return }
            for source in self.views {
                do {
                    let prepared = try await MediaPreparation.load(source, timeout: self.commandTimeout)
                    guard self.generation == token, !Task.isCancelled else { prepared.lease.release(); return }
                    self.mediaLeases.append(prepared.lease)
                    let asset=prepared.asset, seconds=prepared.duration
                    let hasAudio=prepared.hasAudio
                    guard seconds.isFinite && seconds > 0 else { throw Failure("媒体时长无效") }
                    self.lengths[source.id] = seconds
                    if hasAudio { self.audible.insert(source.id) }
                    let item = AVPlayerItem(asset: asset); item.audioTimePitchAlgorithm = .timeDomain
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                    output.suppressesPlayerRendering = false
                    item.add(output)
                    self.firstFrameOutputs[source.id] = output; self.firstFrameItems[source.id] = item
                    self.player(for: source).replaceCurrentItem(with: item)
                    for _ in 0..<250 {
                        if item.status != .unknown { break }; try await Task.sleep(for: .milliseconds(20))
                    }
                    guard item.status == .readyToPlay else { throw Failure(item.error?.localizedDescription ?? "媒体准备超时") }
                    guard self.generation == token, !Task.isCancelled else { return }
                    // AVPlayerItem presentationSize is the displayed size, including rotation
                    // and pixel aspect ratio; do not guess from the encoded track dimensions.
                    let cacheKey = source.identity + ":" + (source.contentHash ?? "")
                    if !source.identity.isEmpty, source.contentHash != nil, let size = self.sizeCache[cacheKey] { self.displaySizes[source.id] = size }
                    self.acceptDisplaySize(item.presentationSize, source: source, token: token)
                    self.sizeObservers.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
                        let size = item.presentationSize
                        Task { @MainActor [weak self] in self?.acceptDisplaySize(size, source: source, token: token) }
                    })
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.missing.insert(source.id); self.error = "\(source.role.rawValue)：\(error.localizedDescription)。资料已保留，可重新定位。"
                }
            }
            guard self.generation == token, !Task.isCancelled else { return }
            let available = self.views.filter { !self.missing.contains($0.id) }
            guard !available.isEmpty else {self.intentPlaying=false;self.phase = .failed;return}
            self.clockID = available.max { (self.lengths[$0.id] ?? 0) - $0.relativeOffset < (self.lengths[$1.id] ?? 0) - $1.relativeOffset }?.id
            let mediaDuration=available.map { (self.lengths[$0.id] ?? 0) - $0.relativeOffset }.max() ?? 0
            self.duration = self.missing.isEmpty ? mediaDuration:max(lecture.duration,mediaDuration)
            self.audioID = available.first { $0.id == lecture.audioSourceID && self.audible.contains($0.id) }?.id ?? available.first { $0.role == .screen && self.audible.contains($0.id) }?.id ?? available.first { self.audible.contains($0.id) }?.id
            self.clock.observe(available.map{($0.id,self.player(for:$0),$0.relativeOffset)})
            self.applyAudio(); self.chooseClock(at: self.position)
            let target = restart ? 0:max(0,min(lecture.state.position,max(0,self.duration-0.01)))
            let complete = await self.seekPlayers(target)
            guard self.generation == token, !Task.isCancelled else { return }
            self.position = complete ? target : max(0, self.actualPosition); self.ready = true; self.phase = .paused; self.refreshEnded()
            if !complete { self.recoverOperation("媒体定位未完成，已暂停。可点击播放恢复或重新跳转。") }
            self.naturalEndEligible=target<self.duration-0.025
            if restart {self.completionChanged?(lecture.id,false)}
            self.startLoop(token)
            if complete && self.intentPlaying && self.missing.isEmpty {self.scheduleStart()}else{self.intentPlaying=false}
        }
    }
    private func acceptDisplaySize(_ size: CGSize, source: MediaSource, token: UUID) {
        guard generation == token, views.contains(where: { $0.id == source.id }), PictureInPictureGeometry.aspect(size) != nil else { return }
        if displaySizes[source.id] != size { displaySizes[source.id] = size }
        if !source.identity.isEmpty, source.contentHash != nil {
            if sizeCache.count >= 64 { sizeCache.removeAll() }
            sizeCache[source.identity + ":" + (source.contentHash ?? "")] = size
        }
    }
    private func chooseClock(at time: Double) {
        let available = views.filter { eligible($0, at: time) }
        let preferred = available.first { $0.id == audioID } ?? available.first
        guard let source = preferred, source.id != clockID || !ready else { return }
        clockID = source.id
        clock.select(source.id)
    }
    private func seekPlayer(_ p: AVPlayer, to time: Double) async -> Bool {
        let command = seekCommand
        return await PlaybackCallback.wait(seconds: commandTimeout) { done in
            if let command { command(p, time, done) }
            else { p.seek(to: CMTime(seconds: time, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: done) }
        }
    }
    private func seekPlayers(_ value: Double) async -> Bool {
        let targets = views.filter { !missing.contains($0.id) }.map { source in (player(for: source), max(0, min(localTime(source, value), lengths[source.id] ?? 0))) }
        return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for (p, time) in targets { group.addTask { await self.seekPlayer(p, to: time) } }
            var ok = true; for await result in group { ok = ok && result }; return ok
        }
    }
    private func recoverOperation(_ message: String) {
        waitingStarted=nil;pendingSeek = nil; synchronizing = false; intentPlaying = false
        for p in players { p.cancelPendingPrerolls(); p.currentItem?.cancelPendingSeeks(); p.pause() }
        let actual = actualPosition; if actual.isFinite { position = max(0, actual) }
        playing = false; waiting = false; phase = .failed; error = message; persist()
        PerformanceTrace.record("playback.recovery", 1)
    }
    private func correctFollower(_ source: MediaSource) {
        guard correctionTask == nil, frameRecoveries[source.id] == nil else { return }
        if followerFailures[source.id,default:0] >= 3 { recoverOperation("次要画面持续不同步，已暂停。请检查媒体文件后重新播放。"); return }
        followerFailures[source.id,default:0] += 1
        let token = generation, operation = seekGeneration
        let p = player(for: source)
        correctionCount += 1; PerformanceTrace.record("playback.followerCorrection", 1)
        correctionTask = Task { [weak self] in
            guard let self else { return }
            let complete = await self.seekPlayer(p, to: self.localTime(source, self.clock.latest(self.clockID) ?? self.position))
            guard self.generation == token, self.seekGeneration == operation, !Task.isCancelled else { return }
            self.correctionTask = nil
            if complete && self.intentPlaying { p.rate = Float(self.targetSpeed) }
            else if !complete { self.recoverOperation("次要画面同步未完成，已暂停。可点击播放恢复。") }
        }
    }
    private func startLoop(_ token: UUID) {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100)); guard let self, self.generation == token else { return }
                guard self.ready, !self.synchronizing, self.pendingSeek == nil else { continue }
                self.chooseClock(at: self.position)
                let actual = self.views.contains(where:{self.eligible($0,at:self.position)}) ? (self.clock.latest(self.clockID) ?? self.position) : self.position
                if actual.isFinite, abs(self.position-max(0,actual))>0.001 { self.position = max(0, actual) }; self.refreshEnded()
                if self.intentPlaying {
                    if self.position >= self.duration - 0.025 {
                        let natural=self.naturalEndEligible && self.missing.isEmpty && self.clockID.map{self.ended.contains($0)} == true
                        self.pause()
                        if natural,let id=self.lectureID {self.naturallyEnded=true;self.completionChanged?(id,true)}
                    }
                    else {
                        let active = self.views.filter { self.eligible($0, at: self.position) }
                        if active.isEmpty { self.pause(); continue }
                        let stalled = self.clockSource.map { self.player(for: $0).currentItem?.isPlaybackBufferEmpty == true } ?? false
                        if stalled {
                            let now=ProcessInfo.processInfo.systemUptime
                            if self.waitingStarted == nil {self.waitingStarted=now}
                            if now-(self.waitingStarted ?? now)>=5 {self.recoverOperation("媒体等待超时，已暂停。请检查文件后恢复播放。");continue}
                            if !self.waiting {for p in self.players {p.pause()};self.waiting=true;self.playing=false;self.phase = .waiting}
                        }
                        else if self.waiting || self.clockSource.map({self.player(for:$0).rate == 0}) == true { self.scheduleStart() }
                        else {
                            for source in active where source.id != self.clockID {
                                let drift = (self.clock.latest(source.id) ?? self.position) - self.position
                                if abs(drift)<=0.25 { self.followerFailures[source.id]=nil }
                                if self.driftPolicy.needsCorrection(id: source.id, drift: drift, now: ProcessInfo.processInfo.systemUptime) { self.correctFollower(source) }
                            }
                        }
                    }
                }
                if Date().timeIntervalSince(self.lastSave) >= 5 { self.persist() }
            }
        }
    }
    private func refreshEnded() { let upcoming=Set(views.filter {localTime($0,position)<0}.map(\.id));if upcoming != beforeStart {beforeStart=upcoming};let next = Set(views.filter { !missing.contains($0.id) && localTime($0, position) >= (lengths[$0.id] ?? 0) - 0.025 }.map(\.id)); if ended != next { ended = next } }
    func isBeforeStart(_ source: MediaSource) -> Bool { localTime(source, position) < 0 }
    func pause() { waitingStarted=nil;seekGeneration = UUID(); pendingSeek = nil; synchronizing = false; correctionTask?.cancel(); correctionTask = nil; phase = .paused; intentPlaying = false; controlTask?.cancel(); for p in players { p.cancelPendingPrerolls(); p.currentItem?.cancelPendingSeeks(); p.pause() }; position = actualPosition; playing = false; waiting = false; persist() }
    func toggle() { guard ready else { return }; if naturallyEnded {intentPlaying=true;seek(0);return}; if !intentPlaying && !views.contains(where: { eligible($0, at: position) }) { error = "当前位置没有可播放的视角。请重新定位缺失文件，或跳到已有视角的时间范围。"; return }; if intentPlaying { pause() } else { intentPlaying = true; scheduleStart() } }
    private func scheduleStart() {
        guard intentPlaying, !synchronizing, frameRecoveries.isEmpty else { return }
        synchronizing = true; phase = .prerolling; error = nil; let token = generation; let seekToken = seekGeneration
        controlTask = Task { [weak self] in
            guard let self else { return }
            let time = self.position
            let active = self.views.filter { self.eligible($0, at: time) }
            let command = self.prerollCommand, rate = Float(self.targetSpeed), timeout = self.commandTimeout
            let targets=active.map { self.player(for:$0) }
            let success=await withTaskGroup(of:Bool.self, returning:Bool.self) { group in
                for p in targets { group.addTask {
                    await PlaybackCallback.wait(seconds:timeout) { done in
                        if let command {command(p,rate,done)} else {p.preroll(atRate:rate,completionHandler:done)}
                    }
                } }
                var ok=true;for await result in group {ok = ok && result};return ok
            }
            guard self.generation == token, self.seekGeneration == seekToken else { return }
            self.synchronizing = false
            guard !Task.isCancelled, self.intentPlaying else { return }
            guard success else { self.recoverOperation("播放准备未完成，已暂停。可点击播放重新准备。"); return }
            let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.08, preferredTimescale: 1_000_000_000))
            for source in active { self.player(for: source).setRate(Float(self.targetSpeed), time: CMTime(seconds: self.localTime(source, time), preferredTimescale: 1000), atHostTime: host) }
            self.waitingStarted=nil; self.waiting = false; self.playing = true; self.phase = .playing
        }
    }
    func retryLoad(_ lecture: Lecture) { load(lecture) }
    func speed(_ value: Double) { targetSpeed = value; if intentPlaying { seek(position) } }
    func seek(_ value: Double) {
        guard ready, value.isFinite else { return }
        let target = max(0, min(value, duration)); let token = generation; let seekToken = UUID()
        naturallyEnded=false;naturalEndEligible=target<duration-0.025
        if let id=lectureID {completionChanged?(id,false)}
        correctionTask?.cancel(); correctionTask = nil; followerFailures.removeAll(); driftPolicy.reset(); phase = .seeking
        seekGeneration = seekToken; pendingSeek = target; position = target; synchronizing = true; playing = false; waiting = intentPlaying
        controlTask?.cancel(); for p in players { p.cancelPendingPrerolls(); p.pause() }
        controlTask = Task { [weak self] in
            guard let self else { return }; let complete = await self.seekPlayers(target)
            guard self.generation == token, self.seekGeneration == seekToken else { return }
            self.synchronizing = false; self.pendingSeek = nil
            if complete { self.phase = .paused; self.chooseClock(at: target); self.position = target; self.refreshEnded(); self.persist(); if self.intentPlaying { self.scheduleStart() } }
            else { self.recoverOperation("跳转未完成，已恢复实际播放位置。可重新播放或跳转。") }
        }
    }
    func persist() { guard ready, let id = lectureID else { return }; let seconds = pendingSeek ?? (playing ? (clock.latest(clockID) ?? position) : actualPosition); guard seconds.isFinite else { return }; lastSave=Date();if let old=lastPersisted,old.0==id,abs(old.1-seconds)<0.001,old.2==duration{return};save?(id,max(0,seconds),duration);lastPersisted=(id,seconds,duration) }
    func close() {
        waitingStarted=nil;beforeStart=[];error=nil;clock.detach(); correctionTask?.cancel(); correctionTask = nil; followerFailures.removeAll(); driftPolicy.reset(); phase = .idle
        sizeObservers.removeAll(); displaySizes.removeAll()
        for (id, output) in firstFrameOutputs { firstFrameItems[id]?.remove(output) }
        firstFrameOutputs.removeAll(); firstFrameItems.removeAll(); displayedFrames.removeAll(); frameRecoveries.removeAll(); automaticFrameRecoveries.removeAll()
        persist(); ready = false;naturallyEnded=false;naturalEndEligible=false; generation = UUID(); seekGeneration = UUID(); pendingSeek = nil; intentPlaying = false; synchronizing = false
        loadTask?.cancel(); loop?.cancel(); controlTask?.cancel(); loadTask = nil; loop = nil; controlTask = nil
        for p in players { p.cancelPendingPrerolls(); p.pause(); p.replaceCurrentItem(with: nil) }
        for lease in mediaLeases { lease.release() }; mediaLeases = []; lengths = [:]; audible = []; missing = []; ended = []; views = []; lectureID = nil; playing = false; waiting = false; clockID = nil
    }
}
