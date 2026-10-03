import Foundation

/// Analysis has its own frozen configuration and never changes the translation task or selected variant.
public struct AnalysisConfig: Codable, Equatable, Sendable {
    public var resolvedModels: ResolvedModelPlan?
    public var protocolVersion: Int?
    public var model: String
    public var effort: String
    public var outputLimit: Int
    public init(model: String, effort: String = "none", outputLimit: Int = 6000) {
        self.model = model; self.effort = effort; self.outputLimit = outputLimit
    }
    public var translationConfig: TranslationConfig { var value=TranslationConfig(model:model,effort:effort);value.resolvedModels=resolvedModels;return value }
    public func validate() throws {
        let descriptor = try translationConfig.descriptor()
        try resolvedModels?.validate()
        guard (1...3).contains(protocolVersion ?? 1), outputLimit <= descriptor.maximumOutputTokens else {throw Failure("总结协议或输出上限不受支持")}
        guard (1...12000).contains(outputLimit) else { throw Failure("总结输出上限无效") }
    }
}
public struct AnalysisChunk: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var targets: [Cue]
    public var contextBefore: [Cue]
    public var contextAfter: [Cue]
    public init(id: String, targets: [Cue], contextBefore: [Cue] = [], contextAfter: [Cue] = []) {
        self.id=id; self.targets=targets; self.contextBefore=contextBefore; self.contextAfter=contextAfter
    }
}
public struct AnalysisPlan: Codable, Equatable, Sendable {
    public var sourceVersion: String
    public var sourceCueIDs: [String]
    public var chunks: [AnalysisChunk]
    public var estimatedRequests: Int { chunks.count + 1 }
    public static func make(_ transcript: Transcript) throws -> AnalysisPlan {
        try transcript.validate()
        guard !transcript.cues.isEmpty else { throw Failure("请先添加带时间戳的 VTT 或 SRT 英文字幕") }
        let cues = ordered(transcript.cues)
        var ranges: [Range<Int>] = [], start = 0, bytes = 0
        for i in cues.indices {
            // A single long cue remains intact. A large gap starts a new analysis block.
            if i > start && (i-start >= 1000 || bytes + cues[i].en.utf8.count > 12000 || cues[i].end - cues[start].start > 600000 || cues[i].start - cues[i-1].end > 60000) {
                ranges.append(start..<i); start=i; bytes=0
            }
            bytes += cues[i].en.utf8.count
        }
        ranges.append(start..<cues.count)
        let chunks = ranges.enumerated().map { index, range -> AnalysisChunk in
            let first=cues[range.lowerBound], last=cues[range.upperBound-1]
            let before=cues[..<range.lowerBound].filter { $0.start >= first.start - 60000 }
            let after=cues[range.upperBound...].filter { $0.end <= last.end + 60000 }
            return AnalysisChunk(id: String(format:"block-%04d",index+1), targets: Array(cues[range]), contextBefore: before, contextAfter: after)
        }
        return AnalysisPlan(sourceVersion: transcript.version, sourceCueIDs: cues.map(\.id), chunks: chunks)
    }
    public static func ordered(_ cues: [Cue]) -> [Cue] {
        cues.enumerated().sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }.map(\.element)
    }
    public func estimate(config: AnalysisConfig, remainingChunkIDs: Set<String>? = nil, includeSynthesis: Bool = true) -> String {
        let pending=chunks.filter { remainingChunkIDs == nil || remainingChunkIDs!.contains($0.id) }
        let requests=pending.count + (includeSynthesis ? 1 : 0)
        guard let analysisPrice=config.forStage("analysis").translationConfig.pricingSnapshot,
              let synthesisPrice=config.forStage("synthesis").translationConfig.pricingSnapshot else {return "预计 \(requests) 次请求；价格未记录，无法可靠估算费用。"}
        let analysisInput=pending.reduce(0) {sum,chunk in sum+1000+(chunk.targets+chunk.contextBefore+chunk.contextAfter).reduce(0){$0+($1.en.utf8.count+80)/3}}
        let synthesisInput=includeSynthesis ? 1000+chunks.count*400 : 0
        let synthesisOutput=includeSynthesis ? max(1200,chunks.count*400) : 0
        let cost=analysisPrice.estimate(input:analysisInput,output:pending.count*900)+synthesisPrice.estimate(input:synthesisInput,output:synthesisOutput)
        return "预计 \(requests) 次请求，输入约 \(analysisInput+synthesisInput) / 可见输出约 \(pending.count*900+synthesisOutput) tokens，约 $\(String(format:"%.4f",cost)) USD。价格日期 \(analysisPrice.checkedDate) / \(synthesisPrice.checkedDate)；推理用量不确定，实际费用可能更高。这不是费用上限。"
    }
    public func validate() throws {
        let cues=chunks.flatMap(\.targets)
        guard !sourceVersion.isEmpty, !chunks.isEmpty, Set(chunks.map(\.id)).count==chunks.count,
              !cues.isEmpty, Set(cues.map(\.id)).count==cues.count, cues.map(\.id)==sourceCueIDs,
              Self.ordered(cues).map(\.id)==sourceCueIDs,
              chunks.allSatisfy({!$0.targets.isEmpty}), cues.allSatisfy({$0.start >= 0 && $0.end > $0.start && !$0.en.isEmpty}) else { throw Failure("总结任务的字幕范围无效") }
    }
}
public struct AnalysisChapter: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var startCueID: String
    public var endCueID: String
    public var title: String
    public var points: [String]
    public var memberCueIDs: [String]?
    public var sourceStartMilliseconds: Int?
    public var sourceEndMilliseconds: Int?
    public init(id: String, startCueID: String, endCueID: String, title: String, points: [String]) {
        self.id=id; self.startCueID=startCueID; self.endCueID=endCueID; self.title=title; self.points=points
    }
}
public struct AnalysisOverviewPoint: Codable, Equatable, Sendable {
    public var text: String
    public var chapterID: String
    public init(text: String, chapterID: String) { self.text=text; self.chapterID=chapterID }
}
public struct AnalysisDocument: Codable, Equatable, Sendable {
    public var topics: [AnalysisTopic]?
    public var chapters: [AnalysisChapter]
    public var overview: [AnalysisOverviewPoint]
    public init(chapters: [AnalysisChapter], overview: [AnalysisOverviewPoint]) { self.chapters=chapters; self.overview=overview }
}
public enum AnalysisTaskStatus: String, Codable, Sendable { case running, paused, failed }
public struct AnalysisTaskState: Codable, Equatable, Sendable {
    public var config: AnalysisConfig
    public var plan: AnalysisPlan
    public var completedChunks: [String:[AnalysisChapter]] = [:]
    public var status: AnalysisTaskStatus = .paused
    public var message: String?
    public var createdAt = Date()
    public init(config: AnalysisConfig, plan: AnalysisPlan) { self.config=config; self.plan=plan }
    public var pendingChunks: [AnalysisChunk] { plan.chunks.filter { completedChunks[$0.id] == nil } }
    public var proposedChapters: [AnalysisChapter] { plan.chunks.flatMap { completedChunks[$0.id] ?? [] } }
    public func compactContinuation() throws -> Self {
        try validate()
        var next=self
        for chunk in plan.chunks {
            guard let chapters=completedChunks[chunk.id] else {continue}
            let indices=Dictionary(uniqueKeysWithValues:chunk.targets.enumerated().map{($0.element.id,$0.offset)})
            next.completedChunks[chunk.id]=try chapters.map { chapter in
                guard let start=indices[chapter.startCueID],let end=indices[chapter.endCueID],end>=start else {throw Failure("已保存知识点范围无效")}
                var copy=chapter;copy.memberCueIDs=Array(chunk.targets[start...end]).map(\.id)
                return copy
            }
        }
        next.config.protocolVersion=3;try next.validate();return next
    }
    public func validate() throws {
        try config.validate(); try plan.validate()
        guard Set(completedChunks.keys).isSubset(of:Set(plan.chunks.map(\.id))), Set(proposedChapters.map(\.id)).count==proposedChapters.count else { throw Failure("总结进度包含未知分块") }
        for chunk in plan.chunks { if let value=completedChunks[chunk.id] { try AnalysisValidation.block(value,chunk:chunk) } }
    }
}
public struct AnalysisAttempt: Codable, Equatable, Sendable, Identifiable {
    public var protocolVersion: Int?
    public var validation: AnalysisValidationDetail?
    public var id: UUID
    public var date: Date
    public var stage: String
    public var outcome: String
    public var message: String?
    public var requestID: String?
    public var requestSeconds: Double?
    public var validationSeconds: Double?
    public var databaseSeconds: Double?
    public var usage: TranslationUsage
    public var diagnostics: TranslationDiagnostics?
    public init(id: UUID = UUID(), stage: String, config: AnalysisConfig, result: TranslationResult, requestSeconds: Double? = nil, outcome: String) throws {
        self.id=id; date=Date(); self.stage=stage; self.outcome=outcome; self.message=result.problem
        protocolVersion=config.protocolVersion ?? 1; validation=result.analysisValidation ?? AnalysisValidationDetail.from(result)
        requestID=result.requestID; self.requestSeconds=requestSeconds; diagnostics=result.diagnostics
        usage=TranslationUsage(result:result,config:config.translationConfig,descriptor:try config.translationConfig.descriptor(),batchKey:"analysis:"+stage)
        usage.attemptID=id
    }
}
public struct LessonAnalysis: Codable, Equatable, Sendable {
    public var schema = 1
    public var lessonID: UUID
    public var sourceVersion: String
    public var completed: AnalysisDocument?
    public var completedConfig: AnalysisConfig?
    public var completedAt: Date?
    public var task: AnalysisTaskState?
    public var attempts: [AnalysisAttempt] = []
    public init(lessonID: UUID, sourceVersion: String) { self.lessonID=lessonID; self.sourceVersion=sourceVersion }
    public func validate(transcript: Transcript? = nil) throws {
        guard (schema==1 || schema==2), !sourceVersion.isEmpty, Set(attempts.map(\.id)).count==attempts.count else { throw Failure("课程总结格式无效或来自更新版本") }
        if let task { guard task.plan.sourceVersion==sourceVersion else { throw Failure("总结任务字幕版本不匹配") }; try task.validate() }
        if let completed { try AnalysisValidation.document(completed); guard completedConfig != nil, completedAt != nil else { throw Failure("总结缺少生成信息") } }
        if let transcript {
            try transcript.validate()
            guard transcript.version==sourceVersion else { throw Failure("总结对应旧字幕，不能用于当前字幕跳转") }
            let ordered=AnalysisPlan.ordered(transcript.cues)
            if let completed { try AnalysisValidation.coverage(completed.chapters,cueIDs:ordered.map(\.id)) }
            if let task { guard task.plan.sourceCueIDs==ordered.map(\.id), task.plan.chunks.flatMap(\.targets)==ordered else { throw Failure("总结任务与原字幕不一致") } }
        }
    }
}
public enum AnalysisValidation {
    private static func nonempty(_ value: String) -> Bool { !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    public static func coverage(_ chapters: [AnalysisChapter], cueIDs: [String]) throws {
        guard !chapters.isEmpty, !cueIDs.isEmpty, Set(cueIDs).count==cueIDs.count, Set(chapters.map(\.id)).count==chapters.count else { throw Failure("章节为空或编号重复") }
        let indices=Dictionary(uniqueKeysWithValues:cueIDs.enumerated().map { ($0.element,$0.offset) })
        var next=0
        for chapter in chapters {
            guard nonempty(chapter.id), nonempty(chapter.title), (chapter.memberCueIDs == nil ? 2...3 : 1...3).contains(chapter.points.count), chapter.points.allSatisfy(nonempty),
                  let start=indices[chapter.startCueID], let end=indices[chapter.endCueID], start==next, end>=start else { throw Failure("章节编号、顺序或覆盖范围不完整，本组尚未保存") }
            if let members=chapter.memberCueIDs, members != Array(cueIDs[start...end]) {throw Failure("知识点原文成员遗漏或重排")}
            next=end+1
        }
        guard next==cueIDs.count else { throw Failure("章节遗漏字幕，本组尚未保存") }
    }
    public static func block(_ chapters: [AnalysisChapter], chunk: AnalysisChunk) throws { try coverage(chapters,cueIDs:chunk.targets.map(\.id)) }
    public static func document(_ document: AnalysisDocument) throws {
        if document.topics != nil {try HierarchicalAnalysis.validateStructure(document)}
        let ids=Set(document.chapters.map(\.id))
        guard !ids.isEmpty, ids.count==document.chapters.count, (1...8).contains(document.overview.count),
              document.chapters.allSatisfy({nonempty($0.id) && nonempty($0.startCueID) && nonempty($0.endCueID) && nonempty($0.title) && ($0.memberCueIDs == nil ? 2...3 : 1...3).contains($0.points.count) && $0.points.allSatisfy(nonempty)}),
              document.overview.allSatisfy({nonempty($0.text) && ids.contains($0.chapterID)}) else { throw Failure("总结内容或章节引用无效") }
    }
    public static func synthesis(_ document: AnalysisDocument, proposed: [AnalysisChapter]) throws {
        try self.document(document)
        if document.topics != nil {try HierarchicalAnalysis.validate(document, proposed: proposed); return}
        guard !proposed.isEmpty, Set(proposed.map(\.startCueID)).count==proposed.count, Set(proposed.map(\.endCueID)).count==proposed.count else { throw Failure("待合并章节范围无效") }
        var next=0
        for chapter in document.chapters {
            guard next<proposed.count, chapter.startCueID==proposed[next].startCueID,
                  let end=proposed[next...].firstIndex(where:{$0.endCueID==chapter.endCueID}) else { throw Failure("总结只能合并相邻章节，不能新增、遗漏或移动边界") }
            next=end+1
        }
        guard next==proposed.count else { throw Failure("总结遗漏章节") }
    }
}
public actor AnalysisRepository {
    public let root: URL
    public init(root: URL) { self.root=root }
    public nonisolated static func fileURL(root: URL, lessonID: UUID, sourceVersion: String) -> URL {
        root.appendingPathComponent("analyses",isDirectory:true).appendingPathComponent(lessonID.uuidString+"-"+digest(sourceVersion)+".json")
    }
    public func load(lessonID: UUID, sourceVersion: String) throws -> LessonAnalysis? {
        let url=Self.fileURL(root:root,lessonID:lessonID,sourceVersion:sourceVersion)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let record=try Codec.decode(LessonAnalysis.self,Data(contentsOf:url)); try record.validate()
        guard record.lessonID==lessonID,record.sourceVersion==sourceVersion else { throw Failure("总结文件身份不一致") }
        return record
    }
    public func save(_ record: LessonAnalysis) throws {
        try record.validate()
        let url=Self.fileURL(root:root,lessonID:record.lessonID,sourceVersion:record.sourceVersion)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Codec.encode(record).write(to:url,options:.atomic)
    }
    public func all(lessonID: UUID? = nil) throws -> [LessonAnalysis] { try Self.readAll(root:root).filter { lessonID == nil || $0.lessonID==lessonID } }
    public nonisolated static func readAll(root: URL) throws -> [LessonAnalysis] {
        let folder=root.appendingPathComponent("analyses",isDirectory:true)
        guard FileManager.default.fileExists(atPath:folder.path) else { return [] }
        let urls=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        return try urls.map { url in
            let value=try Codec.decode(LessonAnalysis.self,Data(contentsOf:url)); try value.validate()
            guard url.lastPathComponent==fileURL(root:root,lessonID:value.lessonID,sourceVersion:value.sourceVersion).lastPathComponent else { throw Failure("总结文件名与身份不一致") }
            return value
        }
    }
}
public enum AnalysisMarkdown {
    public static func export(_ record: LessonAnalysis, transcript: Transcript, offset: Double = 0, title: String) throws -> String {
        try record.validate(transcript:transcript)
        guard let document=record.completed else { throw Failure("课程总结尚未完成") }
        let cues=Dictionary(uniqueKeysWithValues:transcript.cues.map{($0.id,$0)}), mapper=SubtitleTimingMapper(offset:offset)
        var lines=["# \(title) — 总结与章节","", "根据英文字幕生成；未分析视频画面。请结合原文核对。", "字幕版本：\(record.sourceVersion)", "播放校准：\(String(format:"%+.3f",offset)) 秒（原字幕时间不变）", "", "## 核心要点", ""]
        let chapterIndices=Dictionary(uniqueKeysWithValues:document.chapters.enumerated().map{($0.element.id,$0.offset+1)})
        for point in document.overview { lines.append("- \(point.text)（章节 \(chapterIndices[point.chapterID]!)）") }
        if let topics = document.topics {
            for topic in topics {
                lines += ["", "## " + topic.title, topic.overview, ""]
                for child in topic.subtopics {
                    guard let start=cues[child.startCueID],let end=cues[child.endCueID] else {throw Failure("知识点原文不存在")}
                    lines += ["### \(timeLabel(mapper.seekTarget(start)))–\(timeLabel(max(0,mapper.effectiveTime(milliseconds:end.end)))) · \(child.title)"]
                    lines += child.points.map {"- " + $0}
                    lines += ["原文：" + (child.memberCueIDs ?? []).joined(separator:", "), ""]
                }
            }
            return lines.joined(separator:"\n")
        }
        lines += ["", "## 章节", ""]
        for chapter in document.chapters {
            let start=cues[chapter.startCueID]!, end=cues[chapter.endCueID]!
            lines += ["### \(timeLabel(mapper.seekTarget(start)))–\(timeLabel(max(0,mapper.effectiveTime(milliseconds:end.end)))) · \(chapter.title)", ""]
            for point in chapter.points { lines.append("- "+point) }
            lines += ["", "原文范围：\(chapter.startCueID) → \(chapter.endCueID)", ""]
        }
        return lines.joined(separator:"\n")
    }
}
