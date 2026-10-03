import SwiftUI
import AVKit
import Core
import Combine

struct DualVideoView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var playback: Playback
    var body: some View {
        VideoCanvas(playback: playback, layout: store.lecture?.layout ?? .inset,
                    swapped: store.lecture?.swapped ?? false, preferences: store.pipPreferences)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
    }
}

/// Keep transport instances stable; each mounted surface owns its rendering layer.
struct VideoCanvas: NSViewRepresentable {
    let playback: Playback; let layout: VideoLayout; let swapped: Bool
    let preferences: PictureInPicturePreferences
    func makeNSView(context: Context) -> Canvas { Canvas() }
    func updateNSView(_ view: Canvas, context: Context) {
        view.configure(playback, layout: layout, swapped: swapped, preferences: preferences)
    }
    static func dismantleNSView(_ view: Canvas, coordinator: ()) { view.tearDown() }
    final class Canvas: NSView {
        let videos = [VideoSurface(), VideoSurface()]
        let handle = PictureInPictureHandle()
        let messages = [NSTextField(wrappingLabelWithString: ""), NSTextField(wrappingLabelWithString: "")]
        let recoveryButtons = [NSButton(title: "恢复画面", target: nil, action: nil), NSButton(title: "恢复画面", target: nil, action: nil)]
        private weak var playback: Playback?
        private var baseMessages = ["", ""]
        private var frameBindings: [Int: FrameBinding] = [:]
        private var frameTimer: Timer?
        private var windowObservers: [NSObjectProtocol] = []
        private var sampleScheduled = false
        private final class FrameBinding {
            let sourceID: UUID, generation: UUID, identity = UUID()
            let createdAt = ProcessInfo.processInfo.systemUptime
            let item: AVPlayerItem
            var state: VideoFirstFrameState
            var observation: NSKeyValueObservation?
            var recovery: Task<Void, Never>?
            init(sourceID: UUID, generation: UUID, item: AVPlayerItem) {
                self.sourceID = sourceID; self.generation = generation; self.item = item
                state = VideoFirstFrameState(generation: generation, binding: identity)
            }
            deinit { recovery?.cancel() }
        }
        var sizes: [UUID: CGSize] = [:]
        var preferences: PictureInPicturePreferences?
        private var subscription: AnyCancellable?
        var sources: [MediaSource] = []; var mode: VideoLayout = .inset; var swapped = false
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
            for i in videos.indices {
                let v = videos[i]
                addSubview(v)
                let message = messages[i]
                message.alignment = .center; message.textColor = .white; message.backgroundColor = .black
                message.drawsBackground = true; message.font = .systemFont(ofSize: 12)
                message.isSelectable = false; message.isHidden = true; message.wantsLayer = true
                addSubview(message)
                let button = recoveryButtons[i]; button.bezelStyle = .rounded
                button.target = self; button.action = #selector(retryFirstFrame(_:)); button.tag = i
                button.isHidden = true; button.wantsLayer = true
                button.setAccessibilityLabel(sourceLabel(i) + "恢复画面")
                addSubview(button)
            }
            addSubview(handle); handle.isHidden = true
            handle.move = { [weak self] dx, dy, keyboard in self?.moveInset(dx: dx, dy: dy, keyboard: keyboard) }
            handle.resize = { [weak self] dx, dy, keyboard in self?.resizeInset(dx: dx, dy: dy, keyboard: keyboard) }
            handle.commit = { [weak self] in self?.preferences?.flush() }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
        func configure(_ playback: Playback, layout: VideoLayout, swapped: Bool, preferences: PictureInPicturePreferences) {
            self.playback = playback
            if self.preferences !== preferences {
                self.preferences?.flush(); self.preferences = preferences
                subscription = preferences.$value.sink { [weak self] _ in
                    // @Published sends before the value is assigned. Relayout next turn.
                    DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
                }
            }
            sizes = playback.displaySizes
            sources = playback.views; mode = layout; self.swapped = swapped
            for i in videos.indices {
                guard i < sources.count else { videos[i].isHidden = true; videos[i].detach(); frameBindings[i] = nil; baseMessages[i] = ""; continue }
                let source = sources[i], player = playback.player(for: source)
                videos[i].player = player
                videos[i].setAccessibilityLabel(source.role.rawValue + "视频")
                bindFirstFrame(index: i, source: source, playback: playback)
                baseMessages[i] = playback.missing.contains(source.id) ? source.role.rawValue + "文件缺失 · 在本课文件中重新选择" :
                    playback.ended.contains(source.id) ? "该视角已结束" : playback.isBeforeStart(source) ? "该视角尚未开始" : ""
            }
            needsLayout = true; scheduleFrameSample()
        }
        private func sourceLabel(_ index: Int) -> String { index < sources.count ? sources[index].role.rawValue : "视频" }
        private func bindFirstFrame(index: Int, source: MediaSource, playback: Playback) {
            guard let item = videos[index].player?.currentItem else { frameBindings[index] = nil; return }
            if let old = frameBindings[index], old.generation == playback.displayGeneration, old.sourceID == source.id, old.item === item { return }
            let binding = FrameBinding(sourceID: source.id, generation: playback.displayGeneration, item: item)
            frameBindings[index] = binding
            let identity = binding.identity
            binding.observation = videos[index].observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.frameBindings[index]?.identity == identity else { return }
                    self.scheduleFrameSample()
                }
            }
        }
        private func scheduleFrameSample() {
            guard !sampleScheduled else { return }; sampleScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.sampleScheduled = false; self.sampleFirstFrames()
            }
        }
        private func sampleFirstFrames() {
            guard let playback else { stopFrameTimer(); return }
            let now = ProcessInfo.processInfo.systemUptime
            var watch = false
            for i in videos.indices {
                guard let binding = frameBindings[i], i < sources.count,
                      playback.matchesDisplayBinding(sourceID: binding.sourceID, generation: binding.generation, item: binding.item) else {
                    messages[i].stringValue = i < sources.count ? baseMessages[i] : ""
                    recoveryButtons[i].isHidden = true; continue
                }
                let view = videos[i]
                let mounted = window?.isVisible == true && window?.isMiniaturized == false
                    && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !view.isHidden
                    && view.bounds.width > 1 && view.bounds.height > 1 && !visibleRect.isEmpty
                let usable = mounted && baseMessages[i].isEmpty
                let eligible = usable && playback.canRecoverFirstFrame
                let decoded = eligible && playback.hasCurrentItemFrame(sourceID: binding.sourceID, generation: binding.generation, item: binding.item)
                let ready = view.isReadyForDisplay && decoded
                let old = binding.state.status
                let recover = binding.state.observe(generation: binding.generation, binding: binding.identity, eligible: eligible, hasFrame: ready, now: now)
                if ready {
                    playback.confirmDisplayedFrame(sourceID: binding.sourceID, generation: binding.generation, item: binding.item)
                }
                if old != binding.state.status {
                    PerformanceTrace.record("video.presentationState", Double(stateNumber(binding.state.status)))
                    if binding.state.status == .ready { PerformanceTrace.record("video.firstFrameSeconds", now - binding.createdAt) }
                }
                if recover { recoverFrame(index: i, binding: binding) }
                let text: String
                switch binding.state.status {
                case .loading: text = "正在加载画面…"
                case .recovering: text = "正在恢复画面…"
                default: text = ""
                }
                messages[i].stringValue = baseMessages[i].isEmpty ? text : baseMessages[i]
                recoveryButtons[i].isHidden = !usable || binding.state.status != .failed
                recoveryButtons[i].isEnabled = binding.recovery == nil
                recoveryButtons[i].setAccessibilityLabel(sourceLabel(i) + "恢复画面")
                watch = watch || (usable && binding.state.status != .ready && binding.state.status != .failed)
            }
            positionFrameMessages()
            if watch && frameTimer == nil {
                let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.sampleFirstFrames() }
                RunLoop.main.add(timer, forMode: .common); frameTimer = timer
            } else if !watch { stopFrameTimer() }
        }
        private func stateNumber(_ state: VideoFirstFrameState.Status) -> Int {
            switch state { case .idle: return 0; case .waiting: return 1; case .loading: return 2; case .recovering: return 3; case .ready: return 4; case .failed: return 5 }
        }
        private func recoverFrame(index: Int, binding: FrameBinding, manual: Bool = false) {
            guard let playback, binding.recovery == nil else { return }
            binding.recovery = Task { [weak self, weak binding, weak playback] in
                guard let binding, let playback else { return }
                // Repair presentation first. Seeking alone cannot fix a detached layer.
                guard let self, self.frameBindings[index]?.identity == binding.identity else { return }
                self.videos[index].rebuildPresentation()
                PerformanceTrace.record("video.surfaceRebuild", 1)
                for _ in 0..<10 {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard self.frameBindings[index]?.identity == binding.identity else { return }
                    if self.videos[index].isReadyForDisplay { break }
                }
                let decoded = playback.hasCurrentItemFrame(sourceID: binding.sourceID, generation: binding.generation, item: binding.item)
                let result: Bool
                if decoded {
                    result = self.videos[index].isReadyForDisplay
                } else {
                    result = await playback.recoverFirstFrame(sourceID: binding.sourceID, generation: binding.generation, item: binding.item, manual: manual)
                }
                guard self.frameBindings[index]?.identity == binding.identity, !Task.isCancelled else { return }
                binding.recovery = nil; binding.state.recoveryFinished(success: result)
                self.sampleFirstFrames()
            }
        }
        @objc private func retryFirstFrame(_ sender: NSButton) {
            guard let binding = frameBindings[sender.tag], playback?.canRecoverFirstFrame == true,
                  binding.state.retry(now: ProcessInfo.processInfo.systemUptime) else { return }
            recoverFrame(index: sender.tag, binding: binding, manual: true); sampleFirstFrames()
        }
        private func stopFrameTimer() { frameTimer?.invalidate(); frameTimer = nil }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            // The PiP drag surface covers the inset. Its recovery action must
            // remain clickable without turning a recovery click into a drag.
            for button in recoveryButtons where !button.isHidden && button.frame.contains(local) {
                return button.hitTest(local)
            }
            return super.hitTest(point)
        }
        private func positionFrameMessages() {
            for i in videos.indices {
                let view = videos[i], message = messages[i], button = recoveryButtons[i]
                message.isHidden = view.isHidden || message.stringValue.isEmpty
                if !view.isHidden {
                    let frame = view.frame, width = max(0, frame.width - 16)
                    let height = message.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 100)).height ?? 40
                    message.frame = CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
                    button.frame = CGRect(x: frame.midX - 48, y: frame.midY - 15, width: 96, height: 30)
                } else { button.isHidden = true }
                message.layer?.zPosition = 2; button.layer?.zPosition = 4
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowObservers.forEach { NotificationCenter.default.removeObserver($0) }; windowObservers.removeAll()
            if let window {
                for event in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
                    windowObservers.append(NotificationCenter.default.addObserver(forName: event, object: window, queue: .main) { [weak self] _ in self?.scheduleFrameSample() })
                }
                scheduleFrameSample()
            } else { stopFrameTimer() }
        }
        override func layout() {
            super.layout(); guard !sources.isEmpty else { videos.forEach { $0.isHidden = true }; messages.forEach { $0.isHidden = true }; recoveryButtons.forEach { $0.isHidden = true }; handle.isHidden = true; stopFrameTimer(); return }
            let screen = sources.firstIndex { $0.role == .screen } ?? 0
            let camera = sources.firstIndex { $0.role == .camera } ?? 0
            let secondary = swapped ? screen : camera
            let frames = videoFrames(sources, mode: mode, swapped: swapped, bounds: bounds,
                                     sizes: sizes, placement: preferences?.value ?? .init())
            for i in videos.indices {
                videos[i].isHidden = frames[i] == nil
                messages[i].isHidden = frames[i] == nil || messages[i].stringValue.isEmpty
                if let frame = frames[i] {
                    videos[i].frame = frame
                    let width = max(0, frame.width - 16)
                    let height = messages[i].cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 100)).height ?? 40
                    messages[i].frame = CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
                }
                videos[i].setPresentationEnabled(frames[i] != nil)
                messages[i].layer?.zPosition = 2
                videos[i].layer?.borderWidth = mode == .inset && sources.count == 2 && i == secondary ? 1 : 0
                videos[i].layer?.borderColor = NSColor.gray.cgColor
            }
            for i in videos.indices { videos[i].layer?.zPosition = mode == .inset && sources.count == 2 && i == secondary ? 1 : 0 }
            handle.wantsLayer = true; handle.layer?.zPosition = 3
            handle.isHidden = mode != .inset || sources.count != 2 || frames[secondary] == nil
            if !handle.isHidden, let frame = frames[secondary] { handle.frame = frame }
            positionFrameMessages(); scheduleFrameSample()
        }
        private var secondaryAspect: CGFloat? {
            guard sources.count == 2 else { return nil }
            let role: MediaRole = swapped ? .screen : .camera
            return sources.first(where: { $0.role == role }).flatMap { sizes[$0.id] }.flatMap(PictureInPictureGeometry.aspect)
        }
        func moveInset(dx: CGFloat, dy: CGFloat, keyboard: Bool) {
            guard let preferences, let aspect = secondaryAspect,
                  let rect = PictureInPictureGeometry.frame(bounds: bounds, aspect: aspect, placement: preferences.value) else { return }
            preferences.preview(PictureInPictureGeometry.moving(origin: CGPoint(x: rect.minX + dx, y: rect.minY + dy), bounds: bounds, aspect: aspect, placement: preferences.value))
            layout(); if keyboard { preferences.saveSoon() }
        }
        func resizeInset(dx: CGFloat, dy: CGFloat = 0, keyboard: Bool) {
            guard let preferences, let aspect = secondaryAspect,
                  let rect = PictureInPictureGeometry.frame(bounds: bounds, aspect: aspect, placement: preferences.value), bounds.width > 0 else { return }
            let delta = abs(dx) >= abs(dy * aspect) ? dx : dy * aspect
            var next = preferences.value; next.width = (rect.width + delta) / bounds.width
            next = PictureInPictureGeometry.moving(origin: rect.origin, bounds: bounds, aspect: aspect, placement: next.validated)
            preferences.preview(next); layout(); if keyboard { preferences.saveSoon() }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { preferences?.flush(); stopFrameTimer() }
            super.viewWillMove(toWindow: newWindow)
        }
        func tearDown() {
            stopFrameTimer(); subscription = nil
            windowObservers.forEach { NotificationCenter.default.removeObserver($0) }; windowObservers.removeAll()
            frameBindings.values.forEach { $0.recovery?.cancel() }; frameBindings.removeAll()
            videos.forEach { $0.detach() }; playback = nil
        }
        deinit { frameTimer?.invalidate(); windowObservers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
struct LayoutMenu: View {
    @ObservedObject var store: AppStore
    @ObservedObject var playback: Playback
    func available(_ layout: VideoLayout) -> Bool {
        if layout == .screen { return playback.views.contains { $0.role == .screen } }
        if layout == .camera { return playback.views.contains { $0.role == .camera } }
        return playback.views.count == 2
    }
    var body: some View {
        Menu {
            ForEach(VideoLayout.allCases, id: \.self) { layout in
                Button((store.lecture?.layout ?? .inset) == layout ? "✓ " + layout.rawValue : layout.rawValue) { if let id = store.current { store.updateLecture(id) { $0.layout = layout } } }.disabled(!available(layout))
            }
            if let id = store.current, (store.lecture?.mediaSources.count ?? 0) < 2 { Button("添加第二路视频…") { store.addSecondVideo(id) } }
            Button("恢复默认小窗") { store.pipPreferences.reset() }.disabled((store.lecture?.layout ?? .inset) != .inset || playback.views.count < 2)
            Button("交换主次画面") { if let id = store.current { store.updateLecture(id) { $0.swapped = !($0.swapped ?? false) } } }.disabled(playback.views.count < 2)
            Button("调整两路视频同步…"){store.adjustMediaOffset()}.disabled(playback.views.count<2)
            Divider()
            ForEach(playback.views) { source in
                Button((playback.audioID == source.id ? "✓ " : "") + source.role.rawValue + "音频") { playback.selectAudio(source.id); if let id = store.current { store.updateLecture(id) { $0.audioSourceID = source.id } } }.disabled(!playback.hasAudio(source.id))
            }
        } label: { Image(systemName: "rectangle.split.2x1") }.menuStyle(.borderlessButton).frame(width: 28).help("画面布局与音频").accessibilityLabel("画面布局与音频")
    }
}

func videoFrames(_ sources: [MediaSource], mode: VideoLayout, swapped: Bool, bounds: CGRect, sizes: [UUID: CGSize] = [:], placement: PictureInPicturePlacement = .init()) -> [Int: CGRect] {
            let screen = sources.firstIndex { $0.role == .screen } ?? 0
            let camera = sources.firstIndex { $0.role == .camera } ?? 0
            let primary = swapped ? camera : screen, secondary = swapped ? screen : camera
            var frames = [Int: NSRect]()
            if sources.count == 1 { frames[0] = bounds }
            else {
                switch mode {
                case .screen: frames[screen] = bounds
                case .camera: frames[camera] = bounds
                case .horizontal:
                    frames[primary] = NSRect(x: 0,y: 0,width: bounds.width / 2 - 1,height: bounds.height)
                    frames[secondary] = NSRect(x: bounds.width / 2 + 1,y: 0,width: bounds.width / 2 - 1,height: bounds.height)
                case .vertical:
                    frames[primary] = NSRect(x: 0,y: 0,width: bounds.width,height: bounds.height / 2 - 1)
                    frames[secondary] = NSRect(x: 0,y: bounds.height / 2 + 1,width: bounds.width,height: bounds.height / 2 - 1)
                case .inset:
                    frames[primary] = bounds
                    if let size = sizes[sources[secondary].id], let aspect = PictureInPictureGeometry.aspect(size) {
                        frames[secondary] = PictureInPictureGeometry.frame(bounds: bounds, aspect: aspect, placement: placement)
                    }
                }
            }
    return frames
}
