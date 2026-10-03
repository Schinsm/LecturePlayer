import Foundation
import Testing
@testable import Core

private func analysisTranscript(_ count: Int = 6, spacing: Int = 30000, text: String = "Lecture explanation") -> Transcript {
    let data=Data("fixture-\(count)-\(spacing)-\(text)".utf8)
    return Transcript(version:digest(data),original:data,format:"vtt",cues:(0..<count).map{Cue(id:"original-\($0)",sourceID:"source-\($0)",start:$0*spacing,end:$0*spacing+20000,en:text+" \($0)")})
}
private func analysisChapter(_ id: String, _ first: Cue, _ last: Cue) -> AnalysisChapter {
    AnalysisChapter(id:id,startCueID:first.id,endCueID:last.id,title:"现金流 Cash flow",points:["老师解释现金流。","结合案例说明。"])
}
private func analysisEnvelope(_ payload: Any, status: String = "completed", reason: String? = nil) throws -> Data {
    let text=String(decoding:try JSONSerialization.data(withJSONObject:payload),as:UTF8.self)
    var root:[String:Any] = ["status":status,"usage":["input_tokens":80,"output_tokens":40,"input_tokens_details":["cached_tokens":20],"output_tokens_details":["reasoning_tokens":10]],"output":[["content":[["type":"output_text","text":text]]]]]
    if let reason {root["incomplete_details"]=["reason":reason]}
    return try JSONSerialization.data(withJSONObject:root)
}
@Suite struct V08AnalysisTests {
    @Test func chunkPlanPreservesEveryCueAndBounds() throws {
        let source=analysisTranscript(100,spacing:30000,text:String(repeating:"English ",count:45))
        let before=source
        let plan=try AnalysisPlan.make(source)
        try plan.validate()
        #expect(plan.chunks.flatMap(\.targets).map(\.id)==source.cues.map(\.id))
        #expect(source==before)
        #expect(plan.estimatedRequests==plan.chunks.count+1)
        for chunk in plan.chunks {
            #expect(chunk.targets.reduce(0){$0+$1.en.utf8.count}<=12000)
            #expect(chunk.targets.last!.end-chunk.targets.first!.start<=600000)
            #expect(Set(chunk.targets.map(\.id)).isDisjoint(with:Set((chunk.contextBefore+chunk.contextAfter).map(\.id))))
            #expect(chunk.contextBefore.allSatisfy{$0.start>=chunk.targets.first!.start-60000})
            #expect(chunk.contextAfter.allSatisfy{$0.end<=chunk.targets.last!.end+60000})
        }
    }
    @Test func denseCuesRemainWithinSchemaLimit() throws {
        let source=analysisTranscript(1400,spacing:300,text:"x")
        let plan=try AnalysisPlan.make(source)
        #expect(plan.chunks.count==2 && plan.chunks[0].targets.count==1000)
        #expect(plan.chunks.flatMap(\.targets).map(\.id)==source.cues.map(\.id))
    }
    @Test func longCueAndTimedTextRequirement() throws {
        let long=analysisTranscript(2,text:String(repeating:"A",count:15000))
        let plan=try AnalysisPlan.make(long)
        #expect(plan.chunks.count==2 && plan.chunks.allSatisfy{$0.targets.count==1})
        let data=Data("no timestamps".utf8), txt=Transcript(version:digest(data),original:data,format:"txt",cues:[],plain:"no timestamps")
        #expect(throws:(any Error).self){try AnalysisPlan.make(txt)}
    }
    @Test func coverageRejectsMissingOverlapReverseAndUnknown() throws {
        let source=analysisTranscript(), chunk=try AnalysisPlan.make(source).chunks[0]
        let good=[analysisChapter("a",source.cues[0],source.cues[2]),analysisChapter("b",source.cues[3],source.cues[5])]
        try AnalysisValidation.block(good,chunk:chunk)
        var missing=good;missing[1].startCueID=source.cues[4].id
        var overlap=good;overlap[1].startCueID=source.cues[2].id
        var unknown=good;unknown[0].endCueID="not-an-original-ID"
        var empty=good;empty[0].points=["", ""]
        for invalid in [missing,overlap,unknown,empty,Array(good.reversed()),[good[0]]] {
            #expect(throws:(any Error).self){try AnalysisValidation.block(invalid,chunk:chunk)}
        }
    }
    @Test func synthesisOnlyMergesAdjacentAndReferencesKnownChapters() throws {
        let cues=analysisTranscript().cues
        let proposed=[analysisChapter("a",cues[0],cues[1]),analysisChapter("b",cues[2],cues[3]),analysisChapter("c",cues[4],cues[5])]
        let merged=analysisChapter("final",cues[0],cues[5])
        let good=AnalysisDocument(chapters:[merged],overview:[AnalysisOverviewPoint(text:"整课要点",chapterID:"final")])
        try AnalysisValidation.synthesis(good,proposed:proposed)
        var bad=good;bad.chapters[0].startCueID=cues[2].id
        #expect(throws:(any Error).self){try AnalysisValidation.synthesis(bad,proposed:proposed)}
        bad=good;bad.chapters[0].endCueID=cues[4].id
        #expect(throws:(any Error).self){try AnalysisValidation.synthesis(bad,proposed:proposed)}
        bad=good;bad.overview[0].chapterID="invented"
        #expect(throws:(any Error).self){try AnalysisValidation.synthesis(bad,proposed:proposed)}
    }
    @Test func incompleteResponseNeverSalvagesJSONButRetainsUsage() throws {
        let source=analysisTranscript(), chunk=try AnalysisPlan.make(source).chunks[0], config=AnalysisConfig(model:"gpt-4o-mini")
        let payload:[String:Any] = ["chapters":[["start":"c0001","end":"c0006","title":"标题","points":["一点","二点"]]]]
        for reason in ["max_output_tokens","content_filter","unexpected_reason"] {
            let response=OpenAIAnalysisProvider.decodeChunk(try analysisEnvelope(payload,status:"incomplete",reason:reason),chunk:chunk,config:config,requestID:"req_sample")
            #expect(response.value==nil && response.result.problem != nil)
            #expect(response.result.inputTokens==80 && response.result.outputTokens==40)
            #expect(response.result.reasoningTokens==10 && response.result.cachedInputTokens==20)
            #expect(response.result.diagnostics?.incompleteReason == (reason=="unexpected_reason" ? "unknown" : reason))
        }
    }
    @Test func providerMapsShortIDsToOriginalAndRejectsUnknown() throws {
        let source=analysisTranscript(), chunk=try AnalysisPlan.make(source).chunks[0], config=AnalysisConfig(model:"gpt-4o-mini")
        let row:[String:Any] = ["start":"c0001","end":"c0006","title":"标题","points":["一点","二点"]]
        let result=OpenAIAnalysisProvider.decodeChunk(try analysisEnvelope(["chapters":[row]]),chunk:chunk,config:config,requestID:"unsafe\nheader")
        let values=try #require(result.value)
        #expect(values[0].startCueID==source.cues[0].id && values[0].endCueID==source.cues[5].id)
        #expect(values[0].sourceStartMilliseconds==source.cues[0].start && values[0].sourceEndMilliseconds==source.cues[5].end)
        #expect(result.result.requestID==nil)
        try AnalysisValidation.block(values,chunk:chunk)
        var bad=row;bad["start"]="c9999"
        let invalid=OpenAIAnalysisProvider.decodeChunk(try analysisEnvelope(["chapters":[bad]]),chunk:chunk,config:config)
        #expect(invalid.value==nil && invalid.result.outputTokens==40)
        let http=OpenAIAnalysisProvider.decodeChunk(try analysisEnvelope([:]),chunk:chunk,config:config,requestID:"req_failed",httpStatus:429)
        #expect(http.value==nil && http.result.requestID=="req_failed" && http.result.inputTokens==80)
        #expect(OpenAIAnalysisProvider.decodeChunk(Data("{broken".utf8),chunk:chunk,config:config).value==nil)
    }
    @Test func synthesisMappingAndRefusal() throws {
        let cues=analysisTranscript().cues, config=AnalysisConfig(model:"gpt-4o-mini")
        let proposed=[analysisChapter("b1",cues[0],cues[2]),analysisChapter("b2",cues[3],cues[5])]
        let data=try analysisEnvelope(["chapters":[["first":"p0001","last":"p0002","title":"标题","points":["一点","二点"]]],"overview":[["text":"核心要点","chapter_start":"p0001"]]])
        let response=OpenAIAnalysisProvider.decodeSynthesis(data,proposed:proposed,config:config)
        let value=try #require(response.value)
        try AnalysisValidation.synthesis(value,proposed:proposed)
        #expect(value.overview[0].chapterID==value.chapters[0].id)
        let refused=try JSONSerialization.data(withJSONObject:["status":"completed","output":[["content":[["type":"refusal","refusal":"private body"]]]]])
        let result=OpenAIAnalysisProvider.decodeSynthesis(refused,proposed:proposed,config:config)
        #expect(result.value==nil && result.result.problem=="服务拒绝生成本组总结")
    }
    @Test func checkpointsResumeOldCompleteAndSafeFilename() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LP08-analysis-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let source=analysisTranscript(50),plan=try AnalysisPlan.make(source),config=AnalysisConfig(model:"gpt-4o-mini")
        let repository=AnalysisRepository(root:root), lesson=UUID()
        var record=LessonAnalysis(lessonID:lesson,sourceVersion:source.version)
        let original=AnalysisDocument(chapters:[analysisChapter("old",source.cues.first!,source.cues.last!)],overview:[.init(text:"旧版已完成",chapterID:"old")])
        record.completed=original;record.completedConfig=config;record.completedAt=Date()
        record.task=AnalysisTaskState(config:config,plan:plan)
        let first=plan.chunks[0]
        record.task!.completedChunks[first.id]=[analysisChapter("first",first.targets.first!,first.targets.last!)]
        record.task!.status = .failed;record.task!.message="测试中断"
        record.attempts=[try AnalysisAttempt(stage:first.id,config:config,result:TranslationResult(items:[],inputTokens:12,outputTokens:8),outcome:"completed"),try AnalysisAttempt(stage:"cancelled",config:config,result:TranslationResult(items:[],problem:"取消"),outcome:"cancelled")]
        try record.validate(transcript:source)
        try await repository.save(record)
        let loaded=try #require(await repository.load(lessonID:lesson,sourceVersion:source.version))
        #expect(loaded.completed==original && loaded.task?.pendingChunks.count==plan.chunks.count-1)
        #expect(loaded.attempts[1].usage.inputTokens==nil)
        #expect(try AnalysisRepository.readAll(root:root)==[record])
        let safe=AnalysisRepository.fileURL(root:root,lessonID:lesson,sourceVersion:"../../escaped")
        #expect(safe.deletingLastPathComponent()==root.appendingPathComponent("analyses",isDirectory:true))
        var corrupt=record;corrupt.task!.completedChunks["invented"]=[]
        do{try await repository.save(corrupt);Issue.record("Expected rejected checkpoint")}catch{}
        #expect(try await repository.load(lessonID:lesson,sourceVersion:source.version)==record)
    }
    @Test func markdownUsesMapperAndRejectsStaleSubtitle() throws {
        let transcript=analysisTranscript(),config=AnalysisConfig(model:"gpt-4o-mini")
        var record=LessonAnalysis(lessonID:UUID(),sourceVersion:transcript.version)
        record.completed=AnalysisDocument(chapters:[analysisChapter("a",transcript.cues.first!,transcript.cues.last!)],overview:[.init(text:"核心要点",chapterID:"a")]);record.completedConfig=config;record.completedAt=Date()
        let markdown=try AnalysisMarkdown.export(record,transcript:transcript,offset:14,title:"测试课程")
        #expect(markdown.contains("00:00:14") && markdown.contains("00:03:04"))
        #expect(markdown.contains(transcript.version))
        #expect(throws:(any Error).self){try record.validate(transcript:analysisTranscript(7))}
    }
}

