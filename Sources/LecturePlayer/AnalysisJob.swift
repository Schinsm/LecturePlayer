import Foundation
import SwiftUI
import Core

/// Analysis has its own saved task and never reuses a translation variant or changes a cue.
@MainActor final class AnalysisJob: ObservableObject {
    @Published private(set) var records: [String: LessonAnalysis] = [:]
    @Published private(set) var loadErrors: [UUID: String] = [:]
    @Published private(set) var runningLessonID: UUID?
    @Published private(set) var runningVersion: String?
    @Published private(set) var pauseRequested = false
    @Published private(set) var status = "" {didSet {onStatus?(status)}}
    var onStatus:((String)->Void)?
    @Published var lessonStatuses:[UUID:String]=[:]
    func status(for id:UUID?) -> String {id.flatMap{lessonStatuses[$0]} ?? status}
    @Published private(set) var revision = 0
    private(set) var worker: Task<Void, Never>?
    var onPause:(()->Void)?
    var onRecord:((LessonAnalysis)->Void)?
    var scheduler:RequestScheduler?
    @Published var coordinatedLessons:Set<UUID>=[]
    func pauseRequestedForQueue(_ value:Bool) {pauseRequested=value}
    func isRunning(_ id:UUID?) -> Bool {id != nil && (runningLessonID==id || coordinatedLessons.contains(id!))}
    func accept(_ record:LessonAnalysis) {records[Self.key(record.lessonID,record.sourceVersion)]=record;lessonRevisions[record.lessonID,default:0] += 1;revision += 1}
    private var loadTokens: [UUID: UUID] = [:]
    private var lessonRevisions: [UUID: Int] = [:]

