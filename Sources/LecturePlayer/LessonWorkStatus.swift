import SwiftUI
import Core

/// Shared, compact snapshots. Body evaluation only looks up these values; disk reads run separately.
@MainActor final class LessonStatusPresentation: ObservableObject {
    @Published private(set) var translations: [UUID:SavedTranslationSummary]=[:]
    @Published private(set) var translationErrors: [UUID:String]=[:]
    @Published private(set) var analyses: [String:SavedAnalysisSummary]=[:]
    @Published private(set) var analysisError: String?
    private var tokens: [UUID:UUID]=[:]
    private var analysisLoad: Task<Void,Never>?
    private var loadedAnalysisRoot: URL?
    private var generation=UUID()
    var analysisLoaded:Bool {loadedAnalysisRoot != nil}

    func reset() {
        generation=UUID(); tokens.removeAll(); translations.removeAll(); translationErrors.removeAll()
        analysisLoad?.cancel(); analysisLoad=nil; loadedAnalysisRoot=nil; analyses.removeAll(); analysisError=nil
    }
    func accept(_ source:Transcript,for id:UUID) {
        tokens[id]=nil
        let summary=SavedTranslationSummary(source)
        if translations[id] != summary {translations[id]=summary}
        translationErrors[id]=nil
    }
    func prepare(_ lesson:Lecture,repository:Repository?) async {
        guard let repository else{return}
        prepareAnalyses(root:repository.root)
        guard let version=lesson.transcriptVersion else{return}
        guard translations[lesson.id]?.version != version, tokens[lesson.id]==nil else{return}
        let token=UUID(); tokens[lesson.id]=token
        do {
            let url=try repository.transcriptURL(lesson.id,version)
            let work=Task.detached(priority:.utility) { () throws -> SavedTranslationSummary in
                let source=try Codec.decode(Transcript.self,Data(contentsOf:url)); try source.validate()
                guard source.version==version else{throw Failure("字幕版本已变化")}
                return SavedTranslationSummary(source)
            }
            let summary=try await work.value
            guard tokens[lesson.id]==token else{return}
            tokens[lesson.id]=nil; translations[lesson.id]=summary; translationErrors[lesson.id]=nil
        } catch {
            guard tokens[lesson.id]==token else{return}
            tokens[lesson.id]=nil; translationErrors[lesson.id]=error.localizedDescription
        }
    }
    private func prepareAnalyses(root:URL) {
        guard loadedAnalysisRoot != root, analysisLoad==nil else{return}
        let current=generation
        analysisLoad=Task { [weak self] in
            do {
                // One background pass per library, rather than decoding all analyses once per row.
                let values=try await AnalysisRepository(root:root).all()
                guard let self,self.generation==current,!Task.isCancelled else{return}
                self.analyses=Dictionary(uniqueKeysWithValues:values.map { (AnalysisJob.key($0.lessonID,$0.sourceVersion),SavedAnalysisSummary($0)) })
                self.analysisError=nil;self.loadedAnalysisRoot=root;self.analysisLoad=nil
            } catch {
                guard let self,self.generation==current,!Task.isCancelled else{return}
                self.analysisError=error.localizedDescription;self.loadedAnalysisRoot=root;self.analysisLoad=nil
            }
        }
    }
    func analysis(_ lesson:Lecture,job:AnalysisJob)->SavedAnalysisSummary? {
        guard let version=lesson.transcriptVersion else{return nil}
        if let record=job.exact(lesson.id,version:version) {return SavedAnalysisSummary(record)}
        return analyses[AnalysisJob.key(lesson.id,version)]
    }
    func analysisIssue(_ lesson:Lecture,job:AnalysisJob)->String? {
        job.loadErrors[lesson.id] ?? analysisError
    }
    func savedAnalysisLabel(_ lesson:Lecture,job:AnalysisJob)->String {
        // A valid older snapshot remains usable, but must not hide a failed refresh.
        if analysisIssue(lesson,job:job) != nil {return "总结状态不可用"}
        if let summary=analysis(lesson,job:job) {return summary.label}
        if hasOlderAnalysis(lesson,job:job) {return "总结待更新"}
        return analysisLoaded && (translations[lesson.id]?.total ?? 0)>0 ? "总结待处理" : ""
    }
    func hasOlderAnalysis(_ lesson:Lecture,job:AnalysisJob)->Bool {
        analyses.values.contains {$0.lessonID==lesson.id && $0.version != lesson.transcriptVersion && $0.complete}
        || job.records.values.contains {$0.lessonID==lesson.id && $0.sourceVersion != lesson.transcriptVersion && $0.completed != nil}
    }
}

