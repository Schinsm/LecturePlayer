import SwiftUI
import AppKit
import AVKit
import Core
import Combine

struct PlayerPage: View {
    @ObservedObject private var columns:ReadingColumns
    @ObservedObject private var shortcuts=PlaybackShortcuts.shared
    @ObservedObject var store: AppStore
    init(store:AppStore){self.store=store;columns=store.readingColumns}
    var body: some View {
        VStack(spacing: 0) {
            PlaybackHeader(store: store)
            TransferStatus(transfer: store.transfer).padding(.horizontal, 12)
            ReadingColumnsHost(columns:columns,identity:store.current) {
                VideoPane(store:store,playback:store.playback)
            } chapters: {
                ChapterColumn(store:store)
            } transcript: {
                TranscriptColumn(store:store)
            }

        }.background(PlayerKeys(action: playbackKey)).id(store.current)
    }
    func playbackKey(_ code:UInt16,_ modifiers:NSEvent.ModifierFlags)->Bool {
        guard let command=shortcuts.resolve(code,modifiers) else{return false}
        if command == .search,let id=store.current {
            columns.show(.transcript)
            store.readerPresentation.session(id).searchRequest += 1
            return true
        }
        guard store.playback.ready else{return true}
        guard let action=shortcuts.transport(command,position:store.playback.position,cues:store.transcript?.cues ?? [],mapper:store.lecture?.state.timingMapper ?? SubtitleTimingMapper()) else{return true}
        switch action {case .toggle:store.playback.toggle();case .seek(let seconds):store.playback.seek(seconds)}
        return true
    }
}

struct PlaybackHeader: View {
    @ObservedObject var store: AppStore
    @LPState private var details = false
    @LPState private var files = false
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { store.back() } label: { Image(systemName: "chevron.left") }.help("课程库").accessibilityLabel("课程库")
            VStack(alignment: .leading, spacing: 2) {
                Text(store.breadcrumb).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(store.lecture.map(LessonCatalog.displayTitle) ?? "").font(.headline).lineLimit(1).help(store.lecture?.title ?? "")
                if store.lessonLoading { Text("正在载入课件…").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let id=store.current {ReadingSearchField(session:store.readerPresentation.session(id),columns:store.readingColumns)}
            ReadingSwitches(columns:store.readingColumns)
            LayoutMenu(store:store,playback:store.playback,columns:store.readingColumns)
            Menu {
                Button("本课文件…") { files=true }
                Button("添加或更换英文字幕…") {store.replaceSubtitle()}.disabled(store.translation.busy)
                Menu("导出") {
                    Button("导出本课资料包…") {store.exportStudyPackage()}
                    Button("导出章节…") {store.exportAnalysis()}
                    Divider()
                    ForEach(ExportKind.allCases,id: \.self){kind in Button(kind.rawValue){store.export(kind)}}
                }
                Divider()
                Button("添加书签") {
                    if let id = store.current, let note = askName("书签备注", initial: "书签") {
                        store.updateLecture(id) { $0.marks.append(Mark(seconds: store.playback.position, note: note)) }
                    }
                }.keyboardShortcut("b")
                ForEach(store.lecture?.marks ?? []) { mark in
                    Button("\(timeLabel(mark.seconds)) · \(mark.note)") { store.playback.seek(mark.seconds) }
                }
            } label: { GlassIcon(systemName: "ellipsis") }.glassMenuStyle().help("本课文件、导出与书签").accessibilityLabel("本课文件、导出与书签")
        }.buttonStyle(.borderless).padding(.horizontal,12).padding(.vertical,10).sheet(isPresented:$files){DataLocations(store:store,lessonID:store.current)}.sheet(isPresented: $details) { if let id = store.current { LessonDetails(store: store, ids: [id]) } }
    }
}

/// Reports pointer movement over the video without taking clicks from it.
struct PointerActivity: NSViewRepresentable {
    let moved: () -> Void
    func makeNSView(context: Context) -> TrackingView { let view = TrackingView(); view.moved = moved; return view }
    func updateNSView(_ view: TrackingView, context: Context) { view.moved = moved }
    final class TrackingView: NSView {
        var moved: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        override func mouseMoved(with event: NSEvent) { moved?() }
        override func mouseEntered(with event: NSEvent) { moved?() }
    }
}

