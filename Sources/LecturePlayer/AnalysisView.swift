import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Core

struct AnalysisPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var job: AnalysisJob
    @ObservedObject var translation: TranslationJob
    let playback: Playback
    var visible: Bool = true
    var onViewSource: (String) -> Void
    @LPState private var confirming = false
    @ObservedObject private var session:ReaderSession
    init(store:AppStore,job:AnalysisJob,translation:TranslationJob,playback:Playback,visible:Bool=true,onViewSource:@escaping(String)->Void){self.store=store;self.job=job;self.translation=translation;self.playback=playback;self.visible=visible;self.onViewSource=onViewSource;session=store.readerPresentation.session(store.current ?? UUID())}
    private var expandedTopics:Set<String> {get{session.expandedTopics} nonmutating set{session.expandedTopics=newValue}}
    private var openedDocument:Date? {get{session.openedDocument} nonmutating set{session.openedDocument=newValue}}
    private var chapterQuery:String {session.chapterQuery}
    @LPState private var historicalSource: Transcript?
    @LPState private var cueLookup: [String:Cue] = [:]
    @LPState private var currentChapterID: String?
    @LPState private var topicByChapter:[String:String]=[:]
    @LPState private var locateRequest=0
    private var currentTopicID:String? {currentChapterID.flatMap{topicByChapter[$0]}}
    @LPState private var filteredTopics:[AnalysisTopic]=[]
    @LPState private var filteredChapters:[AnalysisChapter]=[]
    @LPState private var intervals:[ChapterPositionIndex.Entry]=[]
    @LPState private var historicalVersion:String?
    private var lesson: Lecture? { store.lecture }
    private var version: String { store.transcript?.version ?? "" }
    private var record: LessonAnalysis? { lesson.flatMap { job.visible($0.id, version: version) } }
    private var pending: AnalysisTaskState? { lesson.flatMap { job.exact($0.id, version: version)?.task } }
    private var stale: Bool { record.map { $0.sourceVersion != version } ?? false }
    private var source: Transcript? { stale ? historicalSource : store.transcript }
    private var mapper: SubtitleTimingMapper { lesson?.state.timingMapper ?? SubtitleTimingMapper() }
    private var thisRunning: Bool { job.isRunning(lesson?.id) }
    private var unavailable: Bool { version.isEmpty || store.transcript?.cues.isEmpty != false }
    private var buttonTitle: String {
        if thisRunning { return job.pauseRequested ? "正在收尾…" : "暂停" }
        if let pending { return pending.status == .failed ? "重试并继续…" : "继续生成…" }
        return record?.completed != nil && !stale ? (record?.completed?.topics == nil ? "生成细化目录…" : "重新生成…") : "生成总结与章节…"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("搜索主题、知识点或英文术语", text: $session.chapterQuery)
                .textFieldStyle(.roundedBorder).accessibilityLabel("搜索课程章节")
            ViewThatFits(in:.horizontal) {
                chapterToolbar(expandedControls:true)
                chapterToolbar(expandedControls:false)
            }
            if let id = lesson?.id, let error = job.loadErrors[id] {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Button("重新读取") { Task { await job.load(store: store, lessonID: id) } }
            }
            if unavailable {
                ContentUnavailableView("需要带时间的英文字幕", systemImage: "text.bubble", description: Text("添加 VTT 或 SRT 后，可生成总结与章节。无时间戳 TXT 无法定位讲解片段。"))
                Button("添加英文字幕…") { store.replaceSubtitle() }
            } else {
                if thisRunning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(job.status(for:lesson?.id)).font(.caption) }
                } else if let pending {
                    Text(pending.pendingChunks.isEmpty ? "分块分析已保存，最后整理未完成。继续时只处理整理步骤。" : "已保存 \(pending.completedChunks.count)/\(pending.plan.chunks.count) 组分析 · 等待确认继续").font(.caption).foregroundStyle(.secondary)
                    if let message = pending.message, !message.isEmpty {
                        DisclosureGroup("技术详情") {
                            Text(message).font(.caption).textSelection(.enabled)
                            if let attempt=record?.attempts.last {
                                Text("阶段：" + attempt.stage + " · 协议：" + (attempt.protocolVersion.map(String.init) ?? "未记录")).font(.caption)
                                Text("类别：" + (attempt.validation?.code ?? "未记录") + " · 请求：" + (attempt.requestID ?? "未记录")).font(.caption).textSelection(.enabled)
                                if let diagnostics=attempt.diagnostics {Text("服务状态：" + (diagnostics.status ?? "未知") + " · 输出上限：" + (diagnostics.outputLimit.map(String.init) ?? "未记录")).font(.caption)}
                            }
                        }
                    }
                }
                if stale {
                    Label("对应旧字幕，时间跳转已停用。可重新生成当前字幕的总结。", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let document = record?.completed {
                    ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            DisclosureGroup("整课总结", isExpanded: $session.overviewExpanded) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(document.overview.enumerated()), id: \.offset) { _, point in
                                        Button {
                                            if let chapter = document.chapters.first(where: { $0.id == point.chapterID }) { seek(chapter) }
                                        } label: {
                                            HStack(alignment: .top, spacing: 8) {
                                                Image(systemName: "smallcircle.filled.circle").font(.caption2).padding(.top, 4)
                                                Text(point.text).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                                            }.contentShape(Rectangle())
                                        }.buttonStyle(.plain).disabled(stale).help("跳到相关章节")
                                    }
                                }.padding(.top, 10)
                            }.font(.body)
                            Divider()
                            if document.topics != nil {
                                ForEach(filteredTopics) { topic in topicRow(topic) }
                            } else {
                                Text("旧版目录；生成细化目录后可定位到知识点。").font(.caption).foregroundStyle(.secondary)
                                ForEach(filteredChapters, id: \.id) {chapter in chapterRow(chapter)}
                            }
                            if let record {
                                Divider()
                                Button("导出总结与章节…") { store.exportAnalysis() }.disabled(stale)
                                Text("根据英文字幕生成，可能遗漏图表信息，请结合原文核对。")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let date = record.completedAt {
                                    Text("\(record.completedConfig?.model ?? "OpenAI") · \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.trailing, 8)
                    }.onChange(of:locateRequest) {_,_ in
                        guard let chapter=currentChapterID,!stale else{return}
                        session.chapterQuery=""
                        if let topic=topicByChapter[chapter] {expandedTopics.insert(topic)}
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo("chapter:"+chapter,anchor:.center)
                        }
                    }
                    }
                } else if !thisRunning {
                    ContentUnavailableView("按主题回顾这堂课", systemImage: "list.bullet.rectangle", description: Text("根据英文字幕整理中文总结与主题章节，保留英文术语。点击章节即可跳到讲解起点。"))
                } else { Spacer() }
            }
        }.padding(12)
        .task(id: "\(lesson?.id.uuidString ?? "")-\(version)") {
            if let id = lesson?.id { await job.load(store: store, lessonID: id); refreshHistoricalSource(); rebuildLookup() }
        }
        .onChange(of: job.revision) { _, _ in refreshHistoricalSource(); rebuildLookup(); expandCurrentOnce() }
        .onAppear {rebuildLookup(); expandCurrentOnce()}
        .onChange(of:visible) {_,value in if value {refreshSearch();updateCurrent(playback.position);expandCurrentOnce()}}
        .onChange(of:chapterQuery){_,_ in refreshSearch()}
        .onReceive(playback.clock.$snapshot.map(\.seconds)) {value in if visible {updateCurrent(value)}}
        .onChange(of:lesson?.state.offset) {_,_ in updateCurrent(playback.position)}
        .sheet(isPresented: $confirming) {
            if let id = lesson?.id { AnalysisConfirmation(store: store, job: job, translation: translation, lessonID: id) }
        }
    }
    private func chapterToolbar(expandedControls:Bool) -> some View {
        HStack(spacing:8) {
            Text("课程章节").font(.headline).fixedSize()
            Button("定位当前"){locateRequest += 1}
                .disabled(currentChapterID==nil || stale).help("清除搜索并定位当前知识点，保留播放状态")
            Spacer(minLength:0)
            if expandedControls,record?.completed?.topics != nil {
                Button("展开全部"){expandedTopics=Set(record?.completed?.topics?.map(\.id) ?? [])}
                Button("收起全部"){expandedTopics=[]}
            }
            Menu {
                if !expandedControls,record?.completed?.topics != nil {
                    Button("展开全部"){expandedTopics=Set(record?.completed?.topics?.map(\.id) ?? [])}
                    Button("收起全部"){expandedTopics=[]}
                    Divider()
                }
                Button(buttonTitle) {if thisRunning {job.pause()} else {confirming=true}}
                    .disabled(unavailable || (thisRunning ? job.pauseRequested : !translation.acceptsQueuedWork))
            } label: {Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize()
                .help("章节操作").accessibilityLabel("章节操作")
        }.controlSize(.small)
    }
    private func chapterMatches(_ chapter: AnalysisChapter) -> Bool {
        chapterQuery.isEmpty || ([chapter.title] + chapter.points).joined(separator:" ").localizedCaseInsensitiveContains(chapterQuery)
    }
    private func topicMatches(_ topic: AnalysisTopic) -> Bool {
        chapterQuery.isEmpty || (topic.title + " " + topic.overview).localizedCaseInsensitiveContains(chapterQuery) || topic.subtopics.contains(where:chapterMatches)
    }
    private func expandCurrentOnce() {
        guard visible,let record,let date=record.completedAt,date != openedDocument,let topics=record.completed?.topics else {return}
        openedDocument=date;expandedTopics=[]
        if let topic=topics.first(where:{$0.subtopics.contains(where:isCurrent)}) {expandedTopics.insert(topic.id)}
    }
    private func topicRow(_ topic: AnalysisTopic) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.top) {
                Button {if !expandedTopics.insert(topic.id).inserted {expandedTopics.remove(topic.id)}} label: {
                    Image(systemName:expandedTopics.contains(topic.id) ? "chevron.down" : "chevron.right").frame(width:24,height:28)
                }.buttonStyle(.plain).accessibilityLabel("展开或收起" + topic.title)
                Button {if let first=topic.subtopics.first {seek(first)}} label: {
                    VStack(alignment:.leading,spacing:5) {
                        HStack {Text(topic.title).font(.headline);if currentTopicID==topic.id && !expandedTopics.contains(topic.id) && chapterQuery.isEmpty {ChapterPlaybackBadge(playback:playback)}}
                        if let first=topic.subtopics.first,let last=topic.subtopics.last {Text(topicRange(first,last)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)}
                        Text(topic.overview).font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(stale)
            }
            if expandedTopics.contains(topic.id) || !chapterQuery.isEmpty {
                ForEach(topic.subtopics.filter {chapterQuery.isEmpty || (topic.title + " " + topic.overview).localizedCaseInsensitiveContains(chapterQuery) || chapterMatches($0)}) {child in
                    chapterRow(child).padding(.leading,20)
                }
            }
        }.padding(8)

            .id("topic:"+topic.id)
            .accessibilityValue(currentTopicID==topic.id ? "当前主题":"")
    }
    private func topicRange(_ first:AnalysisChapter,_ last:AnalysisChapter) -> String {
        guard let (start,_)=cueRange(first),let (_,end)=cueRange(last) else {return ""}
        return timeLabel(mapper.seekTarget(start)) + "–" + timeLabel(max(0,mapper.effectiveTime(milliseconds:end.end)))
    }
    private func chapterRow(_ chapter: AnalysisChapter) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { seek(chapter) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(rangeLabel(chapter)).font(.caption.monospacedDigit()).foregroundStyle(isCurrent(chapter) ? Color.accentColor : Color.secondary)
                    HStack {Text(chapter.title).font(.headline);if isCurrent(chapter) {ChapterPlaybackBadge(playback:playback)}}
                    ForEach(Array(chapter.points.enumerated()), id: \.offset) { _, point in
                        Text("• " + point).font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(stale)
            if !chapterQuery.isEmpty {Label("搜索匹配",systemImage:"magnifyingglass").font(.caption2).foregroundStyle(.secondary)}
            Button("查看对应原文") { onViewSource(chapter.startCueID) }
                .buttonStyle(.borderless).font(.caption).disabled(stale)
        }.padding(12)
            .background(isCurrent(chapter) ? Color.primary.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment:.leading) {if isCurrent(chapter) {RoundedRectangle(cornerRadius:2).fill(Color.accentColor).frame(width:3).padding(.vertical,8)}}
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(rangeLabel(chapter))，\(chapter.title)")
            .accessibilityValue(isCurrent(chapter) ? "当前知识点":"")
            .id("chapter:"+chapter.id)
    }
    private func cueRange(_ chapter: AnalysisChapter) -> (Cue, Cue)? {
        guard let first = cueLookup[chapter.startCueID],
              let last = cueLookup[chapter.endCueID] else { return nil }
        return (first, last)
    }
    private func rangeLabel(_ chapter: AnalysisChapter) -> String {
        guard let (first, last) = cueRange(chapter) else { return "原字幕时间暂不可用" }
        return "\(timeLabel(mapper.seekTarget(first)))–\(timeLabel(max(0, mapper.effectiveTime(milliseconds: last.end))))"
    }
    private func isCurrent(_ chapter: AnalysisChapter) -> Bool { !stale && currentChapterID == chapter.id }
    private func rebuildLookup() {
        cueLookup=Dictionary((source?.cues ?? []).map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        intervals=(record?.completed?.chapters ?? []).compactMap {chapter in
            guard let (first,last)=cueRange(chapter) else{return nil}
            return ChapterPositionIndex.Entry(id:chapter.id,start:Double(first.start)/1000,end:Double(last.end)/1000)
        }.sorted{$0.start<$1.start}
        topicByChapter=ChapterActivity.parents(record?.completed?.topics ?? [])
        refreshSearch();updateCurrent(playback.position)
    }
    private func refreshSearch(){filteredTopics=record?.completed?.topics?.filter(topicMatches) ?? [];filteredChapters=record?.completed?.chapters.filter(chapterMatches) ?? []}
    private func updateCurrent(_ seconds:Double) {
        let next=stale ? nil : ChapterPositionIndex.current(intervals,seconds:seconds-(lesson?.state.offset ?? 0))
        if next != currentChapterID {currentChapterID=next}
    }
    private func seek(_ chapter: AnalysisChapter) {
        guard !stale, let (first, _) = cueRange(chapter) else { return }
        playback.seek(mapper.seekTarget(first))
    }
    private func refreshHistoricalSource() {
        guard stale, let record, var old = lesson else {historicalSource=nil;historicalVersion=nil;return}
        guard historicalVersion != record.sourceVersion else{return}
        historicalVersion=record.sourceVersion
        old.transcriptVersion = record.sourceVersion
        historicalSource = try? store.repository?.read(old)
    }
}

