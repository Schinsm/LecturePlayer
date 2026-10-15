import Foundation
import Testing
@testable import Core

private final class ChaptersOnlyMock:URLProtocol,@unchecked Sendable {
    nonisolated(unsafe) static var handler:((URLRequest)throws->Data)?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {let data=try Self.handler!(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}
@Suite(.serialized) struct V0811ChapterTests {
    var config:AnalysisConfig {var c=AnalysisConfig(model:"gpt-4o-mini");c.protocolVersion=4;return c}
    func fixture()throws->(Transcript,AnalysisTaskState,[AnalysisChapter]) {
        let t=try SubtitleParser.parse(Data("WEBVTT\n\n00:00.000 --> 00:01.000\nCash flow\n\n00:01.000 --> 00:02.000\nDiscounting\n".utf8),format:"vtt")
        let plan=try AnalysisPlan.make(t),block=plan.chunks[0]
        let children=try HierarchicalAnalysis.build([.init(start:"c0001",title:"Cash",points:["Flow"]),.init(start:"c0002",title:"Value",points:["Discount"])],chunk:block)
        return(t,AnalysisTaskState(config:config,plan:plan),children)
    }
    func envelope(_ payload:Any,status:String="completed")throws->Data {
        let text=String(decoding:try JSONSerialization.data(withJSONObject:payload),as:UTF8.self)
        return try JSONSerialization.data(withJSONObject:["status":status,"output":[["content":[["type":"output_text","text":text]]]]])
    }
    var payload:[String:Any] {["topics":[["start":"p0001","title":"Valuation","summary":"Cash flows and value"]]]}
    @Test func outgoingRequestOmitsOverviewAndKeepsFrozenConfiguration()async throws {
        let (_,_,children)=try fixture()
        let settings=URLSessionConfiguration.ephemeral;settings.protocolClasses=[ChaptersOnlyMock.self]
        let session=URLSession(configuration:settings);defer{session.invalidateAndCancel();ChaptersOnlyMock.handler=nil}
        var count=0
        ChaptersOnlyMock.handler={request in
            count += 1;let body=try ModelRequestTests().body(request)
            let format=try #require((body["text"] as? [String:Any])?["format"] as? [String:Any])
            let schema=try #require(format["schema"] as? [String:Any])
            #expect(format["name"] as? String=="lecture_chapters_only")
            #expect((schema["properties"] as? [String:Any])?["overview"]==nil)
            #expect(!(String(describing:body["instructions"])).contains("whole-lecture overview"))
            #expect(body["model"] as? String=="gpt-4o-mini" && body["max_output_tokens"] as? Int==6000)
            return try envelope(payload)
        }
        let result=try await OpenAIAnalysisProvider(key:"synthetic",session:session).synthesize(children,config:config)
        #expect(count==1 && result.value?.chapters==children && result.value?.overview.isEmpty==true)
    }
    @Test func chapterProtocolRejectsMissingCoverageUnknownDuplicateAndTruncatedOutput()throws {
        let (_,_,children)=try fixture()
        for starts in [["p0002"],["p9999"],["p0001","p0001"],["p0002","p0001"]] {
            let bad:[String:Any]=["topics":starts.map{["start":$0,"title":"A","summary":"B"]}]
            #expect(OpenAIAnalysisProvider.decodeCompactSynthesis(try envelope(bad),proposed:children,config:config).value==nil)
        }
        #expect(OpenAIAnalysisProvider.decodeCompactSynthesis(try envelope(payload,status:"incomplete"),proposed:children,config:config).value==nil)
        var bad=payload;bad["overview"]=[]
        #expect(OpenAIAnalysisProvider.decodeCompactSynthesis(try envelope(bad),proposed:children,config:config).value==nil)
    }
    @Test func oldRulesStayStrictAndNewProtocolCannotRewriteAcceptedChildren()throws {
        let (_,_,children)=try fixture()
        let document=try #require(OpenAIAnalysisProvider.decodeCompactSynthesis(try envelope(payload),proposed:children,config:config).value)
        try AnalysisValidation.synthesis(document,proposed:children,protocolVersion:4)
        #expect(throws:(any Error).self){try AnalysisValidation.document(document,protocolVersion:3)}
        var changed=document;changed.chapters[0].points=["rewritten"];changed.topics![0].subtopics=changed.chapters
        #expect(throws:(any Error).self){try AnalysisValidation.synthesis(changed,proposed:children,protocolVersion:4)}
    }
    @Test func explicitContinuationRetainsBlocksAndFrozenSettings()throws {
        let (_,task,children)=try fixture();var old=task;old.config.protocolVersion=3;old.completedChunks[old.plan.chunks[0].id]=children
        let upgraded=try old.chaptersOnlyContinuation()
        #expect(upgraded.config.protocolVersion==4 && old.config.protocolVersion==3)
        #expect(upgraded.config.model==old.config.model && upgraded.config.effort==old.config.effort && upgraded.config.outputLimit==old.config.outputLimit)
        #expect(upgraded.pendingChunks.isEmpty && upgraded.proposedChapters==children)
    }
    @Test func newRecordAndBackupRoundTripAndOlderFormatsRejectIt()throws {
        let (t,task,children)=try fixture()
        let c=Course(name:"Synthetic");let url=URL(fileURLWithPath:"/synthetic.mp4")
        var lesson=Lecture(title:"Test",courseID:c.id,folderID:nil,url:url,bookmark:nil,identity:"synthetic");lesson.transcriptVersion=t.version
        var library=Library();library.courses=[c];library.lectures=[lesson]
        var record=LessonAnalysis(lessonID:lesson.id,sourceVersion:t.version)
        let document:AnalysisDocument=try #require(OpenAIAnalysisProvider.decodeCompactSynthesis(try envelope(payload),proposed:children,config:config).value)
        record.schema=3;record.completed=document;record.completedConfig=config;record.completedAt=Date()
        try record.validate(transcript:t)
        let backup=Backup(library:library,transcripts:["\(lesson.id)-\(t.version)":t],analyses:try Backup.analysisPayload([record]))
        #expect(backup.schema==7);try backup.validate()
        #expect(try Codec.decode(Backup.self,Codec.encode(backup)).analyses==backup.analyses)
        var old=backup;old.schema=6;#expect(throws:(any Error).self){try old.validate()}
        var invalid=record;invalid.schema=2;#expect(throws:(any Error).self){try invalid.validate()}
        let queued=Backup(library:library,transcripts:["\(lesson.id)-\(t.version)":t],processing:[ImportProcessingEntry(id:lesson.id,translation:nil,analysis:task)])
        #expect(queued.schema==7);try queued.validate()
    }
    @Test func legacyOverviewSurvivesStorageButIsAbsentFromChapterExport()throws {
        let (t,_,children)=try fixture();var oldConfig=config;oldConfig.protocolVersion=3
        var oldPayload=payload;oldPayload["overview"]=[["text":"LEGACY_OVERVIEW","source":"p0001"]]
        var record=LessonAnalysis(lessonID:UUID(),sourceVersion:t.version);record.schema=2
        let document:AnalysisDocument=try #require(OpenAIAnalysisProvider.decodeCompactSynthesis(try envelope(oldPayload),proposed:children,config:oldConfig).value)
        record.completed=document;record.completedConfig=oldConfig;record.completedAt=Date()
        let data=try Codec.encode(record);try record.validate(transcript:t)
        let markdown=try AnalysisMarkdown.export(record,transcript:t,title:"Synthetic")
        #expect(!markdown.contains("LEGACY_OVERVIEW") && markdown.contains("Valuation"))
        #expect(try Codec.encode(record)==data)
        #expect(try Codec.decode(LessonAnalysis.self,data).completed?.overview.first?.text=="LEGACY_OVERVIEW")
    }
}