/// One search for both reading columns: chapters filter, the transcript highlights matches.
struct ReadingSearchField: View {
    @ObservedObject var session:ReaderSession
    @ObservedObject var columns:ReadingColumns
    @FocusState private var focused:Bool
    var body: some View {
        if columns.value.enabled {
            HStack(spacing:6) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索章节与转写",text:Binding(get:{session.reader.query},set:{value in
                    if value.isEmpty {clear()} else {session.reader.search(value);session.chapterQuery=value}
                })).textFieldStyle(.plain).focused($focused).frame(width:180).accessibilityLabel("搜索章节与转写")
                if !session.reader.query.isEmpty {
                    Button {clear()} label: {Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}
                        .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal,12).frame(height:32).glassSurface(Capsule())
            .onChange(of:session.searchRequest) {_,_ in focused=true}
        }
    }
    /// Leaving search returns both columns to the playing position.
    private func clear() {session.reader.resume();session.followChapters()}
}

/// 章节 / 转写 switches: the single place to show or hide each reading column.
struct ReadingSwitches: View {
    @ObservedObject var columns:ReadingColumns
    var body: some View {
        HStack(spacing:2) {
            item("章节",icon:"list.bullet",pane:.chapters)
            item("转写",icon:"text.alignleft",pane:.transcript)
        }.padding(3).glassSurface(Capsule())
    }
    private func item(_ title:String,icon:String,pane:ReadingColumns.Pane)->some View {
        let on=columns.isOn(pane)
        return Button {columns.toggle(pane)} label: {
            Label(title,systemImage:icon).font(.callout.weight(on ? .semibold:.regular)).padding(.horizontal,10).frame(height:26)
                .background {if on {Capsule().fill(Color.primary.opacity(0.14))}}.contentShape(Capsule())
        }.buttonStyle(.plain).foregroundStyle(on ? .primary:.secondary)
        .help(on ? "收起"+title:"显示"+title).accessibilityLabel(title).accessibilityValue(on ? "显示":"已收起")
    }
}

struct VideoPane: View {
    @ObservedObject private var shortcuts=PlaybackShortcuts.shared
    @ObservedObject var store: AppStore
    @ObservedObject var playback: Playback
    @LPState private var resumed = false
    @LPState private var controlsShown = true
    @LPState private var overControls = false
    @LPState private var hideTask: Task<Void,Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 10) {
            DualVideoView(store: store, playback: playback)
                .background(VideoEdgeAnchor())
                .overlay(alignment: .bottom) {
                    VideoCaptionOverlay(store: store, playback: playback, presentation:store.captions)
                        .padding(.bottom, controlsShown ? 96 : 0)
                }
                // Controls float over the video and fade out during playback when the pointer rests.
                .overlay(PointerActivity { revealControls() })
                .overlay(alignment: .bottom) {
                    controls
                        .frame(maxWidth: 820).padding(.horizontal, 16).padding(.bottom, 14)
                        .opacity(controlsShown ? 1 : 0).allowsHitTesting(controlsShown)
                        .onHover { inside in overControls = inside; if !inside { scheduleHide() } }
                }
                .onChange(of: playback.playing) { _, playing in if playing { scheduleHide() } else { revealControls() } }
            if let error = playback.error {
                Text(error).foregroundStyle(.red)
                if playback.missing.isEmpty {
                    Button(playback.ready ? "恢复播放" : "重试载入") {
                        if playback.ready { playback.toggle() } else if let lesson=store.lecture {playback.retryLoad(lesson)}
                    }
                } else { Button("重新定位文件") { store.relocate() } }
            }
            PlaylistEndAction(store:store,playback:playback,presentation:store.playlist)
        }.padding(.horizontal, 12).padding(.bottom, 10)
    }
    private var controls: some View {
        VStack(spacing: 6) {
            PlaybackPositionSlider(playback:playback, clock:playback.clock)
            ViewThatFits(in: .horizontal) {
                controlRow(compact: false)
                controlRow(compact: true)
                VStack(spacing: 4) {
                    timeDisplay.frame(maxWidth: .infinity, alignment: .leading)
                    HStack { transportControls; Spacer(minLength: 8); audioControls(compact: true) }
                }
            }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassSurface(RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }
    private func revealControls() {
        if !controlsShown { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { controlsShown = true } }
        scheduleHide()
    }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            // VoiceOver users keep the controls: hidden controls leave the accessibility tree.
            guard !Task.isCancelled, playback.playing, !overControls, !NSWorkspace.shared.isVoiceOverEnabled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { controlsShown = false }
        }
    }
    private var timeDisplay: some View {
        PlaybackTimeLabel(clock:playback.clock,duration:playback.duration)
    }
    private var transportControls: some View {
        HStack(spacing: 20) {
                Button { playback.seek(playback.position - 10) } label: { Image(systemName: "gobackward.10") }
                Button {
                    if !resumed && UserDefaults.standard.bool(forKey: "rewind") { playback.seek(playback.position - 3) }
                    resumed = true; playback.toggle()
                } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill") }
                    .disabled(!playback.ready).accessibilityLabel("播放或暂停").help("播放／暂停（"+shortcuts.key(.toggle).label+"）")
                Button { playback.seek(playback.position + 10) } label: { Image(systemName: "goforward.10") }
        }.fixedSize().padding(.horizontal, 16)
    }
    private func controlRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            timeDisplay.frame(minWidth: compact ? 140 : 375, maxWidth: .infinity, alignment: .leading)
            transportControls
            audioControls(compact: compact).frame(minWidth: compact ? 190 : 375, maxWidth: .infinity, alignment: .trailing)
        }
    }
    @LPState private var volumeOpen = false
    private func audioControls(compact: Bool) -> some View {
        HStack(spacing: 10) {
                CoursePlaylistButton(store:store)
                VideoCaptionControls(store: store, presentation:store.captions)
                PlaybackSpeedButton(speed: store.lecture?.state.speed ?? 1) { speed in
                    if let id = store.current { store.updateLecture(id) { $0.state.speed = speed }; playback.speed(speed) }
                }.frame(width: compact ? 55 : 80, height: 24)
                Button { volumeOpen.toggle() } label: { Image(systemName: playback.volume == 0 ? "speaker.slash" : "speaker.wave.2") }.accessibilityLabel("音量").help("音量")
                    .popover(isPresented: $volumeOpen) {
                        HStack { Button {playback.toggleMute()} label: {Image(systemName: playback.volume == 0 ? "speaker.wave.2" : "speaker.slash")}.accessibilityLabel("静音或恢复音量"); Slider(value: Binding(get: {playback.volume}, set: {playback.setVolume($0)}), in: 0...1).frame(width: 140).accessibilityLabel("音量") }.padding()
                    }
                StudyFullscreenButton()
        }.fixedSize(horizontal: true, vertical: false)
    }

}

