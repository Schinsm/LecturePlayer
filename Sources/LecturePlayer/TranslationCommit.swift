import Foundation
import Core

enum TranscriptTransactions { static let lock=NSRecursiveLock() }

struct TranslationCommit: Sendable {
    var transcript: Transcript; var complete: Bool; var saved: Int
    var sidecars: [String:String]?; var fileStatus: String
}
/// One actor owns background translation file transactions, including read/merge/write.
actor TranslationWriter {
    private var pending:[URL:Lecture]=[:]
    private var pendingTimings:[URL:[UUID:Double]]=[:]
    private var scheduled:Task<Void,Never>?
    var fileUpdate:(@MainActor @Sendable (UUID,TranslationCommit)->Void)?
    func observeFiles(_ callback:@escaping @MainActor @Sendable(UUID,TranslationCommit)->Void) {fileUpdate=callback}
    func enqueueFiles(_ lesson:Lecture,url:URL) {
        pending[url]=lesson
        guard scheduled==nil else{return}
        scheduled=Task {try? await Task.sleep(for:.seconds(1));if !Task.isCancelled {await self.flushFiles()}}
    }
    func flushFiles() async {
        scheduled?.cancel();scheduled=nil
        let work=pending;pending=[:]
        for (url,lesson) in work {
            do {let result=try saveFiles(lesson:lesson,url:url);await fileUpdate?(lesson.id,result)}
            catch {pending[url]=lesson} // Explicit file retry or next flush; never calls a service.
        }
    }

    func saveFiles(lesson:Lecture,url:URL) throws -> TranslationCommit {
        TranscriptTransactions.lock.lock();defer{TranscriptTransactions.lock.unlock()}
        var t=try Codec.decode(Transcript.self,Data(contentsOf:url));try t.validate()
        let started=Date()
        for i in (t.attempts ?? []).indices {if let duration=pendingTimings[url]?[t.attempts![i].id] {t.attempts![i].databaseSeconds=duration}}
        pendingTimings[url]=nil
        var lesson=lesson
        for variant in (t.variants ?? [:]).values {lesson.sidecars=(lesson.sidecars ?? [:]).merging(variant.sidecars ?? [:]){_,new in new}}
        let selected=t.variantID;var messages:[String]=[]
        for id in (t.variants ?? [:]).keys.sorted() where !(t.variants?[id]?.translations.isEmpty ?? true) {
            t=t.viewing(id)
            do {
                guard let path=lesson.subtitlePath else{throw Failure("请定位原英文字幕")}
                let original=URL(fileURLWithPath:path)
                guard digest(try Data(contentsOf:original))==t.version else{throw Failure("原字幕缺失或已变化，请重新定位")}
                lesson.sidecars=try SidecarWriter.write(t,lesson:lesson,beside:original,hideSpeakers:UserDefaults.standard.object(forKey:"hideSpeakerLabels") as? Bool ?? true)
                t.variants?[id]?.sidecars=lesson.sidecars
                t.variants?[id]?.fileStatus="文件已保存"
            } catch {t.variants?[id]?.fileStatus="文件待保存："+error.localizedDescription}
            messages.append((t.variants?[id]?.title ?? id)+" · "+(t.variants?[id]?.fileStatus ?? ""))
        }
        t=t.viewing(selected)
        if let last=t.attempts?.indices.last {t.attempts![last].sidecarSeconds=Date().timeIntervalSince(started)}
        try Codec.encode(t).write(to:url,options:.atomic)
        return TranslationCommit(transcript:t,complete:true,saved:0,sidecars:lesson.sidecars,fileStatus:messages.joined(separator:"；"))
    }
    func read(_ url:URL) throws -> Transcript {let t=try Codec.decode(Transcript.self,Data(contentsOf:url));try t.validate();return t}
    func commit(result:TranslationResult,batch:TranslationBatch,config:TranslationConfig,lesson:Lecture,url:URL,seconds:Double?,attemptID:UUID,allowSave:Bool,deferFiles:Bool=false,queueSeconds:Double?=nil) throws -> TranslationCommit {
        TranscriptTransactions.lock.lock();defer{TranscriptTransactions.lock.unlock()}
        var t=try Codec.decode(Transcript.self,Data(contentsOf:url));try t.validate();try t.migrateVariants();t=t.viewing(config.providerID.rawValue);t.ensureVariant(t.variantID)
        guard t.version==batch.sourceVersion else {throw Failure("原字幕版本发生变化")}
        let key=try batch.key(config)
        var a=TranslationAttempt(model:config.providerID == .openAI ? config.model : config.providerID.rawValue+"-standard",batchKey:key,requestID:result.requestID,expected:batch.targets.count,outcome:"已收到响应，待校验")
        a.id=attemptID;a.variantID=t.variantID;a.service=config.providerID;a.requestSeconds=seconds;a.queueSeconds=queueSeconds;a.targetIDs=batch.targets.map(\.id);a.diagnostics=result.diagnostics
        let descriptor=try config.usageDescriptor()
        var u=TranslationUsage(result:result,config:config,descriptor:descriptor,batchKey:key);u.attemptID=attemptID;u.variantID=t.variantID;u.submittedCharacters=batch.targets.reduce(0){$0+(config.providerID == .azure ? $1.en.utf16.count : $1.en.unicodeScalars.count)}
        t.attempts=(t.attempts ?? [])+[a];t.usage=(t.usage ?? [])+[u]
        let validationStart=Date()
        let check=TranslationAssessment(result.problem == nil && allowSave ? result.items : [],targets:batch.targets)
        let problem=result.problem ?? (allowSave ? nil : "字幕版本已改变，未写入译文")
        if problem == nil {
            for item in check.accepted where t.translations[item.id] == nil {
                var translation=Translation(ai:item.zh,cacheKey:key);translation.service=config.providerID;translation.model=a.model
                t.translations[item.id]=translation;a.saved += 1
            }
        }
        let complete=problem == nil && check.complete
        a.outcome=problem ?? (complete ? "完成" : check.summary);a.validationSeconds=Date().timeIntervalSince(validationStart)
        if var task=t.task {task.completed=task.ids.filter{t.translations[$0] != nil}.count;if !complete {task.failed(batch,transcript:t)};task.failedIDs.removeAll{t.translations[$0] != nil};t.task=task}
        if complete && !t.completedBatches.contains(key) {t.completedBatches.append(key)}
        t.attempts![t.attempts!.count-1]=a
        let selectedVariant=t.variantID
        t.variants?[selectedVariant]?.fileStatus="译文已保存；等待生成文件"
        try t.validate()
        let dbStart=Date();try Codec.encode(t).write(to:url,options:.atomic)
        let duration=Date().timeIntervalSince(dbStart)
        pendingTimings[url,default:[:]][attemptID]=duration;PerformanceTrace.record("translation.commit",duration)
        var saved=TranslationCommit(transcript:t,complete:complete,saved:a.saved,sidecars:nil,fileStatus:"译文已保存；等待生成文件")
        if allowSave && t.translatedCount>0 {
            if deferFiles {enqueueFiles(lesson,url:url)}
            else {let files=try saveFiles(lesson:lesson,url:url);saved.transcript=files.transcript;saved.sidecars=files.sidecars;saved.fileStatus=files.fileStatus}
        }
        return saved
    }
}
