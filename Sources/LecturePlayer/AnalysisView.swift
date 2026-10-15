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
    private var availability:AnalysisAvailability {
        AnalysisAvailability(saved:record.map(SavedAnalysisSummary.init),hasOlder:stale,running:thisRunning,hasTimedSource:!version.isEmpty && store.transcript?.cues.isEmpty == false,readError:lesson.flatMap{job.loadErrors[$0.id]})
    }
    private var unavailable: Bool { availability.reason != nil && (version.isEmpty || store.transcript?.cues.isEmpty != false) }
    private var buttonTitle: String {
        if thisRunning { return job.pauseRequested ? "正在收尾…" : "暂停" }
        if let pending { return pending.status == .failed ? "重试并继续…" : "继续生成…" }
        return record?.completed != nil && !stale ? "重新生成章节…" : "生成章节…"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReadingPaneHeader("章节",pane:.chapters,columns:store.readingColumns,following:session.chapterFollowing,follow:{session.followChapters();followCurrentChapter()}) {chapterActions}
            if let id = lesson?.id, let error = job.loadErrors[id] {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Button("重新读取") { Task { await job.load(store: store, lessonID: id) } }
            }
            if unavailable {
                Text("添加带时间的字幕后可生成章节").font(.callout).foregroundStyle(.secondary)
                Button("添加英文字幕…") { store.replaceSubtitle() }
            } else {
                if thisRunning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(job.status(for:lesson?.id)).font(.caption) }
                } else if let pending {
                    pendingDetails(pending)
                }
                if stale {
                    Label("对应旧字幕，时间跳转已停用。可重新生成当前字幕的章节。", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let document = record?.completed {
                    documentContent(document)
                } else if !thisRunning {
                    Text("未生成章节").font(.callout).foregroundStyle(.secondary)
                    Button(buttonTitle) {confirming=true}.buttonStyle(.borderedProminent)
                        .frame(maxWidth:.infinity)
                } else { Spacer() }
            }
        }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .task(id: "\(lesson?.id.uuidString ?? "")-\(version)-\(visible)") {
            if visible,let id = lesson?.id { await job.load(store: store, lessonID: id); refreshHistoricalSource(); rebuildLookup() }
        }
        .onChange(of: job.revision) { _, _ in refreshHistoricalSource(); rebuildLookup(); expandCurrentOnce() }
        .onAppear {rebuildLookup(); expandCurrentOnce()}
        .onChange(of:visible) {_,value in if value {refreshSearch();updateCurrent(playback.position);expandCurrentOnce();followCurrentChapter()}}
        .onChange(of:chapterQuery){_,value in if !value.isEmpty {session.browseChapters()};refreshSearch()}
        .onChange(of:currentChapterID){_,_ in followCurrentChapter()}
        .onChange(of:session.chapterFollowing){_,following in if following {followCurrentChapter()}}
        .onReceive(playback.clock.$snapshot.map(\.seconds)) {value in if visible {updateCurrent(value)}}
        .onChange(of:lesson?.state.offset) {_,_ in updateCurrent(playback.position)}
        .sheet(isPresented: $confirming) {
            if let id = lesson?.id { AnalysisConfirmation(store: store, job: job, translation: translation, lessonID: id) }
        }
    }
    private func documentContent(_ document:AnalysisDocument)->some View {
        ScrollViewReader {proxy in
            ScrollView {
                // One flat lazy list of topic headers and chapter rows. Each row's ForEach identity is
                // its "topic:"/"chapter:" id, so scrollTo reaches a chapter even before it is built.
                LazyVStack(alignment:.leading,spacing:8) {
                    ForEach(listRows(document)) {row in
                        switch row {
                        case .topic(let topic,let first): topicRow(topic).padding(.top,first ? 0:8)
                        case .chapter(let chapter,let nested): chapterRow(chapter).padding(.leading,nested ? 28:0).padding(.trailing,nested ? 8:0)
                        }
                    }
                    if !chapterQuery.isEmpty && filteredTopics.isEmpty && filteredChapters.isEmpty {Text("无结果").foregroundStyle(.secondary)}
                }.padding(.trailing,8).scrollTargetLayout()
            }.scrollPosition(id:$session.chapterScrollID)
            .background(ScrollIntent(enabled:visible,onManual:{session.browseChapters()}))
            .onChange(of:locateRequest) {_,request in
                guard visible,session.chapterFollowing,let chapter=currentChapterID,!stale else{return}
                if let topic=topicByChapter[chapter] {expandedTopics.insert(topic)}
                Task { @MainActor in
                    await Task.yield()
                    guard visible,session.chapterFollowing,request==locateRequest,chapter==currentChapterID else{return}
                    // The first jump lands on estimated heights for rows not built yet; once they are
                    // built, the second pass corrects the position.
                    proxy.scrollTo("chapter:"+chapter,anchor:UnitPoint(x:0.5,y:0.3))
                    try? await Task.sleep(for:.milliseconds(80))
                    guard visible,session.chapterFollowing,request==locateRequest,chapter==currentChapterID else{return}
                    proxy.scrollTo("chapter:"+chapter,anchor:UnitPoint(x:0.5,y:0.3))
                }
            }
            .task {
                // Same as the transcript: scrolling before the split view sizes this column is a no-op.
                try? await Task.sleep(for:.milliseconds(200))
                guard !Task.isCancelled,visible else{return}
                if session.chapterFollowing {followCurrentChapter()} else if let id=session.chapterScrollID {proxy.scrollTo(id,anchor:.top)}
            }
        }
    }
    private func pendingDetails(_ pending:AnalysisTaskState)->some View {
        VStack(alignment:.leading,spacing:6) {
                    Text(pending.pendingChunks.isEmpty ? "分块分析已保存，最后整理未完成。继续时只处理整理步骤。" : "已保存 \(pending.completedChunks.count)/\(pending.plan.chunks.count) 组分析 · 等待确认继续").font(.caption).foregroundStyle(.secondary)
                    if let message = pending.message, !message.isEmpty {
                        DisclosureGroup("技术详情") {
                            Text(message).font(.caption).textSelection(.enabled)
                            if let attempt=record?.attempts.last {
                                Text("阶段：" + attempt.stage + " · 协议：" + (attempt.protocolVersion.map { String($0) } ?? "未记录")).font(.caption)
                                Text("类别：" + (attempt.validation?.code ?? "未记录") + " · 请求：" + (attempt.requestID ?? "未记录")).font(.caption).textSelection(.enabled)
                                if let diagnostics=attempt.diagnostics {Text("服务状态：" + (diagnostics.status ?? "未知") + " · 输出上限：" + (diagnostics.outputLimit.map { String($0) } ?? "未记录")).font(.caption)}
                            }
                        }
                    }
        }
    }
    private var chapterActions:some View {
        Menu {
            Button("展开全部"){session.browseChapters();expandedTopics=Set(record?.completed?.topics?.map(\.id) ?? [])}
            Button("收起全部"){session.browseChapters();expandedTopics=[]}
            Divider()
            Button(buttonTitle){if thisRunning {job.pause()} else {confirming=true}}
                .disabled(unavailable || (thisRunning ? job.pauseRequested : !translation.acceptsQueuedWork))
            if record?.completed != nil {Button("导出章节…"){store.exportAnalysis()}.disabled(stale)}
        } label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize().help("章节操作").accessibilityLabel("章节操作")
    }
    private func followCurrentChapter() {
        guard visible,session.chapterFollowing,chapterQuery.isEmpty,!stale,let id=currentChapterID else{return}
        if let topic=topicByChapter[id] {expandedTopics.insert(topic)}
        locateRequest += 1
    }
    private func chapterMatches(_ chapter: AnalysisChapter) -> Bool {
        chapterQuery.isEmpty || ([chapter.title] + chapter.points).joined(separator:" ").localizedCaseInsensitiveContains(chapterQuery)
    }
    private func topicMatches(_ topic: AnalysisTopic) -> Bool {
        chapterQuery.isEmpty || (topic.title + " " + topic.overview).localizedCaseInsensitiveContains(chapterQuery) || topic.subtopics.contains(where:chapterMatches)
    }
    private func expandCurrentOnce() {
        guard visible,session.chapterFollowing,let record,let date=record.completedAt,date != openedDocument,let topics=record.completed?.topics else {return}
        openedDocument=date;expandedTopics=[]
        if let topic=topics.first(where:{$0.subtopics.contains(where:isCurrent)}) {expandedTopics.insert(topic.id)}
    }
    private func listRows(_ document:AnalysisDocument)->[ChapterListRow] {
        guard document.topics != nil else {return filteredChapters.map {.chapter($0,nested:false)}}
        var rows:[ChapterListRow]=[]
        for topic in filteredTopics {
            rows.append(.topic(topic,first:rows.isEmpty))
            guard expandedTopics.contains(topic.id) || !chapterQuery.isEmpty else{continue}
            let topicHit=(topic.title + " " + topic.overview).localizedCaseInsensitiveContains(chapterQuery)
            for child in topic.subtopics where chapterQuery.isEmpty || topicHit || chapterMatches(child) {rows.append(.chapter(child,nested:true))}
        }
        return rows
    }
    private func topicRow(_ topic: AnalysisTopic) -> some View {
            HStack(alignment:.top) {
                Button {session.browseChapters();if !expandedTopics.insert(topic.id).inserted {expandedTopics.remove(topic.id)}} label: {
                    Image(systemName:expandedTopics.contains(topic.id) ? "chevron.down" : "chevron.right").frame(width:24,height:28)
                }.buttonStyle(.plain).accessibilityLabel("展开或收起" + topic.title)
                Button {if let first=topic.subtopics.first {seek(first)}} label: {
                    VStack(alignment:.leading,spacing:5) {
                        HStack {Text(topic.title).font(.headline);if currentTopicID==topic.id && !expandedTopics.contains(topic.id) && chapterQuery.isEmpty {ChapterPlaybackBadge(playback:playback)}}
                        if let first=topic.subtopics.first,let last=topic.subtopics.last {Text(topicRange(first,last)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)}
                        Text(topic.overview).font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(stale)
            }.padding(8)
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
            .chapterRowProbe(chapter.id,current:isCurrent(chapter))
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
        let next=stale ? nil : ChapterPositionIndex.readingAnchor(intervals,seconds:seconds-(lesson?.state.offset ?? 0))
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
    @Environment(\.openSettings) private var openSettings
    @LPState private var proposed: AnalysisTaskState?
    @AppStorage("analysisAutomaticModel") private var automatic = false
    @LPState private var model = AnalysisPreferences.load().model
    @LPState private var effort = AnalysisPreferences.load().effort
    @LPState private var message = ""
    @LPState private var resuming = false
    @LPState private var hadCompleted = false
    @LPState private var files=false
    private var config: AnalysisConfig {
        var value=AnalysisConfig(model:model,effort:effort);value.protocolVersion=4
        value.resolvedModels=ResolvedModelPlan.analysis(value,automatic:automatic)
        return value.forStage("analysis")
    }
    private var lesson: Lecture? { store.library.lectures.first { $0.id == lessonID } }
    private var busy: Bool { !translation.acceptsQueuedWork }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(resuming ? "继续生成章节" : hadCompleted ? "重新生成章节" : "生成章节").font(.title2.bold())
            Text(lesson?.displayTitle ?? "课件").foregroundStyle(.secondary)
            Text("根据英文字幕分析，以中文总结并保留英文术语。不会上传视频或音频。")
                .font(.callout)
            if let proposed {
                if resuming {
                    LabeledContent("章节模型", value: TranslationModelCatalog.find(proposed.config.model)?.displayName ?? proposed.config.model)
                    Text("沿用上次确认的模型与字幕范围，已完成的分析不会重新发送。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("自动·均衡", isOn: $automatic)
                    Picker("章节模型", selection: $model) {
                        if TranslationModelCatalog.find(model) == nil { Text(model + "（需检查）").tag(model) }
                        ForEach(TranslationModelCatalog.models) { Text($0.displayName).tag($0.id) }
                    }.disabled(automatic)
                    if TranslationModelCatalog.find(model)?.supportsReasoning == true {
                        Picker("推理强度", selection: $effort) {
                            ForEach(TranslationModelCatalog.find(model)?.supportedEfforts ?? [.none], id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                        }.disabled(automatic)
                    }
                }
                if resuming && (proposed.config.protocolVersion ?? 1) < 4 {
                    Text("继续时复用已完成知识点，只整理章节，不再生成整课总结。").font(.caption).foregroundStyle(.secondary)
                }
                let effective = resuming ? proposed.config : config
                Text(effective.selectionDescription).font(.caption)
                LabeledContent("英文字幕", value: "\(proposed.plan.sourceCueIDs.count) 条")
                LabeledContent("本次请求", value: "\(proposed.pendingChunks.count) 次分组分析 + 1 次主题整理")
                Text(proposed.plan.estimate(config: effective, remainingChunkIDs: Set(proposed.pendingChunks.map(\.id))))
                    .font(.caption).foregroundStyle(.secondary)
                if hadCompleted { Text("新结果完成前，保留现在的章节。").font(.caption) }
                Text("遇到错误即暂停，不自动重试或更换模型。已发送的请求仍可能计费。")
                    .font(.caption).foregroundStyle(.secondary)
                if !keyAvailability.configured(.openAI) {HStack {Text("请在设置中保存 OpenAI Key。").font(.caption);Button("打开设置"){openSettings()}}}
                if busy {Text(translation.testing ? "连接测试正在进行，完成后可生成章节。":"当前任务正在收尾，完成后可继续生成。").font(.caption).foregroundStyle(.orange)}
                if TranslationModelCatalog.find(effective.model)==nil {HStack {Text("当前模型不在支持的模型目录中。").font(.caption);Button("打开设置"){openSettings()}}}
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
                if !message.isEmpty {Button("本课文件…"){files=true}}
                Button("关闭") { dismiss() }
            }
        }.padding(24).frame(width: 570)
            .sheet(isPresented:$files){DataLocations(store:store,lessonID:lessonID)}
            .task {
                do {
                    guard let lesson,let root=store.repository?.root else {throw Failure("资料库不可用")}
                    let chosen=config
                    let work=Task.detached(priority:.userInitiated) {try PerformanceTrace.measure("analysis.confirmation.prepare"){try AnalysisPreparation.load(root:root,lesson:lesson,config:chosen)}}
                    let result=try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                    try Task.checkCancellation()
                    guard store.library.lectures.first(where:{$0.id==lessonID})?.transcriptVersion==result.source.version else {throw Failure("字幕已改变，请重新打开确认窗口。")}
                    hadCompleted=result.existing?.completed != nil
                    proposed=result.task
                    if result.existing?.task != nil {model=result.task.config.model;effort=result.task.config.effort;resuming=true}
                } catch is CancellationError {} catch {message=error.localizedDescription}

            }
    }
    private func confirm() {
        guard var request = proposed, !busy else { return }
        do {
            if !resuming { request.config = config }
            else { request = try request.chaptersOnlyContinuation() }
            var entry=ImportProcessingEntry(id:lessonID,translation:nil,analysis:request)
            entry.purpose="chapters";entry.regenerateAnalysis=hadCompleted && !resuming;entry.analysisReconfirmed=resuming
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
        Section("课程章节") {
            Toggle("自动·均衡", isOn: $automatic)
            if automatic {Text(AnalysisPreferences.load().selectionDescription).font(.caption)}
            Picker("章节模型", selection: $model) {
                if TranslationModelCatalog.find(model) == nil { Text(model + "（需检查）").tag(model) }
                ForEach(TranslationModelCatalog.models) { Text($0.displayName).tag($0.id) }
            }.disabled(automatic)
            if TranslationModelCatalog.find(model)?.supportsReasoning == true {
                Picker("总结推理强度", selection: $effort) {
                    ForEach(TranslationModelCatalog.find(model)?.supportedEfforts ?? [.none], id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }.disabled(automatic)
            }
            Text("使用 OpenAI Key").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("生成设置说明") {
                Text("确认生成时使用以上配置；已确认任务保留原配置。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension AppStore {
    func exportAnalysis() {
        guard let lesson = lecture, let transcript, let root = repository?.root else { return }
        Task { @MainActor in
            do {
                guard let record = try await AnalysisRepository(root: root).load(lessonID: lesson.id, sourceVersion: transcript.version) else {
                    throw Failure("当前字幕还没有已完成的课程章节。")
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

private enum ChapterListRow:Identifiable {
    case topic(AnalysisTopic,first:Bool)
    case chapter(AnalysisChapter,nested:Bool)
    var id:String {
        switch self {
        case .topic(let topic,_): "topic:"+topic.id
        case .chapter(let chapter,_): "chapter:"+chapter.id
        }
    }
}

#if DEBUG
/// Test-only: where the highlighted chapter row sits, in window coordinates (top-left origin).
@MainActor enum ChapterRowProbe {
    static var current:(id:String,frame:CGRect)? {entry.map {($0.id,$0.frame)}}
    fileprivate static var entry:(id:String,token:UUID,frame:CGRect)?
}
private struct ChapterRowProbeView:View {
    let id:String
    let active:Bool
    @LPState private var token=UUID()
    var body:some View {
        GeometryReader {proxy in
            let frame=proxy.frame(in:.global)
            Color.clear
                .onAppear {if active {ChapterRowProbe.entry=(id,token,frame)}}
                .onChange(of:frame) {_,value in if active {ChapterRowProbe.entry=(id,token,value)}}
                .onChange(of:active) {_,value in if value {ChapterRowProbe.entry=(id,token,frame)}}
                // A rebuilt row appears before the old one disappears; only the owner may clear.
                .onDisappear {if ChapterRowProbe.entry?.token==token {ChapterRowProbe.entry=nil}}
        }
    }
}
#endif
extension View {
    func chapterRowProbe(_ id:String,current:Bool)->some View {
        #if DEBUG
        background(ChapterRowProbeView(id:id,active:current))
        #else
        self
        #endif
    }
}
