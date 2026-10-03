import Foundation
import Core

enum TranscriptTransactions { static let lock=NSRecursiveLock() }

struct TranslationCommit: Sendable {
    var transcript: Transcript; var complete: Bool; var saved: Int
    var sidecars: [String:String]?; var fileStatus: String
}
/// One actor owns background translation file transactions, including read/merge/write.
actor TranslationWriter {
    func saveFiles(lesson:Lecture,url:URL) throws -> TranslationCommit {
        TranscriptTransactions.lock.lock();defer{TranscriptTransactions.lock.unlock()}
        var t=try Codec.decode(Transcript.self,Data(contentsOf:url));try t.validate()
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
        t=t.viewing(selected);try Codec.encode(t).write(to:url,options:.atomic)
        return TranslationCommit(transcript:t,complete:true,saved:0,sidecars:lesson.sidecars,fileStatus:messages.joined(separator:"；"))
    }
    func read(_ url:URL) throws -> Transcript {let t=try Codec.decode(Transcript.self,Data(contentsOf:url));try t.validate();return t}
    func commit(result:TranslationResult,batch:TranslationBatch,config:TranslationConfig,lesson:Lecture,url:URL,seconds:Double?,attemptID:UUID,allowSave:Bool) throws -> TranslationCommit {
        TranscriptTransactions.lock.lock();defer{TranscriptTransactions.lock.unlock()}
        var t=try Codec.decode(Transcript.self,Data(contentsOf:url));try t.validate();try t.migrateVariants();t=t.viewing(config.providerID.rawValue);t.ensureVariant(t.variantID)
        guard t.version==batch.sourceVersion else {throw Failure("原字幕版本发生变化")}
        let key=try batch.key(config)
        var a=TranslationAttempt(model:config.providerID == .openAI ? config.model : config.providerID.rawValue+"-standard",batchKey:key,requestID:result.requestID,expected:batch.targets.count,outcome:"已收到响应，待校验")
        a.id=attemptID;a.variantID=t.variantID;a.service=config.providerID;a.requestSeconds=seconds;a.targetIDs=batch.targets.map(\.id);a.diagnostics=result.diagnostics
        let descriptor=try config.usageDescriptor()
        var u=TranslationUsage(result:result,config:config,descriptor:descriptor,batchKey:key);u.attemptID=attemptID;u.variantID=t.variantID;u.submittedCharacters=batch.targets.reduce(0){$0+(config.providerID == .azure ? $1.en.utf16.count : $1.en.unicodeScalars.count)}
        t.attempts=(t.attempts ?? [])+[a];t.usage=(t.usage ?? [])+[u]
        let dbStart=Date();try Codec.encode(t).write(to:url,options:.atomic)
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
        try t.validate();try Codec.encode(t).write(to:url,options:.atomic)
        a.databaseSeconds=max(0,Date().timeIntervalSince(dbStart)-(a.validationSeconds ?? 0))
        let sideStart=Date();var sidecars:[String:String]?;var fileStatus="译文已保存至资料库"
        if allowSave && t.translatedCount>0 {
            do {
                guard let path=lesson.subtitlePath else {throw Failure("请定位原英文字幕以生成译文文件")}
                let subtitle=URL(fileURLWithPath:path)
                let access=subtitle.startAccessingSecurityScopedResource();defer{if access{subtitle.stopAccessingSecurityScopedResource()}}
                guard digest(try Data(contentsOf:subtitle))==t.version else {throw Failure("原字幕缺失或内容变化，请重新定位")}
                var merged=lesson;for variant in (t.variants ?? [:]).values {merged.sidecars=(merged.sidecars ?? [:]).merging(variant.sidecars ?? [:]){_,new in new}}
                sidecars=try SidecarWriter.write(t,lesson:merged,beside:subtitle,hideSpeakers:UserDefaults.standard.object(forKey:"hideSpeakerLabels") as? Bool ?? true)
                fileStatus="中文 VTT 与双语 Markdown 已保存（\(t.translatedCount)/\(t.cues.count)）"
            } catch {fileStatus="译文已存资料库；文件待保存："+error.localizedDescription}
        }
        let variantID=t.variantID
        if let sidecars {t.variants?[variantID]?.sidecars=sidecars}
        t.variants?[variantID]?.fileStatus=fileStatus
        a.sidecarSeconds=Date().timeIntervalSince(sideStart);t.attempts![t.attempts!.count-1]=a
        try Codec.encode(t).write(to:url,options:.atomic)
        return TranslationCommit(transcript:t,complete:complete,saved:a.saved,sidecars:sidecars,fileStatus:fileStatus)
    }
}
