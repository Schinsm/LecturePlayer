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
    private var activeTranslations:[UUID:TranslationJob]=[:]
    private var activeAnalyses:[UUID:AnalysisJob]=[:]
    private var incoming:[ImportProcessingEntry]=[]
    private var dispatchWake:AsyncStream<Bool>.Continuation?
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
        Task {await store.requests.pause()}
        store.translation.pause();store.analysis.pause()
        for job in activeTranslations.values {job.pause()}
        for job in activeAnalyses.values {job.pause()}
    }
    func launch(_ proposed:[ImportProcessingEntry],store:AppStore,
                translationProvider:((TranslationConfig)throws->any TranslationProvider)?=nil,
                analysisProvider:(any AnalysisProvider)?=nil,deferIfPaused:Bool=false) throws {
        guard !store.translation.testing,running || (!store.translation.busy && !store.analysis.running) else {throw Failure("请等待当前翻译、总结或连接测试收尾")}
        guard !proposed.isEmpty else {throw Failure("没有待处理的课件")}
        guard Set(proposed.map(\.id)).count == proposed.count else {throw Failure("同一课件不能重复加入队列")}
        for entry in proposed {
            guard let lesson=store.library.lectures.first(where:{$0.id==entry.id}),let source=try store.repository?.read(lesson) else {throw Failure("课件或字幕已变化")}
            if let t=entry.translation {guard t.version==source.version,Set(t.ids).isSubset(of:Set(source.cues.map(\.id))) else {throw Failure("翻译范围已变化")}}
            if let a=entry.analysis {try a.validate();guard a.plan == (try AnalysisPlan.make(source)) else {throw Failure("总结范围已变化")}}
        }
        guard !proposed.contains(where:{activeTranslations[$0.id] != nil || activeAnalyses[$0.id] != nil || incoming.map(\.id).contains($0.id)}) else {throw Failure("课件已在处理中")}
        let previous=entries
        for entry in proposed {entries.removeAll{$0.id==entry.id};entries.append(entry)}
        do {try save(store)} catch {entries=previous;throw error}
        if deferIfPaused && paused {
            for i in entries.indices where proposed.contains(where:{$0.id==entries[i].id}) {entries[i].status="等待确认恢复"}
            try save(store);return
        }
        incoming += proposed.filter {entry in !incoming.contains(where:{$0.id==entry.id})}
        if running {dispatchWake?.yield(false);return}
        running=true;paused=false;store.translation.coordinating=true;store.translation.pauseRequested=false
        store.analysis.pauseRequestedForQueue(false)
        store.translation.onPause={ [weak self,weak store] in if let store {self?.pause(store)} }
        store.analysis.onPause={ [weak self,weak store] in if let store {self?.pause(store)} }
        worker=Task { [weak self,weak store] in
            guard let self,let store else{return}
            defer {
                self.running=false;self.worker=nil;store.translation.coordinating=false
                store.translation.onPause=nil;store.analysis.onPause=nil
            }
            await store.requests.resume()
            repeat {
            await withTaskGroup(of:Void.self) {group in
                var active=0
                let events=AsyncStream<Bool> {self.dispatchWake=$0}
                var updates=events.makeAsyncIterator()
                defer {self.dispatchWake?.finish();self.dispatchWake=nil}
                @MainActor func dispatch() {
                    while !self.paused,!Task.isCancelled,active<2,!self.incoming.isEmpty {
                        let original=self.incoming.removeFirst();active += 1
                        group.addTask {
                            await self.process(original,store:store,translationProvider:translationProvider,analysisProvider:analysisProvider)
                            await self.didFinishDispatch()
                        }
                    }
                }
                dispatch()
                while active>0 {
                    guard let completed=await updates.next() else {break}
                    if completed {active -= 1}
                    dispatch()
                }
                await group.waitForAll()
            }
            await store.translation.writer.flushFiles()
            } while !self.paused && !Task.isCancelled && !self.incoming.isEmpty
            self.incoming=[]
            for i in self.entries.indices where self.entries[i].status != "完成" {self.entries[i].status="等待确认恢复"}
            do {try self.save(store)} catch {self.message="任务状态保存失败："+error.localizedDescription}
        }
    }
    private func didFinishDispatch() {dispatchWake?.yield(true)}
    private func process(_ original:ImportProcessingEntry,store:AppStore,
                         translationProvider:((TranslationConfig)throws->any TranslationProvider)?,analysisProvider:(any AnalysisProvider)?) async {
        let translation=TranslationJob(),analysis=AnalysisJob()
        translation.writer=store.translation.writer;translation.localEngine=store.translation.localEngine
        activeTranslations[original.id]=translation;activeAnalyses[original.id]=analysis
        translation.onPause={ [weak self,weak store] in if let store {self?.pause(store)}}
        analysis.onPause=translation.onPause
        translation.onState={ [weak store] id,state in store?.translation.states[id]=state;store?.translation.usageRevision += 1}
        analysis.onStatus={ [weak store] status in store?.analysis.lessonStatuses[original.id]=status}
        analysis.onRecord={ [weak store] record in store?.analysis.accept(record)}
        defer {
            activeTranslations[original.id]=nil;activeAnalyses[original.id]=nil
            store.analysis.coordinatedLessons.remove(original.id);store.translation.coordinatedLessons.remove(original.id)
        }
        do {
            guard !paused,let lesson=store.library.lectures.first(where:{$0.id==original.id}),let source=try store.repository?.read(lesson) else {throw Failure("课件不可用或队列已暂停")}
            if let i=entries.firstIndex(where:{$0.id==original.id}) {entries[i].status="处理中"};try save(store)
            var translationRecord:TranslationTaskState?;var tp:(any TranslationProvider)?
            if let confirmed=original.translation {
                let variant=source.viewing(confirmed.variantID ?? confirmed.config.providerID.rawValue)
                if let saved=variant.task {guard saved.version==confirmed.version,saved.ids==confirmed.ids,saved.config==confirmed.config else {throw Failure("已有翻译任务的范围或配置已变化，请重新确认")}}
                var record=variant.task ?? confirmed
                guard record.version==source.version else {throw Failure("字幕版本已变化")}
                if !record.batches(variant).isEmpty {record.state="排队";translationRecord=record;tp=try translationProvider?(record.config) ?? translation.provider(record.config)}
            }
            var analysisRecord:AnalysisTaskState?;var ap:(any AnalysisProvider)?
            if let confirmed=original.analysis {
                let saved=try await AnalysisRepository(root:store.repository!.root).load(lessonID:lesson.id,sourceVersion:source.version)
                if (original.regenerateAnalysis == true && (saved?.completedAt ?? .distantPast)<original.created) || saved?.completed == nil || saved?.task != nil {
                    if let task=saved?.task,original.analysisReconfirmed != true {guard task.config==confirmed.config,task.plan==confirmed.plan else {throw Failure("已有总结配置已变化，请重新确认")}}
                    analysisRecord=original.analysisReconfirmed == true ? confirmed : (saved?.task ?? confirmed);ap=try analysisProvider ?? OpenAIAnalysisProvider(key:Keychain.read(.openAI))
                }
            }
            guard !paused else {throw RequestNotDispatched()}
            if let record=translationRecord,let tp {store.translation.coordinatedLessons.insert(lesson.id);try translation.saveTask(record,lesson:lesson,store:store);translation.launch(store:store,ids:[lesson.id],provider:tp,coordinated:true)}
            if let record=analysisRecord,let ap {store.analysis.coordinatedLessons.insert(lesson.id);try analysis.launch(store:store,lessonID:lesson.id,proposed:record,provider:ap,coordinated:true)}
            await translation.task?.value;await analysis.worker?.value
            if let confirmed=original.translation {
                let latest=try store.repository!.read(lesson,variantID:confirmed.variantID)
                guard confirmed.ids.allSatisfy({latest?.translations[$0] != nil}) else {throw Failure("翻译尚未完成，队列已暂停")}
            }
            if let confirmed=original.analysis {
                let latest=try await AnalysisRepository(root:store.repository!.root).load(lessonID:lesson.id,sourceVersion:confirmed.plan.sourceVersion)
                guard latest?.completed != nil,latest?.task==nil else {throw Failure("总结尚未完成，队列已暂停")}
            }
            if let i=entries.firstIndex(where:{$0.id==original.id}) {entries[i].status="完成";entries[i].regenerateAnalysis=nil;entries[i].analysisReconfirmed=nil};try save(store)
        } catch {
            pause(store);message=error.localizedDescription
            await translation.task?.value;await analysis.worker?.value
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
