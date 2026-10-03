import SwiftUI
import Core

struct VideoCaptionControls: View {
    @ObservedObject var store: AppStore
    @ObservedObject var presentation: CaptionPresentation
    @LPState private var settings = false
    @AppStorage("hideSpeakerLabels") private var hideSpeakers = true
    private var value: VideoCaptionPreferences { presentation.value }
    var body: some View {
        HStack(spacing: 2) {
            Button { update { $0.enabled.toggle() } } label: {
                Image(systemName: value.enabled ? "captions.bubble.fill" : "captions.bubble")
                    .foregroundStyle(value.enabled ? Color.accentColor : Color.primary)
            }.help(value.enabled ? "隐藏视频字幕" : "显示视频字幕")
                .accessibilityLabel(value.enabled ? "隐藏视频字幕" : "显示视频字幕")
            Button { settings.toggle() } label: {Image(systemName: "chevron.down").font(.caption2)}
                .help("视频字幕设置").accessibilityLabel("视频字幕设置")
                .popover(isPresented: $settings) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("视频字幕").font(.headline)
                        Text("设置会应用到所有视频，并在下次打开时保留。").font(.caption).foregroundStyle(.secondary)
                        Picker("语言", selection: Binding(get: {value.mode}, set: {mode in update {$0.mode = mode}})) {
                            ForEach(["双语", "英文", "中文"], id: \.self) {Text($0)}
                        }.pickerStyle(.segmented)
                        HStack {Text("字号"); Slider(value: Binding(get: {value.fontSize}, set: {size in update {$0.fontSize = size}}), in: 16...36,onEditingChanged:{presentation.setEditing($0)});Text(Int(value.fontSize).description).monospacedDigit()}
                        Toggle("按句显示", isOn: Binding(get: {value.grouped ?? true}, set: {v in update {$0.grouped = v}}))
                        Toggle("隐藏自动说话人编号", isOn: $hideSpeakers)
                        Picker("位置", selection: Binding(get: {value.position ?? "bottom"}, set: {v in update {$0.position = v}})) {
                            Text("顶部").tag("top"); Text("居中").tag("center"); Text("底部").tag("bottom")
                        }
                        if value.position != "center" {
                            HStack { Text("边距"); Slider(value: Binding(get: {value.margin ?? 0.02}, set: {v in update {$0.margin = v}}), in: 0...0.15,onEditingChanged:{presentation.setEditing($0)}) }
                        }
                        HStack { Text("背景透明度"); Slider(value: Binding(get: {value.transparency ?? 0.22}, set: {v in update {$0.transparency = v}}), in: 0...1,onEditingChanged:{presentation.setEditing($0)}); Text("\(Int((value.transparency ?? 0.22)*100))%") }
                        Button("恢复默认外观") {update {$0.position = nil; $0.margin = nil; $0.transparency = nil; $0.fontSize = 22}}
                        Text("中文使用右侧选择的译文来源；缺少中文时显示英文。").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).frame(width: 310).onDisappear {presentation.setEditing(false)}
                }
        }.disabled(store.transcript?.cues.isEmpty != false)
    }
    private func update(_ change: (inout VideoCaptionPreferences) -> Void) {
        presentation.update(change)
    }
}

struct VideoCaptionOverlay: View {
    @ObservedObject var store: AppStore
    let playback: Playback
    @ObservedObject var presentation: CaptionPresentation
    @LPState private var index = ReadingIndex()
    @AppStorage("hideSpeakerLabels") private var hideSpeakers = true
    @LPState private var timeline = TranscriptTimeline([])
    @LPState private var activeIDs: [String] = []
    @LPState private var notified = Set<String>()
    @LPState private var showHint = false
    private var preferences: VideoCaptionPreferences {presentation.value}
    private var mapper: SubtitleTimingMapper {store.lecture?.state.timingMapper ?? SubtitleTimingMapper()}
    var body: some View {
        GeometryReader { geometry in
            if preferences.enabled {
                VStack(spacing: 6) {
                    if preferences.position != "top" { Spacer(minLength: 0) }
                    if showHint {Text("部分中文字幕尚未生成").font(.caption).padding(6).background(.black.opacity(0.8), in: Capsule())}
                    let units = index.activeUnits(activeIDs)
                    let lines = units.map { unit in
                        captionText(unit)
                    }
                    if !lines.isEmpty {
                        VStack(spacing: 5) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line) }
                        }.font(.system(size: min(preferences.fontSize, max(16, geometry.size.width / 28))))
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(1-min(1,max(0,preferences.transparency ?? 0.22))), in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: min(1050, geometry.size.width * 0.92))
                    }
                    if preferences.position == "top" || preferences.position == "center" { Spacer(minLength: 0) }
                }.foregroundStyle(.white).shadow(color: .black, radius: 1, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, geometry.size.height * min(0.15,max(0,preferences.margin ?? 0.02)))
            }
        }.allowsHitTesting(false)
            .onAppear { rebuild(); notifyIfNeeded() }
            .onChange(of: preferences.grouped) {_,_ in rebuild()}
            .onChange(of: store.transcript?.version) {_,_ in rebuild()}
            .onChange(of: store.lecture?.state.offset) {_,_ in update(playback.position)}
            .onChange(of: preferences.enabled) {_,_ in notifyIfNeeded()}
            .onChange(of: preferences.mode) {_,_ in notifyIfNeeded()}
            .onChange(of: store.transcript?.variantID) {_,_ in notifyIfNeeded()}
            .onReceive(playback.$position) {update($0)}
            .task(id: showHint) {if showHint {try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled {showHint = false}}}
    }
    private func captionText(_ unit: TranscriptReadingUnit) -> String {
        let translations=store.transcript?.translations ?? [:]
        let english=unit.content(translations:[:],mode:"英文",hideSpeakers:hideSpeakers).text
        let chinese=unit.cues.compactMap {cue in translations[cue.id].map{SpeakerLabel.cleanTranslation($0.text,source:cue.en,hide:hideSpeakers)}}.joined(separator:" ")
        if preferences.mode == "英文" {return english}
        if preferences.mode == "中文",unit.cues.allSatisfy({translations[$0.id] != nil}) {return chinese}
        return chinese.isEmpty ? english : english + "\n" + chinese
    }
    private func rebuild() {index=ReadingIndex(store.transcript?.cues ?? [],grouped:preferences.grouped ?? true,video:true);timeline = TranscriptTimeline(store.transcript?.cues ?? []); update(playback.position)}
    private func update(_ seconds: Double) {let next = timeline.active(at: seconds, mapper: mapper); if next != activeIDs {activeIDs = next}}
    private func notifyIfNeeded() {
        guard preferences.enabled, preferences.mode != "英文", let t = store.transcript, t.translatedCount < t.cues.count else {showHint = false; return}
        let key = t.version + t.variantID
        if notified.insert(key).inserted {showHint = true}
    }
}
