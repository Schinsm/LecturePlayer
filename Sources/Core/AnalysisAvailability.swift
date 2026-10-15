import Foundation

public struct AnalysisAvailability:Equatable,Sendable {
    public enum State:String,Sendable {case notGenerated,queued,generating,paused,failed,completed,oldSource}
    public var state:State
    public var reason:String?
    public var label:String {
        switch state {
        case .notGenerated:return "未生成章节"
        case .queued:return "章节排队中"
        case .generating:return "章节生成中"
        case .paused:return "章节已暂停"
        case .failed:return "章节生成失败"
        case .completed:return "章节已生成"
        case .oldSource:return "对应旧字幕"
        }
    }
    public var action:String {
        switch state {
        case .paused,.failed:return "继续生成章节…"
        case .completed:return "重新生成章节…"
        case .queued,.generating:return "查看任务"
        default:return "生成章节…"
        }
    }
    public init(saved:SavedAnalysisSummary?,hasOlder:Bool=false,queued:Bool=false,running:Bool=false,queuePaused:Bool=false,hasTimedSource:Bool=true,readError:String?=nil,keyConfigured:Bool?=nil,modelAvailable:Bool=true,serviceTest:Bool=false) {
        if running {state = .generating}
        else if queued {state = queuePaused ? .paused:.queued}
        else if saved?.taskStatus == .failed || readError != nil {state = .failed}
        else if saved?.taskStatus != nil {state = .paused}
        else if saved?.complete == true {state = .completed}
        else if hasOlder {state = .oldSource}
        else {state = .notGenerated}
        reason=readError
        if reason==nil && !hasTimedSource {reason="先添加带时间戳的英文字幕（VTT / SRT）。"}
        if reason==nil && keyConfigured==false {reason="请在设置中保存 OpenAI Key。"}
        if reason==nil && !modelAvailable {reason="当前章节模型不可用，请在设置中选择支持的模型。"}
        if reason==nil && serviceTest {reason="连接测试正在进行，完成后可生成章节。"}
    }
}

public struct AnalysisPreparation:Sendable {
    public let source:Transcript
    public let existing:LessonAnalysis?
    public let task:AnalysisTaskState
    public static func load(root:URL,lesson:Lecture,config:AnalysisConfig) throws -> AnalysisPreparation {
        try Task.checkCancellation()
        guard let version=lesson.transcriptVersion else {throw Failure("先添加带时间戳的英文字幕（VTT / SRT）。")}
        let url=root.appendingPathComponent("transcripts/\(lesson.id)-\(version).json")
        let source=try Codec.decode(Transcript.self,Data(contentsOf:url));try source.validate()
        guard source.version==version,!source.cues.isEmpty else {throw Failure("先添加带时间戳的英文字幕（VTT / SRT）。")}
        try Task.checkCancellation()
        let records=try AnalysisRepository.readAll(root:root,lessonID:lesson.id)
        let existing=records.first{$0.sourceVersion==version}
        let plan=try AnalysisPlan.make(source)
        try Task.checkCancellation()
        let task=existing?.task ?? AnalysisTaskState(config:config,plan:plan)
        guard task.plan==plan else {throw Failure("未完成任务对应的字幕已改变，请重新确认范围。")}
        return AnalysisPreparation(source:source,existing:existing,task:task)
    }
}