    /// A restored library must not inherit records or delayed reads from the previous library.
    func resetPresentation() {
        guard !running else{return}
        records=[:];loadErrors=[:];loadTokens=[:];lessonRevisions=[:];lessonStatuses=[:]
        runningVersion=nil;status="";pauseRequested=false;revision += 1
    }
    var running: Bool { runningLessonID != nil || !coordinatedLessons.isEmpty }
    static func key(_ id: UUID, _ version: String) -> String { "\(id.uuidString)-\(version)" }
    func exact(_ id: UUID, version: String) -> LessonAnalysis? { records[Self.key(id, version)] }
    func visible(_ id: UUID, version: String) -> LessonAnalysis? {
        if let record = exact(id, version: version), record.completed != nil || record.task != nil { return record }
        return records.values.filter { $0.lessonID == id && $0.completed != nil }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }.first
    }
    func load(store: AppStore, lessonID: UUID) async {
        guard let root = store.repository?.root else { return }
        let token = UUID(), startingRevision = lessonRevisions[lessonID, default: 0]
        loadTokens[lessonID] = token
        do {
            let saved = try await AnalysisRepository(root: root).all(lessonID: lessonID)
            guard loadTokens[lessonID] == token, lessonRevisions[lessonID, default: 0] == startingRevision else { return }
            loadErrors[lessonID] = nil
            records = records.filter { $0.value.lessonID != lessonID }
            for record in saved { records[Self.key(record.lessonID, record.sourceVersion)] = record }
            lessonRevisions[lessonID, default: 0] += 1; revision += 1
        } catch {
            guard loadTokens[lessonID] == token, lessonRevisions[lessonID, default: 0] == startingRevision else { return }
            loadErrors[lessonID] = "无法读取课程总结：" + error.localizedDescription
        }
    }
    func pause() {
        guard running else { return }
        onPause?();if let scheduler {Task {await scheduler.pause()}};pauseRequested = true
        status = "正在收尾：保存已发送请求的结果，然后暂停。"
    }
    func cancel() { pauseRequested = true; worker?.cancel() }

    /// Only called after explicit confirmation. Provider injection keeps tests offline.
    func launch(store: AppStore, lessonID: UUID, proposed: AnalysisTaskState, provider: any AnalysisProvider, coordinated: Bool = false) throws {
        if !coordinated,store.processing.running {
            try store.processing.launch([ImportProcessingEntry(id:lessonID,translation:nil,analysis:proposed)],store:store)
            return
        }
        guard !running, !store.translation.testing, (!store.translation.busy || coordinated) else {
            throw Failure("请等待当前翻译、总结或连接测试结束。")
        }
        try proposed.validate()
        guard let lesson = store.library.lectures.first(where: { $0.id == lessonID }),
              let source = try store.repository?.read(lesson), source.version == proposed.plan.sourceVersion,
              AnalysisPlan.ordered(source.cues).map(\.id) == proposed.plan.sourceCueIDs else {
            throw Failure("英文字幕已变化，请重新确认总结范围。")
        }
        guard proposed.plan == (try AnalysisPlan.make(source)) else {
            throw Failure("保存的总结范围与英文字幕不一致，请重新确认。")
        }
        runningLessonID = lessonID; runningVersion = source.version; pauseRequested = false
        scheduler=store.requests
        if !coordinated {store.translation.analyzing = true}
        status = "准备生成课程总结与章节…"
        worker = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer {
                self.runningLessonID = nil; self.runningVersion = nil; self.worker = nil
                if !coordinated {store.translation.analyzing = false}; store.translation.testRevision += 1
            }
            if !coordinated {await store.requests.resume()}
            await self.execute(store: store, lessonID: lessonID, proposed: proposed, provider: provider)
        }
    }

    private func persist(_ record: LessonAnalysis, repository: AnalysisRepository) async throws {
        let started=Date();try await repository.save(record);PerformanceTrace.record("analysis.commit",Date().timeIntervalSince(started))
        records[Self.key(record.lessonID, record.sourceVersion)] = record
        loadErrors[record.lessonID] = nil
        lessonRevisions[record.lessonID, default: 0] += 1; revision += 1;onRecord?(record)
    }
    private func currentVersion(_ store: AppStore, _ lessonID: UUID, _ version: String) throws {
        guard store.library.lectures.first(where: { $0.id == lessonID })?.transcriptVersion == version else {
            throw Failure("英文字幕已更换，本次结果未用于新字幕；请重新确认。")
        }
    }
    private func failureResult(_ error: Error) -> TranslationResult {
        if let result = (error as? APIError)?.result { return result }
        return TranslationResult(items: [], problem: error is CancellationError || (error as? URLError)?.code == .cancelled
            ? "请求已取消，用量未知；已发送请求仍可能计费。" : error.localizedDescription)
    }
    private func execute(store: AppStore, lessonID: UUID, proposed: AnalysisTaskState, provider: any AnalysisProvider) async {
        guard let root = store.repository?.root else { status = "资料库不可用，未发送请求。"; return }
        let repository = AnalysisRepository(root: root)
        var record: LessonAnalysis
        do { record = try await repository.load(lessonID: lessonID, sourceVersion: proposed.plan.sourceVersion)
                ?? LessonAnalysis(lessonID: lessonID, sourceVersion: proposed.plan.sourceVersion) }
        catch {
            status = "无法读取已保存任务，未发送请求：" + error.localizedDescription
            loadErrors[lessonID] = status; return
        }
        var progress = proposed
        progress.status = .running; progress.message = nil
        record.task = progress
        var synthesisLease:RequestScheduler.Lease?
        do {
            // The frozen scope is durable before the first paid request.
            try await persist(record, repository: repository)
            struct Completed:Sendable {
                let chunk:AnalysisChunk;let response:AnalysisResponse<[AnalysisChapter]>?
                let lease:RequestScheduler.Lease?;let seconds:Double;var notSent:String?=nil
            }
            let pending=progress.pendingChunks,config=progress.config.forStage("analysis"),sourceVersion=record.sourceVersion
            var cursor=0,failed=false
            await withTaskGroup(of:Completed.self) {group in
                @MainActor func dispatch() {
                    guard !pauseRequested,!failed,!Task.isCancelled,cursor<pending.count else{return}
                    let chunk=pending[cursor];cursor += 1
                    group.addTask {
                        let lease:RequestScheduler.Lease
                        do {lease=try await store.requests.acquire(lesson:lessonID)}
                        catch {return Completed(chunk:chunk,response:nil,lease:nil,seconds:0)}
                        do {try await self.currentVersion(store,lessonID,sourceVersion)}
                        catch {await store.requests.pause();await store.requests.release(lease);return Completed(chunk:chunk,response:nil,lease:nil,seconds:0,notSent:error.localizedDescription)}
                        let start=Date();let response:AnalysisResponse<[AnalysisChapter]>
                        do {try Task.checkCancellation();response=try await provider.analyze(chunk,config:config)}
                        catch let error as AnalysisNotSent {await store.requests.pause();await store.requests.release(lease);return Completed(chunk:chunk,response:nil,lease:nil,seconds:0,notSent:error.localizedDescription)}
                        catch {response=AnalysisResponse(value:nil,result:await self.failureResult(error))}
                        return Completed(chunk:chunk,response:response,lease:lease,seconds:Date().timeIntervalSince(start))
                    }
                }
                dispatch();dispatch()
                while let done=await group.next() {
                    guard let response=done.response else {if let error=done.notSent {failed=true;progress.message=error;onPause?()} else {pauseRequested=true};continue}
                    do {
                        var attempt=try AnalysisAttempt(stage:done.chunk.id,config:config,result:response.result,requestSeconds:done.seconds,outcome:"completed")
                        attempt.queueSeconds=done.lease?.queueSeconds
                        let checked=Date()
                        do {
                            try currentVersion(store,lessonID,record.sourceVersion)
                            guard response.result.problem==nil,let chapters=response.value else {throw Failure(response.result.problem ?? "服务未返回完整章节")}
                            try AnalysisValidation.block(chapters,chunk:done.chunk)
                            progress.completedChunks[done.chunk.id]=chapters
                        } catch {
                            failed=true;attempt.outcome=Task.isCancelled ? "cancelled":"failed";attempt.message=error.localizedDescription
                            attempt.validation=attempt.validation ?? (error as? AnalysisValidationFailure)?.detail ?? AnalysisValidationDetail(code:"validation")
                            progress.message=error.localizedDescription;onPause?();await store.requests.pause()
                        }
                        attempt.validationSeconds=Date().timeIntervalSince(checked)
                        record.attempts.append(attempt);record.task=progress
                        let saving=Date();try await persist(record,repository:repository)
                        // Carried into the next atomic checkpoint (including final pause/synthesis).
                        record.attempts[record.attempts.count-1].databaseSeconds=Date().timeIntervalSince(saving)
                        status="已保存 \(progress.completedChunks.count)/\(progress.plan.chunks.count) 组分析"
                    } catch {failed=true;progress.message=error.localizedDescription;onPause?();await store.requests.pause()}
                    if pauseRequested || Task.isCancelled {await store.requests.pause()}
                    if let lease=done.lease {await store.requests.release(lease)}
                    dispatch()
                }
            }
            if failed {
                progress.status = Task.isCancelled ? .paused:.failed;record.task=progress;try await persist(record,repository:repository)
                status="已保留完成的分析，可确认后继续。"+(progress.message ?? "")
                return
            }
            if pauseRequested || Task.isCancelled {
                progress.status = .paused; progress.message = "已暂停；继续时只处理未完成内容。"
                record.task = progress; try await persist(record, repository: repository)
                status = "已暂停，完成的分析已保存。"; return
            }
            try currentVersion(store, lessonID, record.sourceVersion)
            status = "正在整理相邻主题与整课总结…"
            let lease=try await store.requests.acquire(lesson:lessonID)
            synthesisLease=lease
            try currentVersion(store,lessonID,record.sourceVersion)
            let started = Date()
            let response: AnalysisResponse<AnalysisDocument>
            do { response = try await provider.synthesize(progress.proposedChapters, config: progress.config.forStage("synthesis")) }
            catch let error as AnalysisNotSent { throw error }
            catch { response = AnalysisResponse(value: nil, result: failureResult(error)) }
            var attempt = try AnalysisAttempt(stage: "synthesis", config: progress.config.forStage("synthesis"), result: response.result,
                                          requestSeconds: Date().timeIntervalSince(started), outcome: "received")
            attempt.queueSeconds=lease.queueSeconds
            record.attempts.append(attempt)
            let checked = Date()
            do {
                try currentVersion(store, lessonID, record.sourceVersion)
                guard response.result.problem == nil, let document = response.value else {
                    throw Failure(response.result.problem ?? "服务没有返回完整总结；原分析结果已保留。")
                }
                try AnalysisValidation.synthesis(document, proposed: progress.proposedChapters)
                attempt.outcome = "completed"; attempt.validationSeconds = Date().timeIntervalSince(checked)
                record.attempts[record.attempts.count - 1] = attempt
                // Keep the old completed document through every partial or failed regeneration.
                record.schema = document.topics == nil ? 1 : 2; record.completed = document; record.completedConfig = progress.config; record.completedAt = Date(); record.task = nil
                try await persist(record, repository: repository)
                status = "本课总结与章节已完成。"
            } catch {
                onPause?();await store.requests.pause()
                attempt.outcome = Task.isCancelled ? "cancelled" : "failed"; attempt.message = error.localizedDescription; attempt.validation = attempt.validation ?? (error as? AnalysisValidationFailure)?.detail ?? AnalysisValidationDetail(code:"validation")
                attempt.validationSeconds = Date().timeIntervalSince(checked)
                record.attempts[record.attempts.count - 1] = attempt
                progress.status = Task.isCancelled ? .paused : .failed; progress.message = error.localizedDescription
                record.task = progress; try await persist(record, repository: repository)
                status = "分块分析已保存，最后整理未完成。继续时只处理整理步骤。" + error.localizedDescription
            }
        } catch {
            onPause?();await store.requests.pause()
            progress.status = Task.isCancelled ? .paused : .failed; progress.message = error.localizedDescription; record.task = progress
            // Best effort only; a storage failure never causes another network request.
            do { try await persist(record, repository: repository) } catch { }
            status = "任务已停止：" + (progress.message ?? "保存未完成。")
            if !(error is AnalysisNotSent) && !(error is RequestNotDispatched) { store.error = status }
        }
        if let lease=synthesisLease {await store.requests.release(lease)}
    }
}

/// Separate preferences: changing the translation service/model does not alter an approved task.
enum AnalysisPreferences {
    static func load(_ defaults: UserDefaults = .standard) -> AnalysisConfig {
        var config = AnalysisConfig(model: defaults.string(forKey: "analysisModel") ?? defaults.string(forKey: "model") ?? TranslationModelCatalog.defaultID,
                       effort: defaults.string(forKey: "analysisEffort") ?? defaults.string(forKey: "effort") ?? "none")
        config.protocolVersion=3
        config.resolvedModels=ResolvedModelPlan.analysis(config,automatic:defaults.bool(forKey:"analysisAutomaticModel"))
        return config.forStage("analysis")
    }
    static func save(_ config: AnalysisConfig, defaults: UserDefaults = .standard) {
        guard config.resolvedModels?.mode != "balanced" else {return}
        defaults.set(config.model, forKey: "analysisModel"); defaults.set(config.effort, forKey: "analysisEffort")
    }
}
