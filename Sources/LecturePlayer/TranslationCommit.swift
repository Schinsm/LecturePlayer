import Foundation
import Core

enum TranscriptTransactions { static let lock=NSRecursiveLock() }

struct TranslationCommit: Sendable {
    var transcript: Transcript; var complete: Bool; var saved: Int
    var sidecars: [String:String]?; var fileStatus: String
    var fileOutcome:FileSaveOutcome = .unchanged
}
/// One actor owns background translation file transactions, including read/merge/write.
actor TranslationWriter {
    private let writeTranscript:@Sendable(Data,URL)throws->Void
    private var blockedRecovery:[URL:String]=[:]
    init(writeTranscript:@escaping @Sendable(Data,URL)throws->Void = {try $0.write(to:$1,options:.atomic)}) {self.writeTranscript=writeTranscript}

    private var pending:[URL:Lecture]=[:]
    private var pendingTimings:[URL:[UUID:Double]]=[:]
    private var scheduled:Task<Void,Never>?
    var fileFailure:(@MainActor @Sendable (UUID,Error)->Void)?
    func observeFailures(_ callback:@escaping @MainActor @Sendable(UUID,Error)->Void) {fileFailure=callback}
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
            catch {await fileFailure?(lesson.id,error)} // Durable pending status remains; explicit retry only.
        }
    }

    func saveFiles(lesson:Lecture,url:URL,onlyIfNeeded:Bool=false) throws -> TranslationCommit {
        let t=try read(url)
        let hidden=UserDefaults.standard.object(forKey:"hideSpeakerLabels") as? Bool ?? true
        let key=try (t.variants ?? [:]).keys.sorted().map{try SidecarWriter.inputKey(t.viewing($0),lesson:lesson,hideSpeakers:hidden)}.joined(separator:":")
        if onlyIfNeeded && blockedRecovery[url]==key {
            return TranslationCommit(transcript:t,complete:false,saved:0,sidecars:lesson.sidecars,fileStatus:lesson.sidecarStatus ?? "文件待保存：资料库写入尚未成功，请重试保存。",fileOutcome:.failed)
        }
        do {let value=try performSaveFiles(lesson:lesson,url:url,onlyIfNeeded:onlyIfNeeded);blockedRecovery[url]=nil;return value}
        catch {blockedRecovery[url]=key;throw error}
    }
    private func performSaveFiles(lesson:Lecture,url:URL,onlyIfNeeded:Bool) throws -> TranslationCommit {
        TranscriptTransactions.lock.lock();defer{TranscriptTransactions.lock.unlock()}
        let originalBytes=try Data(contentsOf:url)
        var t=try Codec.decode(Transcript.self,originalBytes);try t.validate()
        let before=t,started=Date(),timings=pendingTimings[url] ?? [:]
        for i in (t.attempts ?? []).indices {if let duration=timings[t.attempts![i].id] {t.attempts![i].databaseSeconds=duration}}
        var lesson=lesson
        for variant in (t.variants ?? [:]).values {lesson.sidecars=(lesson.sidecars ?? [:]).merging(variant.sidecars ?? [:]){_,new in new}}
        let selected=t.variantID;var messages:[String]=[];var outcome=FileSaveOutcome.unchanged
        let hidden=UserDefaults.standard.object(forKey:"hideSpeakerLabels") as? Bool ?? true
        for id in (t.variants ?? [:]).keys.sorted() where !(t.variants?[id]?.translations.isEmpty ?? true) {
            t=t.viewing(id)
            let input=try SidecarWriter.inputKey(t,lesson:lesson,hideSpeakers:hidden)
            let variant=t.variants![id]!
            let files=variant.sidecars ?? [:]
            let missing=files.isEmpty || files.keys.contains{!FileManager.default.fileExists(atPath:$0)}
            // A failed attempt is retried only after business inputs change or explicit user action.
            let failed=variant.fileStatus?.hasPrefix("文件待保存") == true
            let same=variant.fileInputKey==input
            if !onlyIfNeeded || !same || (!failed && missing) || variant.fileStatus=="译文已保存；等待生成文件" {
                do {
                    guard let path=lesson.subtitlePath else{throw StorageIssue(.unavailable)}
                    let original=URL(fileURLWithPath:path)
                    guard digest(try Data(contentsOf:original))==t.version else{throw StorageIssue(.unavailable)}
                    let report=try SidecarWriter.writeReport(t,lesson:lesson,beside:original,hideSpeakers:hidden)
                    lesson.sidecars=report.files
                    t.variants?[id]?.sidecars=report.files
                    t.variants?[id]?.fileStatus=report.outcome == .conflict ? "文件已保存；人工修改文件已保留，译文另存" : "文件已保存"
                    if outcome != .failed && report.outcome != .unchanged {outcome=report.outcome}
                    if report.writes>0 {StorageDiagnostics.record(root:url.deletingLastPathComponent().deletingLastPathComponent(),operation:.sidecar,outcome:report.outcome,bytes:report.bytes,count:report.writes)}
                } catch {
                    outcome = .failed
                    t.variants?[id]?.fileStatus="文件待保存："+StorageIssue(error).localizedDescription+" 译文已在资料库中；重试文件保存不会重新翻译。"
                    StorageDiagnostics.record(root:url.deletingLastPathComponent().deletingLastPathComponent(),operation:.sidecar,outcome:.failed,error:error)
                }
                t.variants?[id]?.fileInputKey=input
            }
            messages.append((t.variants?[id]?.title ?? id)+" · "+(t.variants?[id]?.fileStatus ?? ""))
        }
        t=t.viewing(selected)
        // Only requests committed in this process receive timings, once. Recovery never edits history.
        for i in (t.attempts ?? []).indices where timings[t.attempts![i].id] != nil {t.attempts![i].sidecarSeconds=Date().timeIntervalSince(started)}
        if t != before {
            let bytes=try Codec.encode(t)
            if bytes != originalBytes {try writeTranscript(bytes,url);StorageDiagnostics.record(root:url.deletingLastPathComponent().deletingLastPathComponent(),operation:.transcript,outcome:.written,bytes:bytes.count)}
        }
        pendingTimings[url]=nil
        return TranslationCommit(transcript:t,complete:true,saved:0,sidecars:lesson.sidecars,fileStatus:messages.joined(separator:"；"),fileOutcome:outcome)
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
        let dbStart=Date();let payload=try Codec.encode(t);try writeTranscript(payload,url)
        StorageDiagnostics.record(root:url.deletingLastPathComponent().deletingLastPathComponent(),operation:.transcript,outcome:.written,bytes:payload.count)
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
