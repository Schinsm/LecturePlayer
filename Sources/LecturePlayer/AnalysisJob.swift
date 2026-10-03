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
    @Published private(set) var status = ""
    @Published private(set) var revision = 0
    private(set) var worker: Task<Void, Never>?
    var onPause:(()->Void)?
    private var loadTokens: [UUID: UUID] = [:]
    private var lessonRevisions: [UUID: Int] = [:]

    var running: Bool { runningLessonID != nil }
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
        onPause?();pauseRequested = true
        status = "正在收尾：保存已发送请求的结果，然后暂停。"
    }
    func cancel() { pauseRequested = true; worker?.cancel() }

    /// Only called after explicit confirmation. Provider injection keeps tests offline.
    func launch(store: AppStore, lessonID: UUID, proposed: AnalysisTaskState, provider: any AnalysisProvider, coordinated: Bool = false) throws {
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
        store.translation.analyzing = true
        status = "准备生成课程总结与章节…"
        worker = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer {
                self.runningLessonID = nil; self.runningVersion = nil; self.worker = nil
                store.translation.analyzing = false; store.translation.testRevision += 1
            }
            await self.execute(store: store, lessonID: lessonID, proposed: proposed, provider: provider)
        }
    }

    private func persist(_ record: LessonAnalysis, repository: AnalysisRepository) async throws {
        try await repository.save(record)
        records[Self.key(record.lessonID, record.sourceVersion)] = record
        loadErrors[record.lessonID] = nil
        lessonRevisions[record.lessonID, default: 0] += 1; revision += 1
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
        do {
            // The frozen scope is durable before the first paid request.
            try await persist(record, repository: repository)
            for chunk in progress.pendingChunks {
                if pauseRequested || Task.isCancelled { break }
                try currentVersion(store, lessonID, record.sourceVersion)
                status = "正在分析第 \(progress.completedChunks.count + 1)/\(progress.plan.chunks.count) 组原文…"
                let started = Date()
                let response: AnalysisResponse<[AnalysisChapter]>
                do { response = try await provider.analyze(chunk, config: progress.config.forStage("analysis")) }
                catch let error as AnalysisNotSent { throw error }
                catch { response = AnalysisResponse(value: nil, result: failureResult(error)) }
                var attempt = try AnalysisAttempt(stage: chunk.id, config: progress.config.forStage("analysis"), result: response.result,
                                              requestSeconds: Date().timeIntervalSince(started), outcome: "received")
                record.attempts.append(attempt)
                // Usage is recorded even when the response or its chapter boundaries fail validation.
                try await persist(record, repository: repository)
                let checked = Date()
                do {
                    try currentVersion(store, lessonID, record.sourceVersion)
                    guard response.result.problem == nil, let chapters = response.value else {
                        throw Failure(response.result.problem ?? "服务没有返回完整章节，本组尚未保存。")
                    }
                    try AnalysisValidation.block(chapters, chunk: chunk)
                    progress.completedChunks[chunk.id] = chapters
                    attempt.outcome = "completed"
                    attempt.validationSeconds = Date().timeIntervalSince(checked)
                    record.attempts[record.attempts.count - 1] = attempt
                    record.task = progress
                    try await persist(record, repository: repository)
                } catch {
                    onPause?()
                    attempt.outcome = Task.isCancelled ? "cancelled" : "failed"
                    attempt.message = error.localizedDescription; attempt.validation = attempt.validation ?? (error as? AnalysisValidationFailure)?.detail ?? AnalysisValidationDetail(code:"validation")
                    attempt.validationSeconds = Date().timeIntervalSince(checked)
                    record.attempts[record.attempts.count - 1] = attempt
                    progress.status = Task.isCancelled ? .paused : .failed; progress.message = error.localizedDescription
                    record.task = progress
                    try await persist(record, repository: repository)
                    status = "已保留完成的分析，可确认后继续。" + error.localizedDescription
                    return
                }
            }
            if pauseRequested || Task.isCancelled {
                progress.status = .paused; progress.message = "已暂停；继续时只处理未完成内容。"
                record.task = progress; try await persist(record, repository: repository)
                status = "已暂停，完成的分析已保存。"; return
            }
            try currentVersion(store, lessonID, record.sourceVersion)
            status = "正在整理相邻主题与整课总结…"
            let started = Date()
            let response: AnalysisResponse<AnalysisDocument>
            do { response = try await provider.synthesize(progress.proposedChapters, config: progress.config.forStage("synthesis")) }
            catch let error as AnalysisNotSent { throw error }
            catch { response = AnalysisResponse(value: nil, result: failureResult(error)) }
            var attempt = try AnalysisAttempt(stage: "synthesis", config: progress.config.forStage("synthesis"), result: response.result,
                                          requestSeconds: Date().timeIntervalSince(started), outcome: "received")
            record.attempts.append(attempt); try await persist(record, repository: repository)
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
                onPause?()
                attempt.outcome = Task.isCancelled ? "cancelled" : "failed"; attempt.message = error.localizedDescription; attempt.validation = attempt.validation ?? (error as? AnalysisValidationFailure)?.detail ?? AnalysisValidationDetail(code:"validation")
                attempt.validationSeconds = Date().timeIntervalSince(checked)
                record.attempts[record.attempts.count - 1] = attempt
                progress.status = Task.isCancelled ? .paused : .failed; progress.message = error.localizedDescription
                record.task = progress; try await persist(record, repository: repository)
                status = "分块分析已保存，最后整理未完成。继续时只处理整理步骤。" + error.localizedDescription
            }
        } catch {
            onPause?()
            progress.status = Task.isCancelled ? .paused : .failed; progress.message = error.localizedDescription; record.task = progress
            // Best effort only; a storage failure never causes another network request.
            do { try await persist(record, repository: repository) } catch { }
            status = "任务已停止：" + (progress.message ?? "保存未完成。")
            if !(error is AnalysisNotSent) { store.error = status }
        }
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
