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

/// Keep each AVPlayerView attached to its own player across all layouts.
/// Swapping players between reused SwiftUI representables can detach the other's video surface.
struct VideoCanvas: NSViewRepresentable {
    let playback: Playback; let layout: VideoLayout; let swapped: Bool
    let preferences: PictureInPicturePreferences
    func makeNSView(context: Context) -> Canvas { Canvas() }
    func updateNSView(_ view: Canvas, context: Context) {
        view.configure(playback, layout: layout, swapped: swapped, preferences: preferences)
    }
    final class Canvas: NSView {
        let videos = [AVPlayerView(), AVPlayerView()]
        let handle = PictureInPictureHandle()
        let messages = [NSTextField(wrappingLabelWithString: ""), NSTextField(wrappingLabelWithString: "")]
        var sizes: [UUID: CGSize] = [:]
        var preferences: PictureInPicturePreferences?
        private var subscription: AnyCancellable?
        var sources: [MediaSource] = []; var mode: VideoLayout = .inset; var swapped = false
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
            for i in videos.indices {
                let v = videos[i]; v.controlsStyle = .none; v.videoGravity = .resizeAspect; v.wantsLayer = true; v.layer?.backgroundColor = NSColor.black.cgColor
                addSubview(v)
                let message = messages[i]
                message.alignment = .center; message.textColor = .white; message.backgroundColor = .black
                message.drawsBackground = true; message.font = .systemFont(ofSize: 12)
                message.isSelectable = false; message.isHidden = true; message.wantsLayer = true
                addSubview(message)
            }
            addSubview(handle); handle.isHidden = true
            handle.move = { [weak self] dx, dy, keyboard in self?.moveInset(dx: dx, dy: dy, keyboard: keyboard) }
            handle.resize = { [weak self] dx, dy, keyboard in self?.resizeInset(dx: dx, dy: dy, keyboard: keyboard) }
            handle.commit = { [weak self] in self?.preferences?.flush() }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
        func configure(_ playback: Playback, layout: VideoLayout, swapped: Bool, preferences: PictureInPicturePreferences) {
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
                guard i < sources.count else { videos[i].isHidden = true; continue }
                let source = sources[i], player = playback.player(for: source)
                if videos[i].player !== player { videos[i].player = player }
                videos[i].setAccessibilityLabel(source.role.rawValue + "视频")
                messages[i].stringValue = playback.missing.contains(source.id) ? source.role.rawValue + "文件缺失 · 在本课文件中重新选择" :
                    playback.ended.contains(source.id) ? "该视角已结束" : playback.isBeforeStart(source) ? "该视角尚未开始" : ""
            }
            needsLayout = true
        }
        override func layout() {
            super.layout(); guard !sources.isEmpty else { videos.forEach { $0.isHidden = true }; messages.forEach { $0.isHidden = true }; handle.isHidden = true; return }
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
                messages[i].layer?.zPosition = 2
                videos[i].layer?.borderWidth = mode == .inset && sources.count == 2 && i == secondary ? 1 : 0
                videos[i].layer?.borderColor = NSColor.gray.cgColor
            }
            for i in videos.indices { videos[i].layer?.zPosition = mode == .inset && sources.count == 2 && i == secondary ? 1 : 0 }
            handle.wantsLayer = true; handle.layer?.zPosition = 3
            handle.isHidden = mode != .inset || sources.count != 2 || frames[secondary] == nil
            if !handle.isHidden, let frame = frames[secondary] { handle.frame = frame }
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
            if newWindow == nil { preferences?.flush() }
            super.viewWillMove(toWindow: newWindow)
        }
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
