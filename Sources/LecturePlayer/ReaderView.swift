import SwiftUI
import AppKit
import AVKit
import Core
import Combine

struct PlayerPage: View {
    @AppStorage("readerPaneVisible") private var readerVisible = true
    @ObservedObject private var shortcuts=PlaybackShortcuts.shared
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            PlaybackHeader(store: store)
            TransferStatus(transfer: store.transfer).padding(.horizontal, 12)
            StudySplit(identity:store.current, rightVisible:readerVisible) {
                VideoPane(store: store, playback: store.playback)
            } right: {
                StudyReaderPane(store: store, playback: store.playback)
            }
        }.background(PlayerKeys(action: playbackKey)).id(store.current)
    }
    private func playbackKey(_ code:UInt16,_ modifiers:NSEvent.ModifierFlags)->Bool {
        guard let command=shortcuts.resolve(code,modifiers) else{return false}
        if command == .search,let id=store.current {
            readerVisible = true
            store.readerPresentation.select("transcript",lesson:id)
            store.readerPresentation.session(id).searchRequest += 1
            return true
        }
        guard store.playback.ready else{return false}
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
        HStack {
            Button { store.back() } label: { Image(systemName: "chevron.left") }.help("课程库").accessibilityLabel("课程库")
            VStack(alignment: .leading, spacing: 2) {
                Text(store.breadcrumb).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(store.lecture?.displayTitle ?? "").font(.headline).lineLimit(1)
            }
            Spacer()
            LayoutMenu(store: store, playback: store.playback)
            Menu {
                Button("本课文件…") { files=true }
                Button("添加或更换英文字幕…") {store.replaceSubtitle()}.disabled(store.translation.busy)
                Menu("导出") {
                    Button("导出本课资料包…") {store.exportStudyPackage()}
                    Button("导出总结与章节…") {store.exportAnalysis()}
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
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28).help("本课文件、导出与书签").accessibilityLabel("本课文件、导出与书签")
        }.buttonStyle(.borderless).padding(12).sheet(isPresented:$files){DataLocations(store:store,lessonID:store.current)}.sheet(isPresented: $details) { if let id = store.current { LessonDetails(store: store, ids: [id]) } }
    }
}

