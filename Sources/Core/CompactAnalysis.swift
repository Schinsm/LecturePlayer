import Foundation

/// Safe structural metadata only. Never stores response text or course source text.
public struct AnalysisValidationDetail: Codable, Equatable, Sendable {
    public var code:String
    public var identifiers:[String]
    public var expectedCount:Int?
    public var receivedCount:Int?
    public init(code:String,identifiers:[String]=[],expectedCount:Int?=nil,receivedCount:Int?=nil) {
        self.code=code
        self.identifiers=identifiers.filter{$0.count<=12 && $0.range(of:"^[cp][0-9]{4}$",options:.regularExpression) != nil}
        self.expectedCount=expectedCount;self.receivedCount=receivedCount
    }
    public static func from(_ result:TranslationResult)->Self? {
        guard let message=result.problem else{return nil}
        let code:String
        if result.diagnostics?.incompleteReason=="max_output_tokens" {code="output_limit"}
        else if result.diagnostics?.incompleteReason=="content_filter" {code="content_filter"}
        else if let http=result.diagnostics?.httpStatus,http>=400 {code="http"}
        else if message.contains("拒绝") {code="refusal"}
        else if message.contains("JSON") {code="format"}
        else if message.contains("引用") || message.contains("对应章节") {code="reference"}
        else if message.contains("未知") && message.contains("编号") {code="unknown_id"}
        else if message.contains("重复") {code="duplicate"}
        else if message.contains("顺序") {code="order_or_coverage"}
        else if message.contains("遗漏") || message.contains("范围") {code="coverage"}
        else if message.contains("为空") {code="empty"}
        else if result.diagnostics == nil {code="network_or_transport"}
        else {code="unknown"}
        return Self(code:code)
    }
}
public struct AnalysisValidationFailure:Error,LocalizedError,Sendable {
    public let detail:AnalysisValidationDetail
    public let message:String
    public init(_ code:String,_ message:String,ids:[String]=[],expected:Int?=nil,received:Int?=nil) {
        detail=AnalysisValidationDetail(code:code,identifiers:ids,expectedCount:expected,receivedCount:received);self.message=message
    }
    public var errorDescription:String? {message}
}
public enum CompactAnalysis {
    public struct Topic:Codable,Sendable {public var start:String;public var title:String;public var summary:String}
    public struct Point:Codable,Sendable {public var text:String;public var source:String}
    public struct Payload:Codable,Sendable {public var topics:[Topic];public var overview:[Point]}
    public static func build(_ payload:Payload,proposed:[AnalysisChapter]) throws -> AnalysisDocument {
        guard !proposed.isEmpty,Set(proposed.map(\.id)).count==proposed.count else {throw AnalysisValidationFailure("input","已保存知识点为空或编号重复")}
        let ids=proposed.indices.map{String(format:"p%04d",$0+1)}
        let positions=Dictionary(uniqueKeysWithValues:ids.enumerated().map{($0.element,$0.offset)})
        guard !payload.topics.isEmpty else {throw AnalysisValidationFailure("empty","没有返回主题",expected:1,received:0)}
        var starts:[Int]=[]
        for topic in payload.topics {
            guard let index=positions[topic.start] else {throw AnalysisValidationFailure("unknown_id","主题包含未知知识点编号",ids:[topic.start])}
            if let last=starts.last,index<=last {throw AnalysisValidationFailure(index==last ? "duplicate":"order","主题起点重复或顺序错误",ids:[topic.start])}
            guard !topic.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!topic.summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw AnalysisValidationFailure("empty","主题标题或概述为空",ids:[topic.start])}
            starts.append(index)
        }
        guard starts.first==0 else {throw AnalysisValidationFailure("coverage","主题遗漏开头知识点",ids:[payload.topics[0].start],expected:0,received:starts[0])}
        var document=AnalysisDocument(chapters:proposed,overview:[])
        document.topics=payload.topics.enumerated().map {i,topic in
            let end=i+1<starts.count ? starts[i+1]:proposed.count
            return AnalysisTopic(id:"compact-topic-\(i+1)",title:topic.title,overview:topic.summary,subtopics:Array(proposed[starts[i]..<end]))
        }
        guard (1...8).contains(payload.overview.count) else {throw AnalysisValidationFailure("count","整课总结要点数量无效",received:payload.overview.count)}
        document.overview=try payload.overview.map {point in
            guard let index=positions[point.source] else {throw AnalysisValidationFailure("reference","总结要点引用未知知识点",ids:[point.source])}
            guard !point.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw AnalysisValidationFailure("empty","总结要点为空",ids:[point.source])}
            return AnalysisOverviewPoint(text:point.text,chapterID:proposed[index].id)
        }
        try AnalysisValidation.synthesis(document,proposed:proposed)
        return document
    }
}
