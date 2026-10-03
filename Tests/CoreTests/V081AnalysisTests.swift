import Foundation
import Testing
@testable import Core

struct V081AnalysisTests {
    var chunk:AnalysisChunk {AnalysisChunk(id:"block-1",targets:(0..<4).map {Cue(id:"q\($0)",start:$0*1000,end:($0+1)*1000,en:"Part \($0)")})}
    var config:AnalysisConfig {var v=AnalysisConfig(model:"gpt-5.6-luna");v.protocolVersion=2;return v}
    func envelope(_ text:String) throws -> Data {try JSONSerialization.data(withJSONObject:["status":"completed","usage":["input_tokens":40,"output_tokens":50],"output":[["content":[["type":"output_text","text":text]]]]])}
    @Test func boundariesDeriveEndsAndRejectMissingDuplicateReorderedUnknown() throws {
        let good=[HierarchicalAnalysis.Boundary(start:"c0001",title:"概念",points:["一"]),.init(start:"c0003",title:"例题",points:["二"])]
        let points=try HierarchicalAnalysis.build(good,chunk:chunk)
        #expect(points.map(\.memberCueIDs) == [["q0","q1"],["q2","q3"]])
        try AnalysisValidation.block(points,chunk:chunk)
        for rows in [[good[1]],[good[0],good[0]],[good[1],good[0]],[.init(start:"c9999",title:"x",points:["x"])]] {
            #expect(throws:(any Error).self) {try HierarchicalAnalysis.build(rows,chunk:chunk)}
        }
    }
    @Test func mergedSubtopicCanBeReferencedByInternalMember() throws {
        let points=try HierarchicalAnalysis.build([.init(start:"c0001",title:"a",points:["a"]),.init(start:"c0003",title:"b",points:["b"])],chunk:chunk)
        let json=#"{"topics":[{"title":"主题","summary":"概述","subtopics":[{"first":"p0001","last":"p0002","title":"知识点","points":["说明"]}]}],"overview":[{"text":"总结","source":"p0002"}]}"#
        let response=OpenAIAnalysisProvider.decodeHierarchySynthesis(try envelope(json),proposed:points,config:config)
        let doc=try #require(response.value)
        #expect(doc.topics?.count == 1)
        #expect(doc.chapters[0].memberCueIDs == chunk.targets.map(\.id))
        #expect(doc.overview[0].chapterID == doc.chapters[0].id)
        var invalid=doc;invalid.chapters[0].memberCueIDs=["q0","q3"]
        #expect(throws:(any Error).self) {try HierarchicalAnalysis.validate(invalid,proposed:points)}
    }
    @Test func malformedHierarchyRetainsUsage() throws {
        let result=OpenAIAnalysisProvider.decodeHierarchyChunk(try envelope(#"{"subtopics":[{"start":"bad","title":"a","points":["x"]}]}"#),chunk:chunk,config:config)
        #expect(result.value == nil && result.result.problem?.contains("未知") == true)
        #expect(result.result.outputTokens == 50)
    }
    @Test func automaticPlanFrozenPerStageAndManualCompatible() throws {
        let plan=ResolvedModelPlan.analysis(config,automatic:true)
        try plan.validate()
        var c=config;c.resolvedModels=plan
        #expect(c.forStage("analysis").effort == "low")
        #expect(c.forStage("synthesis").model == "gpt-5.6-terra")
        #expect(c.forStage("synthesis").effort == "medium")
        let decoded=try Codec.decode(AnalysisConfig.self,Codec.encode(c))
        #expect(decoded == c)
        #expect(try TranslationConfig(model:"gpt-4o-mini",effort:"high").descriptor().supportsReasoning == false)
        #expect(throws:(any Error).self){try TranslationConfig(model:"unavailable").descriptor()}
        let old=try JSONDecoder().decode(AnalysisConfig.self,from:Data(#"{"model":"gpt-4o-mini","effort":"none","outputLimit":6000}"#.utf8))
        #expect(old.resolvedModels == nil && old.protocolVersion == nil)
    }
    @Test func frozenUnknownPriceAndHierarchyBackupRollback() throws {
        var c=config;c.resolvedModels=ResolvedModelPlan.analysis(c,automatic:true)
        c.resolvedModels!.stages["analysis"]!.pricing=nil
        let usage=TranslationUsage(result:TranslationResult(items:[],inputTokens:10,outputTokens:20),config:c.forStage("analysis").translationConfig,descriptor:try c.translationConfig.descriptor(),batchKey:"x")
        #expect(usage.estimatedUSD == nil && usage.pricing == nil)
        #expect(try AnalysisPlan.make(Transcript(version:digest("s"),original:Data("s".utf8),format:"vtt",cues:chunk.targets)).estimate(config:c).contains("无法可靠估算"))
        var (backup,record,t)=try V08BackupTests().fixture()
        let plan=try AnalysisPlan.make(t)
        let children=try plan.chunks.flatMap {try HierarchicalAnalysis.build([.init(start:"c0001",title:"知识点",points:["证据"])],chunk:$0)}
        record.schema=2;record.completed=AnalysisDocument(chapters:children,overview:[.init(text:"总结",chapterID:children[0].id)])
        record.completed!.topics=[AnalysisTopic(id:"topic",title:"主题",overview:"概述",subtopics:children)]
        backup=Backup(library:backup.library,transcripts:backup.transcripts,analyses:try Backup.analysisPayload([record]),processing:[ImportProcessingEntry(id:record.lessonID,translation:nil,analysis:AnalysisTaskState(config:config,plan:plan))])
        try backup.validate();#expect(backup.schema==6)
        let decoded=try Codec.decode(Backup.self,Codec.encode(backup));try decoded.validate()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LP081-rollback-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let old=Data("prior pending queue".utf8);try old.write(to:root.appendingPathComponent("processing-queue.json"))
        #expect(throws:(any Error).self){try BackupPayloadTransaction.restore(decoded,root:root){throw Failure("save failed")}}
        #expect(try Data(contentsOf:root.appendingPathComponent("processing-queue.json"))==old)
        try BackupPayloadTransaction.restore(decoded,root:root){}
        #expect(try ImportProcessingEntry.read(root:root)==decoded.processing)
        let reloaded=try AnalysisRepository.readAll(root:root)
        #expect(reloaded==[record])
        let markdown=try AnalysisMarkdown.export(record,transcript:t,offset:14,title:"test")
        #expect(markdown.contains("## 主题") && markdown.contains("### "))
    }

}