struct VideoPane: View {
    @ObservedObject private var shortcuts=PlaybackShortcuts.shared
    @ObservedObject var store: AppStore
    @ObservedObject var playback: Playback
    @LPState private var resumed = false
    var body: some View {
        VStack(spacing: 10) {
            DualVideoView(store: store, playback: playback)
                .overlay(alignment: .trailing) { ReaderPaneToggle().padding(.trailing, 4) }
                .overlay(alignment: .bottom) { VideoCaptionOverlay(store: store, playback: playback, presentation:store.captions) }
            if let error = playback.error {
                Text(error).foregroundStyle(.red)
                Button("重新定位文件") { store.relocate() }
            }
            Slider(value: Binding(get: { playback.position }, set: { playback.seek($0) }), in: 0...max(1, playback.duration))
                .disabled(!playback.ready).accessibilityLabel("播放位置")
            ViewThatFits(in: .horizontal) {
                controlRow(compact: false)
                controlRow(compact: true)
                VStack(spacing: 4) {
                    timeDisplay.frame(maxWidth: .infinity, alignment: .leading)
                    HStack { transportControls; Spacer(minLength: 8); audioControls(compact: true) }
                }
            }.buttonStyle(.borderless).padding(.bottom, 10)
        }.padding(.horizontal, 12)
    }
    private var timeDisplay: some View {
        Text("\(timeLabel(playback.position)) / \(timeLabel(playback.duration))")
            .font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
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
            timeDisplay.frame(minWidth: compact ? 190 : 375, maxWidth: .infinity, alignment: .leading)
            transportControls
            audioControls(compact: compact).frame(minWidth: compact ? 190 : 375, maxWidth: .infinity, alignment: .trailing)
        }
    }
    @LPState private var volumeOpen = false
    private func audioControls(compact: Bool) -> some View {
        HStack(spacing: 10) {
                VideoCaptionControls(store: store, presentation:store.captions)
                Picker("倍速", selection: Binding(get: { store.lecture?.state.speed ?? 1 }, set: { speed in
                    if let id = store.current { store.updateLecture(id) { $0.state.speed = speed }; playback.speed(speed) }
                })) { ForEach([0.75,1,1.25,1.5,1.75,2,2.5], id: \.self) { Text("\($0.formatted())×").tag($0) } }
                    .labelsHidden().frame(width: compact ? 55 : 80)
                Button { if compact { volumeOpen.toggle() } else { playback.toggleMute() } } label: { Image(systemName: playback.volume == 0 ? "speaker.slash" : "speaker.wave.2") }.accessibilityLabel("静音或恢复音量")
                    .popover(isPresented: $volumeOpen) {
                        HStack { Button {playback.toggleMute()} label: {Image(systemName: "speaker.slash")}; Slider(value: Binding(get: {playback.volume}, set: {playback.setVolume($0)}), in: 0...1).frame(width: 140) }.padding()
                    }
                if !compact {
                    Slider(value: Binding(get: { playback.volume }, set: { playback.setVolume($0) }), in: 0...1)
                        .frame(width: 120).accessibilityLabel("音量")
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
    @LPState private var syncOpen = false
    private var scrollID:String? {get{session.scrollID} nonmutating set{session.scrollID=newValue}}
    @LPState private var matches: [Cue] = []
    @LPState private var matchIDs: Set<String> = []
    @LPState private var matchIndex = -1
    @AppStorage("fontSize") private var fontSize = 17.0
    @AppStorage("lineSpacing") private var spacing = 5.0
    @FocusState private var searchFocused: Bool
    @AppStorage("hideSpeakerLabels") private var hideSpeakers = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LPState private var handledSearchRequest=0
    @LPState private var index = ReadingIndex()
    private var units: [TranscriptReadingUnit] {index.units}
    private var cues: [Cue] { store.transcript?.cues ?? [] }
    private var offset: Double { store.lecture?.state.subtitleOffsetSeconds ?? 0 }
    private var mapper: SubtitleTimingMapper { store.lecture?.state.timingMapper ?? SubtitleTimingMapper() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("译文来源", selection: Binding(get:{store.transcript?.variantID ?? "openAI"},set:{store.selectTranslation($0)})) {
                ForEach(TranslationService.allCases,id: \.rawValue) { service in
                    Text("\(service.title) · \(store.transcript?.variants?[service.rawValue]?.translations.count ?? 0)/\(cues.count)").tag(service.rawValue)
                }
                if let history=store.transcript?.variants?["legacy"], !history.translations.isEmpty {Text("历史译文 · \(history.translations.count)/\(cues.count)").tag("legacy")}
            }.controlSize(.small).accessibilityLabel("译文来源")
            TranslationControls(store: store, job: store.translation, query: reader.query)
            HStack {
                TextField("搜索中英文", text: Binding(get: { reader.query }, set: { reader.search($0); updateSearch() }))
                    .focused($searchFocused).textFieldStyle(.roundedBorder)
                Text("\(matches.count)").font(.caption)
                Menu {
                    Toggle("按句显示", isOn: Binding(get: {store.lecture?.readingGrouped ?? true}, set: {v in if let id = store.current {store.updateLecture(id) {$0.readingGrouped = v}}}))
                    Toggle("隐藏自动说话人编号", isOn: $hideSpeakers)
                    Button("字号 −") { fontSize = max(12, fontSize-1) }; Button("字号 +") { fontSize = min(32, fontSize+1) }; Slider(value: $spacing, in: 0...16) { Text("行距") } } label: { Image(systemName: "textformat.size") }.menuStyle(.borderlessButton).frame(width: 30).help("阅读设置")
            }
            HStack {
                Picker("显示", selection: Binding(get: { store.lecture?.state.mode ?? "双语" }, set: { mode in
                    if let id = store.current { store.updateLecture(id) { $0.state.mode = mode } }
                })) { ForEach(["双语", "英文", "中文"], id: \.self) { Text($0) } }.labelsHidden()
                Spacer()
                Button(reader.following ? "跟随播放" : "回到当前播放") { reader.resume(); updateSearch(); scrollRequest += 1 }
            }
            Button(mapper.label, systemImage: "clock.arrow.2.circlepath") { syncOpen.toggle() }
                .accessibilityLabel("字幕同步：" + mapper.label)
                .popover(isPresented: $syncOpen) {
                    SubtitleSyncPopover(offset: offset, update: setOffset)
                }.disabled(cues.isEmpty)
            ScrollViewReader { proxy in
                if !reader.query.isEmpty {
                    HStack { Button { jumpMatch(-1, proxy) } label: { Image(systemName: "chevron.up") }.help("上一匹配")
                        Button { jumpMatch(1, proxy) } label: { Image(systemName: "chevron.down") }.help("下一匹配")
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
                    .onChange(of:sourceRequest) {_,request in if visible,let request {proxy.scrollTo(unitID(request.cueID),anchor:.center)}}.background(ScrollIntent(enabled:visible,onManual: { reader.browse() }))
                    .onChange(of: anchorID) { _, id in if visible, reader.following, let id { scrollID = unitID(id) } }
                    .onChange(of: scrollRequest) { _, _ in if visible,let id = anchorID { scrollID = unitID(id); proxy.scrollTo(unitID(id),anchor:.center) } }
                    .task {
                        // Let the split view establish the final text width before initial positioning.
                        try? await Task.sleep(for: .milliseconds(200))
                        if !Task.isCancelled, visible, reader.following, let id = anchorID { scrollID = unitID(id) }
                    }
            }
        }.padding(12)
            .onChange(of:session.searchRequest){_,_ in focusRequestedSearch()}
            .onAppear { rebuild() }
            .onChange(of: sourceRequest) { _, request in
                guard visible,let request, cues.contains(where: { $0.id == request.cueID }) else { return }
                reader.browse(); scrollID = unitID(request.cueID)
            }
            .onChange(of: store.transcript?.version) { _, _ in rebuild() }
            .onChange(of: store.transcript?.translations) { _, _ in if visible {updateSearch()} }
            .onChange(of: store.lecture?.readingGrouped) {_,_ in rebuild(); if reader.following,let id = anchorID {scrollID = unitID(id)}}
            .onChange(of: hideSpeakers) {_,_ in updateSearch()}
            .onChange(of: offset) { _, _ in updateActive(playback.position); if visible,reader.following {scrollRequest += 1} }
            .onReceive(playback.$position) { if visible {updateActive($0)} }
            .onChange(of:visible){_,value in if value {updateActive(playback.position);updateSearch();focusRequestedSearch()}}
    }

    private func focusRequestedSearch() {
        guard visible,session.searchRequest != handledSearchRequest else{return}
        handledSearchRequest=session.searchRequest;searchFocused=true;reader.browse()
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
    private func rebuild() { index=ReadingIndex(cues,grouped:store.lecture?.readingGrouped ?? true); timeline = TranscriptTimeline(cues); updateActive(playback.position); updateSearch() }
    private func updateActive(_ position: Double) {
        let next = timeline.active(at: position, mapper: mapper)
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

/// Kept at the video edge even when the right pane is collapsed.
struct ReaderPaneToggle:View {
    @AppStorage("readerPaneVisible") private var visible = true
    @LPState private var hovering = false
    var body:some View {
        Button {visible.toggle()} label: {
            Image(systemName:visible ? "chevron.right":"chevron.left")
                .font(.system(size:14,weight:.semibold)).foregroundStyle(.white)
                .frame(width:26,height:56)
                .background(.black.opacity(hovering ? 0.7:0.4),in:RoundedRectangle(cornerRadius:6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover{hovering=$0}
            .help(visible ? "隐藏转写与章节":"显示转写与章节")
            .accessibilityLabel(visible ? "隐藏转写与章节":"显示转写与章节")
    }
}
