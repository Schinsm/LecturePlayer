import SwiftUI
import Security
import LocalAuthentication
import Core

struct Keychain {
    static var isConfigured:Bool { configured(.openAI) }
    static func configured(_ provider:TranslationService)->Bool {
        if provider == .apple {if #available(macOS 15.0,*) {return true};return false}
        let service = keyService(provider)
        let context=LAContext();context.interactionNotAllowed=true
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"api-key",kSecReturnAttributes as String:true,kSecUseAuthenticationContext as String:context]
        return SecItemCopyMatching(q as CFDictionary,nil)==errSecSuccess
    }
    static let service="local.LecturePlayer.openai"
    static func keyService(_ provider:TranslationService)->String {provider == .openAI ? service : "local.LecturePlayer."+provider.rawValue}
    static func read(_ provider:TranslationService = .openAI) throws -> String {
        let service=keyService(provider)
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"api-key",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        guard status==errSecSuccess,let data=result as? Data,let key=String(data:data,encoding:.utf8) else {throw Failure(status==errSecItemNotFound ? "请在设置中输入所选服务的 API Key" : "Keychain 读取失败：\(status)")};return key
    }
    static func save(_ key:String, provider:TranslationService = .openAI) throws {
        defer {Task {@MainActor in KeychainAvailability.shared.invalidate(provider)}}
        let service=keyService(provider)
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"api-key"]
        let attributes:[String:Any]=[kSecValueData as String:Data(key.utf8)]
        let status=SecItemUpdate(q as CFDictionary,attributes as CFDictionary)
        if status==errSecItemNotFound {var insert=q;attributes.forEach{insert[$0]=$1};insert[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly;let added=SecItemAdd(insert as CFDictionary,nil);guard added==errSecSuccess else{throw Failure("Keychain 保存失败：\(added)")}}
        else if status != errSecSuccess {throw Failure("Keychain 保存失败：\(status)")}
    }
    static func remove(_ provider:TranslationService = .openAI) throws {
        defer {Task {@MainActor in KeychainAvailability.shared.invalidate(provider)}}
        let service=keyService(provider);let s=SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"api-key"] as CFDictionary);guard s==errSecSuccess || s==errSecItemNotFound else{throw Failure("Keychain 删除失败：\(s)")}}
}
@MainActor final class TranslationJob:ObservableObject {
    @Published var coordinating=false
    var onPause:(()->Void)?
    @Published var analyzing=false
    var busy:Bool {running || testing || analyzing || coordinating}
    @Published var testing=false
    @Published var testRevision=0
    @Published var usageRevision=0
    var serviceTestTask:Task<Void,Never>?
    @Published var lessonID:UUID?
    @Published var pauseRequested=false
    @Published var eta:String=""
    var writer=TranslationWriter()
    var scheduler:RequestScheduler?
    var onState:((UUID,TranslationTaskState)->Void)?
    @Published var coordinatedLessons:Set<UUID>=[]
    func isRunning(_ id:UUID?) -> Bool {id != nil && ((running && lessonID==id) || coordinatedLessons.contains(id!))}
    var acceptsQueuedWork:Bool {!testing && (!busy || coordinating)}
    let requestGate=TranslationRequestGate()
    func pause(){onPause?();if let scheduler {Task {await scheduler.pause()}};requestGate.setPaused(true);pauseRequested=true;status="正在收尾：已发送的请求完成后保存，不再发送新请求。"}
    var localEngine:AnyObject? = {if #available(macOS 15.0,*) {return AppleTranslationEngine()};return nil}()
    func provider(_ config:TranslationConfig) throws -> any TranslationProvider {
        if config.providerID == .apple {if #available(macOS 15.0,*),let engine=localEngine as? AppleTranslationEngine {return engine};throw Failure("Apple 本机翻译需要 macOS 15 或更新版本")}
        let key=try Keychain.read(config.providerID)
        switch config.providerID {case .azure:return AzureProvider(key:key,gate:requestGate);case .deepL:return DeepLProvider(key:key,gate:requestGate);case .openAI:return OpenAIProvider(key:key);case .apple:throw Failure("本机翻译不可用")}
    }
    @Published var running=false; @Published var status=""; @Published var details=""
    var task:Task<Void,Never>?
    var authorized:[UUID]=[]
    @Published var states: [UUID:TranslationTaskState] = [:]
    func restore(_ store:AppStore) {
        states=[:];authorized=[];lessonID=nil;status="";details=""
        for lesson in store.library.lectures {
            if let source=try? store.repository?.read(lesson), var record = source.variants?.values.compactMap(\.task).sorted(by: { ($0.state != "完成" && $0.state != "已取消" ? 0 : 1) < ($1.state != "完成" && $1.state != "已取消" ? 0 : 1) }).first {
                if record.state != "完成" && record.state != "已取消" { record.state="待恢复" }
                states[lesson.id]=record;onState?(lesson.id,record)
            }
        }
    }
    func saveTask(_ record:TranslationTaskState,lesson:Lecture,store:AppStore) throws {
        TranscriptTransactions.lock.lock();defer{TranscriptTransactions.lock.unlock()}
        guard var t=try store.repository?.read(lesson,variantID:record.variantID ?? record.config.providerID.rawValue),t.version == record.version else { throw Failure("字幕版本已改变，需要重新确认") }
        t.task=record;try store.repository?.write(t,for:lesson.id);store.displayTranscript(t,for:lesson.id);states[lesson.id]=record;onState?(lesson.id,record)
    }
    func start(store:AppStore,ids:Set<String>?,retry:Bool=false,wholeLecture:Bool=false,lectureID:UUID?=nil,precise:Bool=false) {
        guard !busy,let lecture=store.library.lectures.first(where:{$0.id == (lectureID ?? store.current)}) else{return}
        lessonID=lecture.id
        do {
            guard let source=try store.repository?.read(lecture),!source.cues.isEmpty else{return}
            let config=TranslationPreferences.load(.standard,glossary:store.library.courses.first { $0.id == lecture.courseID }?.glossary ?? "")
            var record:TranslationTaskState
            if retry,let previous=source.task,previous.version == source.version {
                record=previous
            } else {
                let missing=Set(source.cues.filter { source.translations[$0.id] == nil && (ids == nil || ids!.contains($0.id)) }.map(\.id))
                let limit=UserDefaults.standard.object(forKey:"batchLimit") == nil ? 5 : max(1,UserDefaults.standard.integer(forKey:"batchLimit"))
                let selected=Array((config.providerID == .azure ? config.batches(source,ids:missing) : TranslationBatch.make(source,ids:missing,maxCues:precise ? 1 : 10)).prefix(wholeLecture ? Int.max : limit))
                record=TranslationTaskState(transcript:source,ids:selected.flatMap(\.targets).map(\.id),config:config)
                if retry { record.failedIDs=record.ids;record.retrySize=5 }
            }
            if precise || UserDefaults.standard.bool(forKey:"translationSingleCue") {record.singleCue=true}
            let batches=record.batches(source)
            guard !batches.isEmpty else { status="所选范围已有译文，没有发起请求。";return }
            let estimate=try record.config.estimate(batches)
            let alert=NSAlert();alert.messageText="发送 \(batches.reduce(0){$0+$1.targets.count}) 条字幕 · \(batches.count) 次请求？"
            alert.informativeText="服务：\(record.config.providerID.title) · \(record.config.displayModel)\n\(estimate)\n范围：本任务全部剩余内容。拆小补译后继续原任务；异常即暂停整个队列，不自动重发。超时也可能计费。"
            alert.addButton(withTitle:record.config.providerID == .azure ? "确认使用 Azure 翻译" : "确认付费翻译");alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let provider=try self.provider(record.config)
            record.state="排队";try saveTask(record,lesson:lecture,store:store)
            launch(store:store,ids:[lecture.id],provider:provider)
        } catch {store.error=error.localizedDescription}
    }
    func launch(store:AppStore,ids:[UUID],provider:any TranslationProvider,coordinated:Bool=false) {
        if !coordinated,store.processing.running {
            do {
                let entries=try ids.map {id -> ImportProcessingEntry in
                    guard let lesson=store.library.lectures.first(where:{$0.id==id}),let task=try store.repository?.read(lesson,variantID:states[id]?.variantID)?.task else {throw Failure("翻译任务不可用")}
                    return ImportProcessingEntry(id:id,translation:task,analysis:nil)
                }
                try store.processing.launch(entries,store:store)
            } catch {store.error=error.localizedDescription}
            return
        }
        guard !testing,(!analyzing && !coordinating) || coordinated else{return}
        if running {authorized += ids.filter{!authorized.contains($0) && lessonID != $0};return};running=true;pauseRequested=false;requestGate.setPaused(false);eta=""
        scheduler=store.requests
        task=Task { [weak self,weak store] in
            guard let self,let store else{return};defer{self.running=false;self.task=nil}
            if !coordinated {await store.requests.resume()}
            await self.executeQueue(store:store,ids:ids,provider:provider)
        }
    }
    func executeQueue(store:AppStore,ids:[UUID],provider:any TranslationProvider) async {
        authorized += ids.filter{!authorized.contains($0)}
        while !authorized.isEmpty {
            let id=authorized.removeFirst()
            guard !Task.isCancelled,!pauseRequested,let lesson=store.library.lectures.first(where:{$0.id==id}) else{break}
            do {
                guard let source=try store.repository?.read(lesson,variantID:states[id]?.variantID),var record=source.task,record.version==source.version else{throw Failure("字幕版本已变化，需要重新确认")}
                record.state="翻译中";try saveTask(record,lesson:lesson,store:store)
                await run(store:store,lecture:lesson,batches:record.batches(source),config:record.config,provider:provider)
                guard states[id]?.state == "完成" else{break}
            } catch {onPause?();status=error.localizedDescription;break}
        }
        // An error or cancellation pauses every remaining authorized task, not just the visible lesson.
        authorized=[]
        for id in Array(states.keys) where states[id]?.state == "排队" || states[id]?.state == "翻译中" {
            if let lesson=store.library.lectures.first(where:{$0.id==id}),var record=states[id] {
                record.state="已暂停";do{try saveTask(record,lesson:lesson,store:store)}catch{store.error=error.localizedDescription}
            }
        }
    }
    /// Separate from confirmation and Keychain so the actual job can be exercised with mock providers.
    func run(store:AppStore,lecture:Lecture,batches:[TranslationBatch],config:TranslationConfig,provider:any TranslationProvider) async {
        lessonID=lecture.id
        var cursor=0;var stopped=false;var completedRequests=0
        let started=Date()
        guard let file=try? store.repository?.transcriptURL(lecture.id,lecture.transcriptVersion ?? ""),var latestTranscript=try? await writer.read(file) else {status="无法读取字幕，未发送请求";return}
        latestTranscript=latestTranscript.viewing(config.providerID.rawValue)
        struct Completed:Sendable {var batch:TranslationBatch;var result:TranslationResult;var seconds:Double;var id:UUID;var sent=true;var lease:RequestScheduler.Lease?=nil}
        await withTaskGroup(of:Completed.self) { group in
            @MainActor func dispatch() -> Bool {
                guard !pauseRequested,!stopped,!Task.isCancelled else{return false}
                while cursor<batches.count {
                    var batch=batches[cursor];cursor += 1
                    guard let active=store.library.lectures.first(where:{$0.id==lecture.id}),active.transcriptVersion==batch.sourceVersion,
                          latestTranscript.version==batch.sourceVersion else {stopped=true;status="字幕版本已变化，需要重新确认";return false}
                    batch.targets.removeAll{latestTranscript.translations[$0.id] != nil}
                    if batch.targets.isEmpty {continue}
                    let planned=batch
                    group.addTask {
                        let id=UUID();let lease:RequestScheduler.Lease
                        do {lease=try await store.requests.acquire(lesson:lecture.id,serial:config.providerID == .openAI ? nil : config.providerID.rawValue)}
                        catch {return Completed(batch:planned,result:TranslationResult(items:[]),seconds:0,id:id,sent:false)}
                        let valid=await MainActor.run { !self.pauseRequested && store.library.lectures.first(where:{$0.id==lecture.id})?.transcriptVersion==planned.sourceVersion }
                        guard valid,!Task.isCancelled else {await store.requests.pause();await store.requests.release(lease);return Completed(batch:planned,result:TranslationResult(items:[]),seconds:0,id:id,sent:false)}
                        let start=Date();let result:TranslationResult
                        do {try Task.checkCancellation();result=try await provider.translate(planned,config:config)}
                        catch is TranslationNotSent {await store.requests.release(lease);return Completed(batch:planned,result:TranslationResult(items:[]),seconds:0,id:id,sent:false)}
                        catch {result=(error as? APIError)?.result ?? TranslationResult(items:[],problem:error is CancellationError || (error as? URLError)?.code == .cancelled ? "请求已取消；用量未知，可能已计费" : "网络或服务请求失败；未自动重发，用量可能已计费")}
                        return Completed(batch:planned,result:result,seconds:Date().timeIntervalSince(start),id:id,lease:lease)
                    }
                    return true
                }
                return false
            }
            for _ in 0..<config.parallelism {_ = dispatch()}
            while let done=await group.next() {
                if !done.sent {stopped=true;continue}
                do {
                    let saved=try await commit(done.result,batch:done.batch,config:config,lecture:lecture,store:store,seconds:done.seconds,attemptID:done.id,deferFiles:true,queueSeconds:done.lease?.queueSeconds)
                    latestTranscript=saved.transcript
                    completedRequests += 1
                    if !saved.complete {onPause?();stopped=true;requestGate.setPaused(true);details=(done.result.problem ?? saved.transcript.attempts?.last?.outcome ?? "尚未完成")+"\n请求："+(done.result.requestID ?? "未记录");status="已保存 \(saved.saved) 条，本组还有 \(done.batch.targets.count-saved.saved) 条尚未完成。此前译文已保留。"}
                    else if !stopped && !pauseRequested {status="本课已译 \(saved.transcript.translatedCount)/\(saved.transcript.cues.count)"}
                    if completedRequests>=3 && !stopped && !pauseRequested {eta="预计还需约 \(max(1,Int(Date().timeIntervalSince(started)/Double(completedRequests)*Double(batches.count-completedRequests)/60))) 分钟"}
                } catch {onPause?();stopped=true;store.storageFailed(error);status="资料库保存未完成："+StorageIssue(error).localizedDescription}
                if stopped || pauseRequested {await store.requests.pause()}
                if let lease=done.lease {await store.requests.release(lease)}
                if !stopped && !pauseRequested {_ = dispatch()}
            }
        }
        await writer.flushFiles()
        eta=""
        if let source=try? store.repository?.read(lecture,variantID:config.providerID.rawValue),var record=source.task {
            record.completed=record.ids.filter{source.translations[$0] != nil}.count
            record.state=record.completed==record.ids.count && !stopped ? "完成" : "已暂停"
            do{try saveTask(record,lesson:lecture,store:store)}catch{store.error=error.localizedDescription}
            if !stopped || pauseRequested {status="本课已译 \(source.translatedCount)/\(source.cues.count)" + (record.state == "完成" ? " · 本次完成" : " · 已暂停，译文已保存") }
        }
    }
    func commit(_ result:TranslationResult,batch:TranslationBatch,config:TranslationConfig,lecture:Lecture,store:AppStore,seconds:Double?=nil,attemptID:UUID=UUID(),deferFiles:Bool=false,queueSeconds:Double?=nil) async throws -> TranslationCommit {
        guard let repo=store.repository else {throw Failure("资料库不可用")}
        let active=store.library.lectures.first{$0.id==lecture.id} ?? lecture
        let saved=try await writer.commit(result:result,batch:batch,config:config,lesson:active,url:repo.transcriptURL(lecture.id,batch.sourceVersion),seconds:seconds,attemptID:attemptID,allowSave:active.transcriptVersion==batch.sourceVersion,deferFiles:deferFiles,queueSeconds:queueSeconds)
        usageRevision += 1
        if let record=saved.transcript.task {states[lecture.id]=record;onState?(lecture.id,record)}
        if store.current==lecture.id && active.transcriptVersion==saved.transcript.version {store.displayTranscript(saved.transcript,for:lecture.id)}
        if active.transcriptVersion==saved.transcript.version {store.updateLecture(lecture.id){if let files=saved.sidecars{$0.sidecars=files};$0.sidecarStatus=saved.fileStatus}}
        return saved
    }
    @discardableResult func apply(_ result:TranslationResult,batch:TranslationBatch,config:TranslationConfig,lecture:Lecture,store:AppStore) async throws -> Bool {
        try await commit(result,batch:batch,config:config,lecture:lecture,store:store).complete
    }
    func retryIDs(_ transcript:Transcript?) -> Set<String>? {
        guard let transcript,let attempt=transcript.attempts?.last,attempt.outcome != "完成",let ids=attempt.targetIDs else { return nil }
        return Set(ids.filter { transcript.translations[$0] == nil })
    }
    func cancel(){task?.cancel()}
    func cancelQueued(_ id:UUID,store:AppStore) {
        if running {pause();return}
        guard let lesson=store.library.lectures.first(where:{$0.id==id}),var record=states[id] else{return}
        record.state="已取消";do{try saveTask(record,lesson:lesson,store:store)}catch{store.error=error.localizedDescription}
    }
}
struct APISettings: View {
    @ObservedObject private var keyAvailability=KeychainAvailability.shared
    @ObservedObject var store:AppStore
    @ObservedObject var job:TranslationJob
    @AppStorage("translationAutomaticModel") var automaticModel=false
    @AppStorage("model") var model = TranslationModelCatalog.defaultID
    @AppStorage("effort") var effort = ReasoningEffort.none.rawValue
    @AppStorage("translationService") var service = "openAI"
    @AppStorage("azureRegion") var region = "global"
    @AppStorage("translationAccelerated") var accelerated=false
    @AppStorage("translationSingleCue") var single=false
    @LPState private var keyRevision=UUID()
    @LPState var key="";@LPState var status="";@LPState var account:DeepLAccountUsage?;@LPState var loadingUsage=false
    var provider:TranslationService {TranslationService(rawValue:service) ?? .openAI}
    var body:some View {
        Section("服务与模型") {
            Picker("翻译服务",selection:$service){ForEach(TranslationService.allCases,id: \.self){Text($0.title).tag($0.rawValue)}}
            if provider == .openAI {
                Toggle("自动·均衡",isOn:$automaticModel)
                if automaticModel {Text("字幕翻译：GPT-5.6 Luna · none；确认后固定，不自动升级。").font(.caption)}
                Picker("模型",selection:$model){if TranslationModelCatalog.find(model)==nil {Text(model+"（需检查）").tag(model)};ForEach(TranslationModelCatalog.models){Text($0.displayName).tag($0.id)}}.disabled(automaticModel)
                if TranslationModelCatalog.find(model)?.supportsReasoning==true {Picker("推理强度",selection:$effort){ForEach(TranslationModelCatalog.find(model)?.supportedEfforts ?? [.none],id: \.self){Text($0.displayName).tag($0.rawValue)}}.disabled(automaticModel)}
            } else if provider == .azure {
                Text("Standard · 英文 → 简体中文")
                Picker("资源区域",selection:Binding(get:{AzureRegion.selection(region)},set:{region = $0 == "other" ? "" : $0})) {
                    Text("Global").tag("global")
                    Text("Australia East（澳大利亚东部）").tag("australiaeast")
                    Text("其他区域").tag("other")
                }
                if AzureRegion.selection(region) == "other" {
                    TextField("Azure 区域代码",text:$region).onSubmit{if let normalized=try? AzureRegion.normalize(region){region=normalized}}
                }
                Text("请选择创建 Azure 资源时使用的区域，与电脑所在地无关。").font(.caption)
                if (try? AzureRegion.normalize(region)) == nil {Text("请输入有效区域代码，例如 australiaeast。").font(.caption).foregroundStyle(.red)}
                Text("请使用公共 Translator F0 资源。F0 每月有 200 万字符额度；应用无法核验账户套餐或剩余额度。不会自动改用收费服务。").font(.caption).foregroundStyle(.secondary)
                Link("Azure 套餐与价格",destination:URL(string:"https://azure.microsoft.com/en-us/pricing/details/translator/")!)
            }
            if provider == .deepL {
                Text("仅支持 DeepL API Free，英文 → 简体中文。额度以账户为准；不自动切换付费端点。").font(.caption)
                Button(loadingUsage ? "正在读取…" : "刷新 DeepL 账户用量") {loadingUsage=true;Task {defer{loadingUsage=false};do{let api=DeepLProvider(key:try Keychain.read(.deepL));account=try await api.accountUsage();status=""}catch{status=error.localizedDescription}}}.disabled(loadingUsage || !keyAvailability.configured(.deepL))
                if let account {Text("账户已用 \(account.characters) / \(account.limit) 字符 · \(account.date.formatted())").font(.caption)}
            }
            if provider == .apple {Text("使用设备语言模型，无云 API 费用。首次翻译可能需要在系统提示中下载英文和简体中文资源。macOS 15 起可用；缺少资源或失败时不会改用云服务。").font(.caption)}
            if provider.needsKey {
            SecureField("API Key（仅存 Keychain）",text:$key)
            HStack {
                Button("保存 Key"){do{try Keychain.save(key.trimmingCharacters(in:.whitespacesAndNewlines),provider:provider);key="";keyRevision=UUID();status="已保存"}catch{status=error.localizedDescription}}.disabled(key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Button("删除 Key"){do{try Keychain.remove(provider);keyRevision=UUID();status="已删除"}catch{status=error.localizedDescription}}
                Text(keyAvailability.values[provider] == nil ? "正在检查…" : keyAvailability.configured(provider) ? "已配置" : "未配置").foregroundStyle(.secondary)
            }
            }
            if !status.isEmpty {Text(status).font(.caption)}
            ServiceTestControls(store:store,job:job,config:TranslationPreferences.load(.standard),unsavedKey:!key.isEmpty,keyRevision:keyRevision)
        }
        .onChange(of:service){_,_ in key="";status="";account=nil}
        Section("速度") {
            Toggle("加速翻译（最多两个请求）",isOn:$accelerated).disabled(provider != .openAI)
            Text("默认逐组处理。加速仅用于 OpenAI；暂停后等待已发送请求保存，它们仍可能计费。Azure 按免费套餐速率调度。").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("高级") {Toggle("逐条处理字幕（较慢）",isOn:$single).disabled(provider != .openAI);Text("只影响新任务；已有任务继续使用确认时的服务、模型和范围。").font(.caption)}
        }
    }
}
