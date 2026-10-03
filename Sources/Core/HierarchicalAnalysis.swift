import Foundation

public typealias AnalysisSubtopic = AnalysisChapter
public struct AnalysisTopic: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var overview: String
    public var subtopics: [AnalysisSubtopic]
    public init(id:String,title:String,overview:String,subtopics:[AnalysisSubtopic]) {
        self.id=id;self.title=title;self.overview=overview;self.subtopics=subtopics
    }
}
public extension AnalysisConfig {
    func forStage(_ stage: String) -> Self {
        var copy=self
        if let value=resolvedModels?.stages[stage] {copy.model=value.model;copy.effort=value.effort}
        return copy
    }
    var selectionDescription: String {resolvedModels?.summary ?? "\(model) · \(effort)"}
}
public enum HierarchicalAnalysis {
    public static func validateStructure(_ document: AnalysisDocument) throws {
        guard let topics=document.topics,!topics.isEmpty,Set(topics.map(\.id)).count==topics.count,
              topics.allSatisfy({!$0.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !$0.overview.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !$0.subtopics.isEmpty}),
              topics.flatMap(\.subtopics)==document.chapters else {throw Failure("父子章节关系、顺序或主题内容无效")}
        for child in document.chapters {
            guard let members=child.memberCueIDs,!members.isEmpty,Set(members).count==members.count,
                  members.first==child.startCueID,members.last==child.endCueID else {throw Failure("知识点原文范围无效")}
        }
    }
    public static func validate(_ document: AnalysisDocument, proposed: [AnalysisChapter]) throws {
        try validateStructure(document)
        var cursor=0
        for child in document.chapters {
            guard cursor<proposed.count,child.startCueID==proposed[cursor].startCueID,
                  let end=proposed[cursor...].firstIndex(where:{$0.endCueID==child.endCueID}) else {throw Failure("知识点只能合并相邻片段")}
            let expected=proposed[cursor...end].flatMap {$0.memberCueIDs ?? []}
            guard !expected.isEmpty,child.memberCueIDs==expected else {throw Failure("知识点遗漏、重复或重排了原文")}
            cursor=end+1
        }
        guard cursor==proposed.count else {throw Failure("总结遗漏知识点")}
    }
    public struct Boundary: Codable, Sendable {
        public var start:String;public var title:String;public var points:[String]
        public init(start:String,title:String,points:[String]){self.start=start;self.title=title;self.points=points}
    }
    public static func build(_ rows:[Boundary], chunk:AnalysisChunk) throws -> [AnalysisChapter] {
        let mapping=Dictionary(uniqueKeysWithValues:chunk.targets.indices.map{(String(format:"c%04d",$0+1),$0)})
        guard !rows.isEmpty else {throw Failure("没有返回知识点")}
        var starts:[Int]=[]
        for row in rows {
            guard let index=mapping[row.start] else {throw AnalysisValidationFailure("unknown_id","知识点包含未知字幕编号",ids:[row.start])}
            if let last=starts.last, index<=last {throw AnalysisValidationFailure(index==last ? "duplicate":"order",index==last ? "知识点编号重复" : "知识点顺序错误",ids:[row.start])}
            starts.append(index)
        }
        guard starts.first==0 else {throw AnalysisValidationFailure("coverage","知识点遗漏开头字幕",ids:rows.prefix(1).map(\.start),expected:0,received:starts.first)}
        return try rows.enumerated().map { i,row in
            guard !row.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,(1...2).contains(row.points.count),row.points.allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else {throw Failure("知识点标题或说明为空")}
            let end=i+1<starts.count ? starts[i+1]-1 : chunk.targets.count-1
            let members=Array(chunk.targets[starts[i]...end])
            var value=AnalysisChapter(id:chunk.id+String(format:"-point-%04d",i+1),startCueID:members[0].id,endCueID:members.last!.id,title:row.title,points:row.points)
            value.memberCueIDs=members.map(\.id);value.sourceStartMilliseconds=members[0].start;value.sourceEndMilliseconds=members.last!.end
            return value
        }
    }
}