private final class AnalysisURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int,Data))?
    static var count=0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        do {
            let (status,data)=try Self.handler!(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["x-request-id":"req_analysis_mock"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
@Suite(.serialized) struct V08AnalysisHTTPTests {
    @Test(arguments:[200,401,429,500]) func actualProviderUsesFixedEndpointSchemaAndSingleRequest(_ status: Int) async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AnalysisURLProtocol.self]
        let session=URLSession(configuration:config);defer{session.invalidateAndCancel();AnalysisURLProtocol.handler=nil}
        let chunk=try AnalysisPlan.make(analysisTranscript()).chunks[0]
        AnalysisURLProtocol.count=0
        AnalysisURLProtocol.handler={ request in
            #expect(request.url?.absoluteString=="https://api.openai.com/v1/responses")
            #expect(request.httpMethod=="POST")
            #expect(request.value(forHTTPHeaderField:"Authorization")=="Bearer mock-key")
            var data=request.httpBody
            if data==nil,let stream=request.httpBodyStream {
                stream.open();defer{stream.close()}
                var bytes=[UInt8](repeating:0,count:2048), result=Data()
                while stream.hasBytesAvailable {let count=stream.read(&bytes,maxLength:bytes.count);if count<=0{break};result.append(contentsOf:bytes.prefix(count))};data=result
            }
            let body=try JSONSerialization.jsonObject(with:try #require(data)) as! [String:Any]
            #expect(body["model"] as? String=="gpt-4o-mini" && body["store"] as? Bool==false)
            #expect(body["max_output_tokens"] as? Int==6000)
            #expect(body["reasoning"]==nil)
            let input=try JSONSerialization.jsonObject(with:Data((body["input"] as! String).utf8)) as! [String:Any]
            let targets=input["targets"] as! [[String:String]]
            #expect(targets.count==chunk.targets.count && targets[0]["id"]=="c0001")
            #expect(targets[0]["english"]==chunk.targets[0].en)
            let format=(body["text"] as! [String:Any])["format"] as! [String:Any]
            #expect(format["strict"] as? Bool==true && format["name"] as? String=="lecture_chapters")
            let schema=format["schema"] as! [String:Any], definitions=schema["$defs"] as! [String:Any]
            #expect((definitions["boundary_id"] as! [String:Any])["enum"] as? [String] == (1...6).map{String(format:"c%04d",$0)})
            let properties=schema["properties"] as! [String:Any], rows=properties["chapters"] as! [String:Any], items=rows["items"] as! [String:Any], rowProperties=items["properties"] as! [String:Any]
            #expect((rowProperties["start"] as! [String:Any])["$ref"] as? String=="#/$defs/boundary_id")
            #expect((rowProperties["end"] as! [String:Any])["$ref"] as? String=="#/$defs/boundary_id")
            return (status,try analysisEnvelope(["chapters":[["start":"c0001","end":"c0006","title":"Cash flow","points":["一点","二点"]]]]))
        }
        let result=try await OpenAIAnalysisProvider(key:"mock-key",session:session).analyze(chunk,config:AnalysisConfig(model:"gpt-4o-mini"))
        #expect(AnalysisURLProtocol.count==1)
        #expect((result.value != nil)==(status==200))
        #expect(result.result.inputTokens==80 && result.result.outputTokens==40 && result.result.requestID=="req_analysis_mock")
    }
    @Test func excessiveSynthesisFailsBeforeNetwork() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AnalysisURLProtocol.self]
        let session=URLSession(configuration:config);defer{session.invalidateAndCancel();AnalysisURLProtocol.handler=nil}
        AnalysisURLProtocol.count=0;AnalysisURLProtocol.handler={ _ in Issue.record("Unexpected network call");return (500,Data()) }
        let cues=analysisTranscript(1001).cues
        let chapters=cues.enumerated().map{analysisChapter("c-\($0.offset)",$0.element,$0.element)}
        do{_ = try await OpenAIAnalysisProvider(key:"mock-key",session:session).synthesize(chapters,config:AnalysisConfig(model:"gpt-4o-mini"));Issue.record("Expected schema limit failure")}catch{#expect(error is AnalysisNotSent)}
        #expect(AnalysisURLProtocol.count==0)
    }
    @Test func invalidConfigurationIsNotARequest() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AnalysisURLProtocol.self]
        let session=URLSession(configuration:config);defer{session.invalidateAndCancel();AnalysisURLProtocol.handler=nil}
        AnalysisURLProtocol.count=0;AnalysisURLProtocol.handler={_ in Issue.record("Unexpected network call");return (500,Data())}
        let chunk=try AnalysisPlan.make(analysisTranscript()).chunks[0]
        do{_ = try await OpenAIAnalysisProvider(key:"mock",session:session).analyze(chunk,config:AnalysisConfig(model:"unsupported-model"));Issue.record("Expected invalid config")}catch{#expect(error is AnalysisNotSent)}
        #expect(AnalysisURLProtocol.count==0)
    }
    @Test func cancellationAndTimeoutNeverRetry() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AnalysisURLProtocol.self]
        let session=URLSession(configuration:config);defer{session.invalidateAndCancel();AnalysisURLProtocol.handler=nil}
        let chunk=try AnalysisPlan.make(analysisTranscript()).chunks[0]
        for code in [URLError.timedOut,URLError.cancelled] {
            AnalysisURLProtocol.count=0
            AnalysisURLProtocol.handler={_ in throw URLError(code)}
            do{_ = try await OpenAIAnalysisProvider(key:"mock-key",session:session).analyze(chunk,config:AnalysisConfig(model:"gpt-4o-mini"));Issue.record("Expected network failure")}catch{}
            #expect(AnalysisURLProtocol.count==1)
        }
    }
}