struct ReaderPane: View {
    @ObservedObject var store: AppStore
    // Deliberately not ObservedObject: quarter-second ticks update only changed cue IDs.
    let playback: Playback
    var visible = true
    var sourceRequest: ReaderSourceRequest?
    @ObservedObject private var session:ReaderSession
    init(store:AppStore,playback:Playback,visible:Bool=true,sourceRequest:ReaderSourceRequest?=nil){self.store=store;self.playback=playback;self.visible=visible;self.sourceRequest=sourceRequest;session=store.readerPresentation.session(store.current ?? UUID())}
    private var reader:ReadingState {get{session.reader} nonmutating set{session.reader=newValue}}
    @LPState private var timeline = TranscriptTimeline([])
    @LPState private var activeIDs: [String] = []
    @LPState private var anchorID: String?
    @LPState private var scrollRequest = 0
    @LPState private var sourceScrollRequest = 0
    @LPState private var syncOpen = false
    private var scrollID:String? {get{session.scrollID} nonmutating set{session.scrollID=newValue}}
    @LPState private var matches: [Cue] = []
    @LPState private var matchIDs: Set<String> = []
    @LPState private var matchIndex = -1
    @AppStorage("fontSize") private var fontSize = 17.0
    @AppStorage("lineSpacing") private var spacing = 5.0
    @AppStorage("hideSpeakerLabels") private var hideSpeakers = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LPState private var index = ReadingIndex()
    private var units: [TranscriptReadingUnit] {index.units}
    private var cues: [Cue] { store.transcript?.cues ?? [] }
    private var offset: Double { store.lecture?.state.subtitleOffsetSeconds ?? 0 }
    private var mapper: SubtitleTimingMapper { store.lecture?.state.timingMapper ?? SubtitleTimingMapper() }
    /// Changes on mount, when the column is shown, and when reading rows first arrive — not on translation updates.
    var initialPositionKey: String { "\(store.current?.uuidString ?? "")|\(visible)|\(units.isEmpty)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReadingPaneHeader("转写",pane:.transcript,columns:store.readingColumns,following:reader.following,follow:{reader.resume();updateSearch();scrollRequest += 1}) {
                if offset != 0 {Button(mapper.label){syncOpen=true}.font(.caption).help("字幕同步")}
                Menu {
                    Picker("语言", selection:Binding(get:{store.lecture?.state.mode ?? "双语"},set:{mode in if let id=store.current {store.updateLecture(id){$0.state.mode=mode}}})) {
                        ForEach(["双语","英文","中文"],id: \.self){Text($0)}
                    }
                    Picker("译文来源",selection:Binding(get:{store.transcript?.variantID ?? "openAI"},set:{store.selectTranslation($0)})) {
                        ForEach(TranslationService.allCases,id: \.rawValue){Text($0.title).tag($0.rawValue)}
                        if let history=store.transcript?.variants?["legacy"],!history.translations.isEmpty {Text("历史译文").tag("legacy")}
                    }
                    Divider()
                    Toggle("按句显示",isOn:Binding(get:{store.lecture?.readingGrouped ?? true},set:{v in if let id=store.current {store.updateLecture(id){$0.readingGrouped=v}}}))
                    Toggle("隐藏说话人编号",isOn:$hideSpeakers)
                    Button("字号 −"){fontSize=max(12,fontSize-1)}
                    Button("字号 +"){fontSize=min(32,fontSize+1)}
                    Slider(value:$spacing,in:0...16){Text("行距")}
                    Divider()
                    Button("字幕同步…"){syncOpen=true}.disabled(cues.isEmpty)
                } label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize().help("转写阅读设置").accessibilityLabel("转写阅读设置")
            }
            .popover(isPresented:$syncOpen){SubtitleSyncPopover(offset:offset,update:setOffset)}
            TranslationControls(store:store,job:store.translation,query:reader.query)
            ScrollViewReader { proxy in
                if !reader.query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    HStack(spacing:8) {
                        Text(matches.isEmpty ? "无结果" : matchIndex < 0 ? "\(matches.count) 处" : "\(matchIndex+1)/\(matches.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button { jumpMatch(-1, proxy) } label: { Image(systemName: "chevron.up") }.help("上一匹配").accessibilityLabel("上一匹配")
                        Button { jumpMatch(1, proxy) } label: { Image(systemName: "chevron.down") }.help("下一匹配").accessibilityLabel("下一匹配")
                    }.disabled(matches.isEmpty).buttonStyle(.borderless)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let plain = store.transcript?.plain {
                            Text("TXT 资料 · 无时间戳，无法同步").foregroundStyle(.secondary)
                            Text(plain).font(.system(size: fontSize)).lineSpacing(spacing).textSelection(.enabled)
                        }
                        if store.transcript == nil { Text("暂无转写。通过“资料”补充字幕。").foregroundStyle(.secondary) }
                        readingRows
                    }.scrollTargetLayout().padding(.trailing, 12)
                }.onChange(of:scrollID) {_,id in if let id {
                    if reader.following && !reduceMotion {withAnimation(.easeOut(duration:0.18)){proxy.scrollTo(id,anchor:UnitPoint(x:0.5,y:0.35))}}
                    else {proxy.scrollTo(id,anchor:UnitPoint(x:0.5,y:0.35))}
                }}
                    .onChange(of:sourceScrollRequest) {_,_ in if visible,let id=scrollID {proxy.scrollTo(id,anchor:.center)}}
                    .background(ScrollIntent(enabled:visible,onManual: { reader.browse() }))
                    .onChange(of: anchorID) { _, id in if visible, reader.following, let id { scrollID = unitID(id) } }
                    .onChange(of: scrollRequest) { _, _ in if visible,let id = anchorID { scrollID = unitID(id); proxy.scrollTo(unitID(id),anchor:.center) } }
                    .task(id: initialPositionKey) {
                        // Let the split view establish the final text width before initial positioning.
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled, visible, !units.isEmpty else { return }
                        // scrollID lives in the lesson session and survives re-entry; this ScrollView
                        // is new and starts at the top, so scroll explicitly instead of waiting for a change.
                        if reader.following { scrollRequest += 1 }
                        else if scrollID != nil { sourceScrollRequest += 1 }
                    }
            }
        }.padding(12)
            .onChange(of:reader.query){_,_ in updateSearch()}
            .onChange(of:reader.following){_,following in if following {scrollRequest += 1}}
            .onAppear { rebuild() }
            .onChange(of: sourceRequest) { _, request in
                handleSourceRequest()
            }
            .onChange(of: store.preparedReading?.revision) { _, _ in rebuild() }
            .onChange(of: store.transcript?.translations) { _, _ in if visible {updateSearch()} }
            .onChange(of: store.lecture?.readingGrouped) {_,_ in rebuild(); if reader.following,let id = anchorID {scrollID = unitID(id)}}
            .onChange(of: hideSpeakers) {_,_ in updateSearch()}
            .onChange(of: offset) { _, _ in updateActive(playback.position); if visible,reader.following {scrollRequest += 1} }
            .onReceive(playback.clock.$snapshot.map(\.seconds)) { if visible {updateActive($0)} }
            .onChange(of:visible){_,value in if value {updateActive(playback.position);updateSearch();handleSourceRequest()}}
    }

    private func handleSourceRequest() {
        guard visible,let request=sourceRequest,request.id != session.handledSourceRequest,cues.contains(where:{$0.id==request.cueID}) else{return}
        session.handledSourceRequest=request.id;reader.browse();scrollID=unitID(request.cueID);sourceScrollRequest += 1
    }
    private var readingRows: some View {
        ForEach(units) { unit in readingRow(unit) }
    }
    private func readingRow(_ unit: TranscriptReadingUnit) -> some View {
        let active = unit.ids.contains { activeIDs.contains($0) }
        let match = unit.ids.contains { matchIDs.contains($0) }
        let content=session.content.content(unit,translations:store.transcript?.translations ?? [:],mode:store.lecture?.state.mode ?? "双语",hidden:hideSpeakers)
        return ReadingUnitCell(unit: unit, content:content,
            mode: store.lecture?.state.mode ?? "双语", fontSize: fontSize, spacing: spacing,
            active: active, match: match, hideSpeakers: hideSpeakers, mapper: mapper,
            seek: {playback.seek($0)}, browse: {reader.browse()})
            .equatable().id(unit.id).contextMenu { editMenu(unit) }
    }
    private func editMenu(_ unit: TranscriptReadingUnit) -> some View {
        ForEach(unit.cues) { cue in
            Menu(timeLabel(mapper.seekTarget(cue))) {
                Button("编辑中文") {store.editTranslation(cue)}.disabled(store.transcript?.translations[cue.id] == nil)
                Button("恢复原译文") {store.editTranslation(cue, restore: true)}.disabled(store.transcript?.translations[cue.id]?.edited == nil)
            }
        }
    }
    private func setOffset(_ value: Double) {
        guard value.isFinite, abs(value) <= 86400, let id = store.current else { return }
        store.updateLecture(id) { $0.state.subtitleOffsetSeconds = value }
        updateActive(playback.position); if visible,reader.following {scrollRequest += 1}
    }
    private func rebuild() {
        guard let data=store.preparedReading else { index=ReadingIndex(); timeline=TranscriptTimeline([]); activeIDs=[]; anchorID=nil; updateSearch(); return }
        index=data.index(grouped:store.lecture?.readingGrouped ?? true); timeline=data.timeline; updateActive(playback.position); updateSearch()
    }
    private func updateActive(_ position: Double) {
        let next = timeline.readingFocus(at: position, mapper: mapper)
        if next != activeIDs { activeIDs = next }
        let anchor = next.first ?? timeline.anchor(at: position, mapper: mapper)
        if anchor != anchorID { anchorID = anchor }
    }
    private func unitID(_ cueID: String) -> String {index.unitID(for:cueID) ?? cueID}
    private func updateSearch() {
        let query = reader.query
        let ids = ReadingSearch.matches(units, translations: store.transcript?.translations ?? [:], query: query, hideSpeakers: hideSpeakers)
        matches = cues.filter {ids.contains($0.id)}
        matchIDs = Set(matches.map(\.id)); matchIndex = -1
    }
    private func jumpMatch(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }; reader.browse()
        matchIndex = matchIndex < 0 ? (delta > 0 ? 0 : matches.count - 1) : (matchIndex + delta + matches.count) % matches.count
        scrollID = unitID(matches[matchIndex].id); proxy.scrollTo(unitID(matches[matchIndex].id),anchor:.center)
    }

}