struct AnalysisConfirmation: View {
    @ObservedObject private var keyAvailability=KeychainAvailability.shared
    @ObservedObject var store: AppStore
    @ObservedObject var job: AnalysisJob
    @ObservedObject var translation: TranslationJob
    let lessonID: UUID
    @Environment(\.dismiss) private var dismiss
    @LPState private var proposed: AnalysisTaskState?
    @AppStorage("analysisAutomaticModel") private var automatic = false
    @LPState private var model = AnalysisPreferences.load().model
    @LPState private var effort = AnalysisPreferences.load().effort
    @LPState private var message = ""
    @LPState private var resuming = false
    @LPState private var hadCompleted = false
    @LPState private var compactContinuation = false
    private var config: AnalysisConfig {
        var value=AnalysisConfig(model:model,effort:effort);value.protocolVersion=3
        value.resolvedModels=ResolvedModelPlan.analysis(value,automatic:automatic)
        return value.forStage("analysis")
    }
    private var lesson: Lecture? { store.library.lectures.first { $0.id == lessonID } }
    private var busy: Bool { !translation.acceptsQueuedWork }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(resuming ? "继续生成总结与章节" : hadCompleted ? "重新生成总结与章节" : "生成总结与章节").font(.title2.bold())
            Text(lesson?.displayTitle ?? "课件").foregroundStyle(.secondary)
            Text("根据英文字幕分析，以中文总结并保留英文术语。不会上传视频或音频。")
                .font(.callout)
            if let proposed {
                if resuming {
                    LabeledContent("总结模型", value: TranslationModelCatalog.find(proposed.config.model)?.displayName ?? proposed.config.model)
                    Text("沿用上次确认的模型与字幕范围，已完成的分析不会重新发送。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("自动·均衡", isOn: $automatic)
                    Picker("总结模型", selection: $model) {
                        if TranslationModelCatalog.find(model) == nil { Text(model + "（需检查）").tag(model) }
                        ForEach(TranslationModelCatalog.models) { Text($0.displayName).tag($0.id) }
                    }.disabled(automatic)
                    if TranslationModelCatalog.find(model)?.supportsReasoning == true {
                        Picker("推理强度", selection: $effort) {
                            ForEach(TranslationModelCatalog.find(model)?.supportedEfforts ?? [.none], id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                        }.disabled(automatic)
                    }
                }
                if resuming && (proposed.config.protocolVersion ?? 1) < 3 {
                    Toggle("使用精简方式继续…",isOn:$compactContinuation)
                    Text("复用已完成分块，仅精简最后整理的返回内容；模型、推理程度与输出上限保持原配置。点击确认后生效。").font(.caption).foregroundStyle(.secondary)
                }
                let effective = resuming ? proposed.config : config
                Text(effective.selectionDescription).font(.caption)
                LabeledContent("英文字幕", value: "\(proposed.plan.sourceCueIDs.count) 条")
                LabeledContent("本次请求", value: "\(proposed.pendingChunks.count) 次分组分析 + 1 次主题整理")
                Text(proposed.plan.estimate(config: effective, remainingChunkIDs: Set(proposed.pendingChunks.map(\.id))))
                    .font(.caption).foregroundStyle(.secondary)
                if hadCompleted { Text("新结果完成前，保留现在的总结与章节。").font(.caption) }
                Text("遇到错误即暂停，不自动重试或更换模型。已发送的请求仍可能计费。")
                    .font(.caption).foregroundStyle(.secondary)
                if !keyAvailability.configured(.openAI) { Text("请先在设置中保存 OpenAI Key。").font(.caption).foregroundStyle(.orange) }
                if busy { Text("请等待正在进行的翻译、总结或连接测试结束。").font(.caption).foregroundStyle(.orange) }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(resuming ? "确认并继续" : "确认生成") { confirm() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(busy || !keyAvailability.configured(.openAI) || TranslationModelCatalog.find(effective.model) == nil)
                }
            } else {
                Text(message.isEmpty ? "正在读取英文字幕…" : message).font(.callout)
                Button("关闭") { dismiss() }
            }
        }.padding(24).frame(width: 570)
            .task {
                await job.load(store: store, lessonID: lessonID)
                do {
                    if let error = job.loadErrors[lessonID] { throw Failure(error) }
                    guard let lesson, let source = try store.repository?.read(lesson) else { throw Failure("没有英文字幕。") }
                    let existing = job.exact(lessonID, version: source.version)
                    hadCompleted = existing?.completed != nil
                    if let saved = existing?.task {
                        proposed = saved; model = saved.config.model; effort = saved.config.effort; resuming = true
                    } else {
                        proposed = AnalysisTaskState(config: config, plan: try AnalysisPlan.make(source))
                    }
                } catch { message = error.localizedDescription }
            }
    }
    private func confirm() {
        guard var request = proposed, !busy else { return }
        do {
            if !resuming { request.config = config }
            else if compactContinuation { request = try request.compactContinuation() }
            var entry=ImportProcessingEntry(id:lessonID,translation:nil,analysis:request)
            entry.purpose="chapters";entry.regenerateAnalysis=hadCompleted && !resuming;entry.analysisReconfirmed=compactContinuation && resuming
            try store.processing.launch([entry],store:store)
            if !resuming { AnalysisPreferences.save(request.config) }
            dismiss()
        } catch { message = error.localizedDescription }
    }
}


