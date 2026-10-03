import Foundation
import SwiftUI
import Core

struct ImportAnalysisPreview {
    var rowID: UUID
    var task: AnalysisTaskState
    var summary: String
}
@MainActor final class ImportProcessingCoordinator: ObservableObject {
    @Published private(set) var entries: [ImportProcessingEntry] = []
    @Published private(set) var running = false
    @Published private(set) var paused = false
    @Published private(set) var message = ""
    var worker: Task<Void,Never>?
    private func file(_ store:AppStore) throws -> URL {
        guard let root=store.repository?.root else {throw Failure("资料库不可用")}
        return root.appendingPathComponent("processing-queue.json")
    }
    private func save(_ store:AppStore) throws {try Codec.encode(entries).write(to:file(store),options:.atomic)}
    func restore(_ store:AppStore) {
        do {
            let url=try file(store)
            guard FileManager.default.fileExists(atPath:url.path) else{return}
            entries=try Codec.decode([ImportProcessingEntry].self,Data(contentsOf:url))
            for i in entries.indices where entries[i].status != "完成" {entries[i].status="等待确认恢复"}
        } catch {message="无法读取导入任务："+error.localizedDescription}
    }
    func pause(_ store:AppStore) {
        guard running,!paused else{return};paused=true;message="正在收尾；已发送结果保存后暂停。"
        store.translation.pause();store.analysis.pause()
    }
    func launch(_ proposed:[ImportProcessingEntry],store:AppStore,
                translationProvider:((TranslationConfig)throws->any TranslationProvider)?=nil,
                analysisProvider:(any AnalysisProvider)?=nil) throws {
        guard !running,!store.translation.busy,!store.analysis.running else {throw Failure("请等待当前翻译、总结或连接测试收尾")}
        guard !proposed.isEmpty else {throw Failure("没有待处理的课件")}
        guard Set(proposed.map(\.id)).count == proposed.count else {throw Failure("同一课件不能重复加入队列")}
        for entry in proposed {
            guard let lesson=store.library.lectures.first(where:{$0.id==entry.id}),let source=try store.repository?.read(lesson) else {throw Failure("课件或字幕已变化")}
            if let t=entry.translation {guard t.version==source.version,Set(t.ids).isSubset(of:Set(source.cues.map(\.id))) else {throw Failure("翻译范围已变化")}}
            if let a=entry.analysis {try a.validate();guard a.plan == (try AnalysisPlan.make(source)) else {throw Failure("总结范围已变化")}}
        }
        let previous=entries
        for entry in proposed {entries.removeAll{$0.id==entry.id};entries.append(entry)}
        do {try save(store)} catch {entries=previous;throw error}
        running=true;paused=false;store.translation.coordinating=true
        store.translation.onPause={ [weak self,weak store] in if let store {self?.pause(store)} }
        store.analysis.onPause={ [weak self,weak store] in if let store {self?.pause(store)} }
        worker=Task { [weak self,weak store] in
            guard let self,let store else{return}
            defer {
                self.running=false;self.worker=nil;store.translation.coordinating=false
                store.translation.onPause=nil;store.analysis.onPause=nil
            }
            for original in proposed {
                guard !self.paused,!Task.isCancelled else{break}
                do {
                    guard let lesson=store.library.lectures.first(where:{$0.id==original.id}),let source=try store.repository?.read(lesson) else {throw Failure("课件不存在")}
                    let index=self.entries.firstIndex{$0.id==original.id}!
                    self.entries[index].status="处理中";try self.save(store)
                    var translationWorker:Task<Void,Never>?
                    var analysisWorker:Task<Void,Never>?
                    // Resolve both providers before sending either request.
                    var translationRecord:TranslationTaskState?
                    var tp:(any TranslationProvider)?
                    if let confirmed=original.translation {
                        let variant=source.viewing(confirmed.variantID ?? confirmed.config.providerID.rawValue)
                        if let saved=variant.task {guard saved.version==confirmed.version,saved.ids==confirmed.ids,saved.config==confirmed.config else {throw Failure("已有翻译任务的范围或配置已变化，请单独确认后继续")}}
                        var record=variant.task ?? confirmed
                        guard record.version==source.version else {throw Failure("翻译字幕版本已变化")}
                        if !record.batches(variant).isEmpty {
                            record.state="排队";translationRecord=record
                            tp=try translationProvider?(record.config) ?? store.translation.provider(record.config)
                        }
                    }
                    var analysisRecord:AnalysisTaskState?
                    var ap:(any AnalysisProvider)?
                    if let confirmed=original.analysis {
                        let saved=try await AnalysisRepository(root:store.repository!.root).load(lessonID:lesson.id,sourceVersion:source.version)
                        if saved?.completed == nil || saved?.task != nil {
                            if let task=saved?.task {guard task.config==confirmed.config,task.plan==confirmed.plan else {throw Failure("已有总结任务的范围或配置已变化，请单独确认后继续")}}
                            analysisRecord=saved?.task ?? confirmed
                            ap=try analysisProvider ?? OpenAIAnalysisProvider(key:Keychain.read(.openAI))
                        }
                    }
                    if let record=translationRecord,let tp {
                        try store.translation.saveTask(record,lesson:lesson,store:store)
                        store.translation.launch(store:store,ids:[lesson.id],provider:tp,coordinated:true)
                        translationWorker=store.translation.task
                    }
                    if let record=analysisRecord,let ap {
                        try store.analysis.launch(store:store,lessonID:lesson.id,proposed:record,provider:ap,coordinated:true)
                        analysisWorker=store.analysis.worker
                    }
                    await translationWorker?.value;await analysisWorker?.value
                    if let confirmed=original.translation {
                        let latest=try store.repository!.read(lesson,variantID:confirmed.variantID)
                        guard confirmed.ids.allSatisfy({latest?.translations[$0] != nil}) else {throw Failure("翻译尚未完成，队列已暂停")}
                    }
                    if let confirmed=original.analysis {
                        let latest=try await AnalysisRepository(root:store.repository!.root).load(lessonID:lesson.id,sourceVersion:confirmed.plan.sourceVersion)
                        guard latest?.completed != nil,latest?.task == nil else {throw Failure("总结尚未完成，队列已暂停")}
                    }
                    self.entries[index].status="完成";try self.save(store)
                } catch {
                    self.pause(store);self.message=error.localizedDescription
                    await store.translation.task?.value;await store.analysis.worker?.value
                    break
                }
            }
            for i in self.entries.indices where self.entries[i].status != "完成" {self.entries[i].status="等待确认恢复"}
            do {try self.save(store)} catch {self.message="任务状态保存失败："+error.localizedDescription}
        }
    }
    func resume(_ store:AppStore) {
        let pending=entries.filter{$0.status != "完成"}
        guard !pending.isEmpty else{return}
        do {
            var descriptions:[String]=[]
            for entry in pending {
                guard let lesson=store.library.lectures.first(where:{$0.id==entry.id}),let source=try store.repository?.read(lesson) else {throw Failure("课件不可用")}
                descriptions.append(lesson.title)
                if let t=entry.translation {descriptions.append(try t.config.estimate(t.batches(source.viewing(t.variantID))))}
                if let a=entry.analysis {
                    let saved=try AnalysisRepository.readAll(root:store.repository!.root).first{$0.lessonID==entry.id && $0.sourceVersion==a.plan.sourceVersion}
                    let current=saved?.task ?? a
                    if saved?.completed == nil || saved?.task != nil {descriptions.append(current.config.selectionDescription);descriptions.append(current.plan.estimate(config:current.config,remainingChunkIDs:Set(current.pendingChunks.map(\.id))))}
                }
            }
            let alert=NSAlert();alert.messageText="继续排队的翻译与总结？"
            alert.informativeText=descriptions.joined(separator:"\n")+"\n仅处理未完成内容；费用为估算，不自动重试。"
            alert.addButton(withTitle:"确认继续");alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else{return}
            try launch(pending,store:store)
        } catch {message=error.localizedDescription;store.error=message}
    }
}
struct ImportProcessingStatus:View {
    @ObservedObject var job:ImportProcessingCoordinator
    @ObservedObject var analysis:AnalysisJob
    let store:AppStore;let id:UUID
    var body:some View {
        if let entry=job.entries.first(where:{$0.id==id}) {
            HStack {
                Text((entry.purpose == "chapters" ? "章节队列 · " : "导入处理 · ") + entry.status).font(.caption)
                if entry.analysis != nil {Text(analysis.runningLessonID==id ? analysis.status : (analysis.exact(id,version:entry.analysis!.plan.sourceVersion)?.completed != nil ? "总结已完成" : "总结待处理")).font(.caption).foregroundStyle(.secondary)}
                if job.running {Button("暂停全部") {job.pause(store)}}
                else if entry.status != "完成" {Button("继续…") {job.resume(store)}}
            }.buttonStyle(.borderless)
        }
    }
}