struct CueCell: View, Equatable {
    let cue: Cue; let translation: String?; let mode: String; let fontSize: Double; let spacing: Double
    let active: Bool; let match: Bool; let targetSeconds: Double; let seek: (Double) -> Void
    var browse: () -> Void = {}
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cue == rhs.cue && lhs.translation == rhs.translation && lhs.mode == rhs.mode && lhs.fontSize == rhs.fontSize && lhs.spacing == rhs.spacing && lhs.active == rhs.active && lhs.match == rhs.match && lhs.targetSeconds == rhs.targetSeconds
    }
    private var displayedText: String {
        if mode == "英文" || translation == nil { return cue.en }
        if mode == "中文" { return translation! }
        return cue.en + "\n" + translation!
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(timeLabel(targetSeconds), action: { seek(targetSeconds) }).buttonStyle(.link).font(.caption.monospacedDigit())
            CueText(text: displayedText, fontSize: fontSize, lineSpacing: spacing, jump: { seek(targetSeconds) }, browse: browse)
        }.font(.system(size: fontSize)).lineSpacing(spacing).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(active ? Color.accentColor.opacity(0.14) : match ? Color.yellow.opacity(0.12) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SubtitleSyncPopover: View {
    let offset: Double
    let update: (Double) -> Void
    @LPState private var precise = ""
    @LPState private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("字幕同步").font(.headline)
            Text(SubtitleTimingMapper(offset: offset).label).monospacedDigit()
            Text("正数让字幕延后，负数让字幕提前。原始 VTT 不变。").font(.caption)
            HStack {
                Button("−0.5s") { update((offset - 0.5).roundedToMilliseconds) }
                Button("−0.1s") { update((offset - 0.1).roundedToMilliseconds) }
                Button("重置") { update(0) }
                Button("+0.1s") { update((offset + 0.1).roundedToMilliseconds) }
                Button("+0.5s") { update((offset + 0.5).roundedToMilliseconds) }
            }
            Button("版权片头 +14 秒") { update(14) }
            Text("适用于视频新增约 14 秒版权片头、字幕时间未变化的情况；设置后可微调。").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("精确输入") {
                HStack {
                    TextField("秒，例如 +1.500", text: $precise).frame(width: 150)
                    Button("应用") {
                        guard let value = Double(precise.replacingOccurrences(of: ",", with: ".")), value.isFinite, abs(value) <= 86400 else { error = "请输入 −86400 到 +86400 秒"; return }
                        error = ""; update(value.roundedToMilliseconds)
                    }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(16).frame(width: 440)
            .onAppear { precise = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), offset) }
            .onChange(of: offset) { _, value in precise = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }
    }
}
private extension Double { var roundedToMilliseconds: Double { (self * 1000).rounded() / 1000 } }