struct LessonWorkStatus:View {
    let store:AppStore;let lesson:Lecture
    @ObservedObject private var snapshot:LessonStatusPresentation
    @ObservedObject private var translation:TranslationJob
    @ObservedObject private var analysis:AnalysisJob
    @ObservedObject private var processing:ImportProcessingCoordinator
    @LPState private var translationConfirmation=false
    @LPState private var analysisConfirmation=false
    @LPState private var showingDetails=false
    init(store:AppStore,lesson:Lecture) {
        self.store=store;self.lesson=lesson;snapshot=store.lessonStatuses;translation=store.translation
        analysis=store.analysis;processing=store.processing
    }
    private var record:TranslationTaskState? {
        guard let value=translation.states[lesson.id],value.version==lesson.transcriptVersion else{return nil};return value
    }
    private var entry:ImportProcessingEntry? {processing.entries.first {$0.id==lesson.id}}
    private var translationRunning:Bool {translation.isRunning(lesson.id)}
    private var analysisRunning:Bool {analysis.isRunning(lesson.id)}
    private var pendingQueue:Bool {entry.map {$0.status != "完成"} ?? false}
    private var saved:SavedTranslationSummary? {
        guard let value=snapshot.translations[lesson.id],value.version==lesson.transcriptVersion else{return nil};return value
    }
    private var translationLabel:String {
        if translationRunning {return translation.pauseRequested || processing.paused ? "翻译收尾中" : "翻译中"}
        if record?.state=="排队" || (pendingQueue && processing.running && entry?.translation != nil) {return "翻译排队中"}
        if let record,record.state != "完成",record.state != "已取消" {return record.failedIDs.isEmpty ? "翻译已暂停" : "翻译未完成"}
        if snapshot.translationErrors[lesson.id] != nil {return "翻译状态不可用"}
        return saved?.label(variant:lesson.selectedTranslationVariantID) ?? ""
    }
    private var summary:SavedAnalysisSummary? {snapshot.analysis(lesson,job:analysis)}
    private var analysisLabel:String {
        if analysisRunning {return analysis.pauseRequested || processing.paused ? "总结收尾中" : "总结生成中"}
        if pendingQueue && processing.running && entry?.analysis != nil {return "总结排队中"}
        return snapshot.savedAnalysisLabel(lesson,job:analysis)
    }
    private var detailText:String {
        var lines:[String]=[]
        if let saved,saved.total>0 {lines.append("当前译文：\(saved.completed(variant:lesson.selectedTranslationVariantID))/\(saved.total)")}
        if let record {lines.append("翻译任务：\(record.state) · \(record.completed)/\(record.ids.count)")}
        if translation.lessonID==lesson.id {
            if !translation.status.isEmpty {lines.append(translation.status)}
            if !translation.eta.isEmpty {lines.append(translation.eta)}
            if !translation.details.isEmpty {lines.append(translation.details)}
        }
        if analysisRunning {lines.append(analysis.status(for:lesson.id))}
        if let message=summary?.message {lines.append(message)}
        if let error=snapshot.translationErrors[lesson.id] {lines.append(error)}
        if let error=snapshot.analysisIssue(lesson,job:analysis) {lines.append(error)}
        if pendingQueue && !processing.message.isEmpty {lines.append(processing.message)}
        return lines.joined(separator:"\n")
    }
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            if !translationLabel.isEmpty {statusRow(translationLabel,running:translationRunning,progress:record.map {Double($0.completed)/Double(max(1,$0.ids.count))})}
            if !analysisLabel.isEmpty {statusRow(analysisLabel,running:analysisRunning,progress:summary?.progress)}
            if translationRunning || analysisRunning || pendingQueue || (record.map {$0.state != "完成" && $0.state != "已取消"} ?? false) || summary?.taskStatus != nil || snapshot.translationErrors[lesson.id] != nil || snapshot.analysisIssue(lesson,job:analysis) != nil {
                HStack(spacing:10) {
                    if processing.running && pendingQueue {Button("暂停") {processing.pause(store)}.disabled(processing.paused)}
                    else if translationRunning {Button("暂停") {translation.pause()}.disabled(translation.pauseRequested)}
                    else if analysisRunning {Button("暂停") {analysis.pause()}.disabled(analysis.pauseRequested)}
                    else if pendingQueue {Button("继续…") {processing.resume(store)}.disabled(translation.busy || analysis.running)}
                    else {
                        if let record,record.state != "完成",record.state != "已取消" {
                            Button("继续翻译…") {store.updateLecture(lesson.id){$0.selectedTranslationVariantID=record.variantID};translationConfirmation=true}.disabled(translation.busy || analysis.running)
                            Button("取消翻译") {translation.cancelQueued(lesson.id,store:store)}
                        }
                        if summary?.taskStatus != nil {Button("继续总结…") {analysisConfirmation=true}.disabled(translation.busy || analysis.running)}
                    }
                    if !detailText.isEmpty {Button("详情") {showingDetails.toggle()}}
                }.buttonStyle(.borderless).font(.caption)
            }
        }
        .task(id:lesson.transcriptVersion) {await snapshot.prepare(lesson,repository:store.repository)}
        .sheet(isPresented:$translationConfirmation) {TranslationConfirmation(store:store,job:translation,lessonID:lesson.id)}
        .sheet(isPresented:$analysisConfirmation) {AnalysisConfirmation(store:store,job:analysis,translation:translation,lessonID:lesson.id)}
        .popover(isPresented:$showingDetails) {ScrollView {Text(detailText).font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(14)}.frame(width:320,height:180)}
    }
    private func statusRow(_ label:String,running:Bool,progress:Double?)->some View {
        HStack(spacing:8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if running {
                if let progress {ProgressView(value:min(1,max(0,progress))).frame(width:100)}
                else {ProgressView().controlSize(.mini)}
            }
        }
    }
}
