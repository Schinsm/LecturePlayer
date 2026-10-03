import SwiftUI
import AVKit
import Core

struct DualVideoView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var playback: Playback
    var body: some View {
        ZStack {
            VideoCanvas(playback: playback, layout: store.lecture?.layout ?? .inset, swapped: store.lecture?.swapped ?? false)
            GeometryReader { geometry in
                ForEach(Array(playback.views.enumerated()), id: \.element.id) { index, source in
                    if let frame = videoFrames(playback.views, mode: store.lecture?.layout ?? .inset, swapped: store.lecture?.swapped ?? false, bounds: CGRect(origin: .zero, size: geometry.size))[index], !message(source).isEmpty {
                        Text(message(source)).foregroundStyle(.white).font(.caption).multilineTextAlignment(.center)
                            .frame(width: max(0, frame.width - 16)).padding(4).background(.black)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }.allowsHitTesting(false)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
    }
    func message(_ source: MediaSource) -> String {
        if playback.missing.contains(source.id) { return source.role.rawValue + "文件缺失 · 在本课文件中重新选择" }
        if playback.ended.contains(source.id) { return "该视角已结束" }
        return playback.isBeforeStart(source) ? "该视角尚未开始" : ""
    }
}

/// Keep each AVPlayerView attached to its own player across all layouts.
/// Swapping players between reused SwiftUI representables can detach the other's video surface.
struct VideoCanvas: NSViewRepresentable {
    let playback: Playback; let layout: VideoLayout; let swapped: Bool
    func makeNSView(context: Context) -> Canvas { Canvas() }
    func updateNSView(_ view: Canvas, context: Context) {
        view.configure(playback, layout: layout, swapped: swapped)
    }
    final class Canvas: NSView {
        let videos = [AVPlayerView(), AVPlayerView()]
        var sources: [MediaSource] = []; var mode: VideoLayout = .inset; var swapped = false
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
            for i in videos.indices {
                let v = videos[i]; v.controlsStyle = .none; v.videoGravity = .resizeAspect; v.wantsLayer = true; v.layer?.backgroundColor = NSColor.black.cgColor
                addSubview(v)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
        func configure(_ playback: Playback, layout: VideoLayout, swapped: Bool) {
            sources = playback.views; mode = layout; self.swapped = swapped
            for i in videos.indices {
                guard i < sources.count else { videos[i].isHidden = true; continue }
                let source = sources[i], player = playback.player(for: source)
                if videos[i].player !== player { videos[i].player = player }
                videos[i].setAccessibilityLabel(source.role.rawValue + "视频")

            }
            needsLayout = true
        }
        override func layout() {
            super.layout(); guard !sources.isEmpty else { return }
            let screen = sources.firstIndex { $0.role == .screen } ?? 0
            let camera = sources.firstIndex { $0.role == .camera } ?? 0
            let secondary = swapped ? screen : camera
            let frames = videoFrames(sources, mode: mode, swapped: swapped, bounds: bounds)
            for i in videos.indices {
                videos[i].isHidden = frames[i] == nil
                if let frame = frames[i] { videos[i].frame = frame }
                videos[i].layer?.borderWidth = mode == .inset && sources.count == 2 && i == secondary ? 1 : 0
                videos[i].layer?.borderColor = NSColor.gray.cgColor
            }
            for i in videos.indices { videos[i].layer?.zPosition = mode == .inset && sources.count == 2 && i == secondary ? 1 : 0 }

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
            Button("交换主次画面") { if let id = store.current { store.updateLecture(id) { $0.swapped = !($0.swapped ?? false) } } }.disabled(playback.views.count < 2)
            Button("调整两路视频同步…"){store.adjustMediaOffset()}.disabled(playback.views.count<2)
            Divider()
            ForEach(playback.views) { source in
                Button((playback.audioID == source.id ? "✓ " : "") + source.role.rawValue + "音频") { playback.selectAudio(source.id); if let id = store.current { store.updateLecture(id) { $0.audioSourceID = source.id } } }.disabled(!playback.hasAudio(source.id))
            }
        } label: { Image(systemName: "rectangle.split.2x1") }.menuStyle(.borderlessButton).frame(width: 28).help("画面布局与音频").accessibilityLabel("画面布局与音频")
    }
}

func videoFrames(_ sources: [MediaSource], mode: VideoLayout, swapped: Bool, bounds: CGRect) -> [Int: CGRect] {
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
                    frames[secondary] = NSRect(x: bounds.width * 0.68 - 10,y: bounds.height * 0.68 - 10,width: bounds.width * 0.32,height: bounds.height * 0.32)
                }
            }
    return frames
}