struct ReadingUnitCell: View, Equatable {
    static func ==(a:Self,b:Self)->Bool {a.unit.cues==b.unit.cues && a.content==b.content && a.fontSize==b.fontSize && a.spacing==b.spacing && a.active==b.active && a.match==b.match && a.mapper==b.mapper}
    let unit: TranscriptReadingUnit
    let content:ReadingText
    let mode: String; let fontSize: Double; let spacing: Double
    let active: Bool; let match: Bool; let hideSpeakers: Bool
    let mapper: SubtitleTimingMapper
    let seek: (Double)->Void; let browse: ()->Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(timeLabel(mapper.seekTarget(unit.cues[0]))) {seek(mapper.seekTarget(unit.cues[0]))}.buttonStyle(.link).font(.caption.monospacedDigit())
            CueText(text: content.text, fontSize: fontSize, lineSpacing: spacing, jump: {seek(mapper.seekTarget(unit.cues[0]))}, browse: browse,
                    characterJump: {index in if let id = content.cue(atUTF16:index), let cue = unit.cues.first(where: {$0.id == id}) {seek(mapper.seekTarget(cue))}})
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(active ? Color.accentColor.opacity(0.14) : match ? Color.yellow.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}


private struct PlaybackTimeLabel: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    var body: some View { Text("\(timeLabel(clock.snapshot.seconds)) / \(timeLabel(duration))").font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65) }
}
private struct PlaybackPositionSlider: View {
    @ObservedObject var playback: Playback
    @ObservedObject var clock: PlaybackClock
    var body: some View {
        Slider(value: Binding(get: {clock.snapshot.seconds}, set: {playback.seek($0)}),in:0...max(1,playback.duration))
            .disabled(!playback.ready).accessibilityLabel("播放位置")
    }
}