struct AnalysisModelSettings: View {
    @AppStorage("analysisAutomaticModel") private var automatic = false
    @AppStorage("analysisModel") private var model = UserDefaults.standard.string(forKey: "model") ?? TranslationModelCatalog.defaultID
    @AppStorage("analysisEffort") private var effort = UserDefaults.standard.string(forKey: "effort") ?? "none"
    var body: some View {
        Section("课程总结") {
            Toggle("自动·均衡", isOn: $automatic)
            if automatic {Text(AnalysisPreferences.load().selectionDescription).font(.caption)}
            Picker("总结模型", selection: $model) {
                if TranslationModelCatalog.find(model) == nil { Text(model + "（需检查）").tag(model) }
                ForEach(TranslationModelCatalog.models) { Text($0.displayName).tag($0.id) }
            }.disabled(automatic)
            if TranslationModelCatalog.find(model)?.supportsReasoning == true {
                Picker("总结推理强度", selection: $effort) {
                    ForEach(TranslationModelCatalog.find(model)?.supportedEfforts ?? [.none], id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }.disabled(automatic)
            }
            Text("使用已保存的 OpenAI Key。只在导入预览或章节页确认后生成；此设置不改变已确认任务，也不影响字幕翻译。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension AppStore {
    func exportAnalysis() {
        guard let lesson = lecture, let transcript, let root = repository?.root else { return }
        Task { @MainActor in
            do {
                guard let record = try await AnalysisRepository(root: root).load(lessonID: lesson.id, sourceVersion: transcript.version) else {
                    throw Failure("当前字幕还没有已完成的课程总结。")
                }
                let text = try AnalysisMarkdown.export(record, transcript: transcript, offset: lesson.state.subtitleOffsetSeconds, title: lesson.displayTitle)
                let panel = NSSavePanel(); panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
                panel.nameFieldStringValue = lesson.displayTitle + ".chapters.md"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Only the small visible badge observes play/pause; chapter rows do not observe the clock.
private struct ChapterPlaybackBadge:View {
    let playback:Playback
    @LPState private var playing=false
    var body:some View {
        Label(playing ? "正在播放":"当前位置",systemImage:playing ? "play.fill":"location.fill")
            .font(.caption2).foregroundStyle(Color.accentColor).fixedSize()
            .onReceive(playback.$playing.removeDuplicates()){playing=$0}
    }
}
