import AVFoundation
import Combine
import Core

@MainActor final class Playback: ObservableObject {
    let player = AVPlayer()
    let secondaryPlayer = AVPlayer()
    @Published var ready = false; @Published var playing = false; @Published var position = 0.0; @Published var duration = 0.0; @Published var error: String?
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
    private var access: [URL] = []; private var lengths: [UUID: Double] = [:]; private var audible: Set<UUID> = []
    private var intentPlaying = false; private var synchronizing = false; private var lastSave = Date.distantPast
    private var lastPersisted:(UUID,Double,Double)?
    private var clockID: UUID?
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
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
    func selectAudio(_ id: UUID) { guard audible.contains(id) else { return }; audioID = id; applyAudio() }
    func hasAudio(_ id: UUID) -> Bool { audible.contains(id) }
    private func applyAudio() { for source in views { player(for: source).volume = source.id == audioID ? Float(volume) : 0 } }
    func load(_ lecture: Lecture,autoplay:Bool=false,restart:Bool=false) {
        close(); let token = UUID(); generation = token; lectureID = lecture.id; position = lecture.state.position; targetSpeed = lecture.state.speed; views = lecture.mediaSources; error = nil
        intentPlaying=autoplay
        loadTask = Task { [weak self] in
            guard let self else { return }
            for source in self.views {
                do {
                    var stale = false
                    let url = try source.bookmark.map { try URL(resolvingBookmarkData: $0, options: [.withSecurityScope,.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) } ?? URL(fileURLWithPath: source.path)
                    if url.startAccessingSecurityScopedResource() { self.access.append(url) }
                    try ImportPlanner.requireLocal(url)
                    let asset = AVURLAsset(url: url)
                    guard try await asset.load(.isPlayable) else { throw Failure("无法播放此媒体编码") }
                    let seconds = try await asset.load(.duration).seconds
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    guard self.generation == token, !Task.isCancelled else { return }
                    guard seconds.isFinite && seconds > 0 else { throw Failure("媒体时长无效") }
                    self.lengths[source.id] = seconds
                    if !tracks.isEmpty { self.audible.insert(source.id) }
                    let item = AVPlayerItem(asset: asset); item.audioTimePitchAlgorithm = .timeDomain
                    self.player(for: source).replaceCurrentItem(with: item)
                    for _ in 0..<500 {
                        if item.status != .unknown { break }; try await Task.sleep(for: .milliseconds(20))
                    }
                    guard item.status == .readyToPlay else { throw Failure(item.error?.localizedDescription ?? "媒体准备超时") }
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.missing.insert(source.id); self.error = "\(source.role.rawValue)：\(error.localizedDescription)。资料已保留，可重新定位。"
                }
            }
            guard self.generation == token, !Task.isCancelled else { return }
            let available = self.views.filter { !self.missing.contains($0.id) }
            guard !available.isEmpty else {self.intentPlaying=false;return}
            self.clockID = available.max { (self.lengths[$0.id] ?? 0) - $0.relativeOffset < (self.lengths[$1.id] ?? 0) - $1.relativeOffset }?.id
            let mediaDuration=available.map { (self.lengths[$0.id] ?? 0) - $0.relativeOffset }.max() ?? 0
            self.duration = self.missing.isEmpty ? mediaDuration:max(lecture.duration,mediaDuration)
            self.audioID = available.first { $0.id == lecture.audioSourceID && self.audible.contains($0.id) }?.id ?? available.first { $0.role == .screen && self.audible.contains($0.id) }?.id ?? available.first { self.audible.contains($0.id) }?.id
            self.applyAudio()
            let target = restart ? 0:max(0,min(lecture.state.position,max(0,self.duration-0.01)))
            guard await self.seekPlayers(target), self.generation == token else { return }
            self.position = target; self.ready = true; self.refreshEnded()
            self.naturalEndEligible=target<self.duration-0.025
            if restart {self.completionChanged?(lecture.id,false)}
            self.startLoop(token)
            if self.intentPlaying && self.missing.isEmpty {self.scheduleStart()}else{self.intentPlaying=false}
        }
    }
    private func seekPlayers(_ value: Double) async -> Bool {
        // Issue both seeks before awaiting completions; each completion is generation-checked by caller.
        let targets = views.filter { !missing.contains($0.id) }.map { source in (player(for: source), max(0, min(localTime(source, value), lengths[source.id] ?? 0))) }
        return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for (p, time) in targets { group.addTask { await withCheckedContinuation { continuation in p.seek(to: CMTime(seconds: time, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) } } } }
            var ok = true; for await result in group { ok = ok && result }; return ok
        }
    }
    private func startLoop(_ token: UUID) {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100)); guard let self, self.generation == token else { return }
                guard self.ready, !self.synchronizing, self.pendingSeek == nil else { continue }
                let actual = self.actualPosition
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
                        let stalled = active.contains { self.player(for: $0).currentItem?.isPlaybackBufferEmpty == true }
                        if stalled { for p in self.players { p.pause() }; self.waiting = true; self.playing = false }
                        else if self.waiting || active.contains(where: { self.player(for: $0).rate == 0 }) { self.scheduleStart() }
                        else if active.contains(where: { abs(self.player(for: $0).currentTime().seconds - self.localTime($0, self.position)) > 0.05 }) { self.seek(self.position) }
                    }
                }
                if Date().timeIntervalSince(self.lastSave) >= 5 { self.persist() }
            }
        }
    }
    private func refreshEnded() { let next = Set(views.filter { !missing.contains($0.id) && localTime($0, position) >= (lengths[$0.id] ?? 0) - 0.025 }.map(\.id)); if ended != next { ended = next } }
    func isBeforeStart(_ source: MediaSource) -> Bool { localTime(source, position) < 0 }
    func pause() { intentPlaying = false; controlTask?.cancel(); for p in players { p.cancelPendingPrerolls(); p.pause() }; playing = false; waiting = false; persist() }
    func toggle() { guard ready else { return }; if naturallyEnded {intentPlaying=true;seek(0);return}; if !intentPlaying && !views.contains(where: { eligible($0, at: position) }) { error = "当前位置没有可播放的视角。请重新定位缺失文件，或跳到已有视角的时间范围。"; return }; if intentPlaying { pause() } else { intentPlaying = true; scheduleStart() } }
    private func scheduleStart() {
        guard intentPlaying, !synchronizing else { return }
        synchronizing = true; let token = generation; let seekToken = seekGeneration
        controlTask = Task { [weak self] in
            guard let self else { return }
            let time = self.position
            let active = self.views.filter { self.eligible($0, at: time) }
            var success = true
            for source in active {
                let p = self.player(for: source)
                let ok = await withCheckedContinuation { continuation in p.preroll(atRate: Float(self.targetSpeed)) { continuation.resume(returning: $0) } }
                success = success && ok
            }
            guard self.generation == token, self.seekGeneration == seekToken else { return }
            self.synchronizing = false
            guard !Task.isCancelled, self.intentPlaying, success else { return }
            let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.08, preferredTimescale: 1_000_000_000))
            for source in active { self.player(for: source).setRate(Float(self.targetSpeed), time: CMTime(seconds: self.localTime(source, time), preferredTimescale: 1000), atHostTime: host) }
            self.waiting = false; self.playing = true
        }
    }
    func speed(_ value: Double) { targetSpeed = value; if intentPlaying { seek(position) } }
    func seek(_ value: Double) {
        guard ready, value.isFinite else { return }
        let target = max(0, min(value, duration)); let token = generation; let seekToken = UUID()
        naturallyEnded=false;naturalEndEligible=target<duration-0.025
        if let id=lectureID {completionChanged?(id,false)}
        seekGeneration = seekToken; pendingSeek = target; position = target; synchronizing = true; playing = false; waiting = intentPlaying
        controlTask?.cancel(); for p in players { p.cancelPendingPrerolls(); p.pause() }
        controlTask = Task { [weak self] in
            guard let self else { return }; let complete = await self.seekPlayers(target)
            guard self.generation == token, self.seekGeneration == seekToken else { return }
            self.synchronizing = false
            if complete { self.pendingSeek = nil; self.position = target; self.refreshEnded(); self.persist(); if self.intentPlaying { self.scheduleStart() } }
        }
    }
    func persist() { guard ready, let id = lectureID else { return }; let seconds = pendingSeek ?? actualPosition; guard seconds.isFinite else { return }; lastSave=Date();if let old=lastPersisted,old.0==id,abs(old.1-seconds)<0.001,old.2==duration{return};save?(id,max(0,seconds),duration);lastPersisted=(id,seconds,duration) }
    func close() {
        persist(); ready = false;naturallyEnded=false;naturalEndEligible=false; generation = UUID(); seekGeneration = UUID(); pendingSeek = nil; intentPlaying = false; synchronizing = false
        loadTask?.cancel(); loop?.cancel(); controlTask?.cancel(); loadTask = nil; loop = nil; controlTask = nil
        for p in players { p.cancelPendingPrerolls(); p.pause(); p.replaceCurrentItem(with: nil) }
        for url in access { url.stopAccessingSecurityScopedResource() }; access = []; lengths = [:]; audible = []; missing = []; ended = []; views = []; lectureID = nil; playing = false; waiting = false; clockID = nil
    }
}
