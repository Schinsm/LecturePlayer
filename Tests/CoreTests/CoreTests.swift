import Testing
import Foundation
@testable import Core

struct CoreTests {
    let sample="\u{feff}WEBVTT\r\n\r\nNOTE skip\r\nmetadata\r\n\r\nSTYLE\r\n::cue {color:red}\r\n\r\nfirst\r\n00:01.000 --> 00:04.000 align:start\r\n<v Alice>Hello &amp; welcome\r\nsecond line</v>\r\n\r\nother\r\n00:00:03.000 --> 00:00:06.500\r\nOverlap\r\n"
    func parsed() throws -> Transcript {try SubtitleParser.parse(Data(sample.utf8),format:"vtt")}
    @Test func testParserPreservesIDsMultilineOverlapAndVersion() throws {let t=try parsed();XCTAssertEqual(t.cues.count,2);XCTAssertEqual(t.cues[0].sourceID,"first");XCTAssertEqual(t.cues[0].en,"Alice: Hello & welcome\nsecond line");XCTAssertEqual(t.cues[1].end,6500);XCTAssertEqual(t,try parsed());XCTAssertEqual(t.original,Data(sample.utf8))}
    @Test func testOffsetOverlapGapAndJump() throws {let t=try parsed();XCTAssertEqual(t.active(at:5.5,offset:2).count,2);XCTAssertTrue(t.active(at:1,offset:2).isEmpty);XCTAssertEqual(t.target(t.cues[0],offset:2),3);XCTAssertEqual(t.target(t.cues[0],offset:-2),0);XCTAssertEqual(t.active(at:1.5,offset:-2).count,2);XCTAssertTrue(t.active(at:8.5,offset:2).isEmpty)}
    @Test func testSRTAndErrors() throws {let t=try SubtitleParser.parse(Data("1\n00:00:00,100 --> 00:00:01,500\nHello\n".utf8),format:"srt");XCTAssertEqual(t.cues[0].start,100);for source in ["WEBVTT\n\n00:99.000 --> 01:00.000\nBad","WEBVTT\n\n00:02.000 --> 00:01.000\nBad","WEBVTT\n\nLost paragraph"] {XCTAssertThrowsError(try SubtitleParser.parse(Data(source.utf8),format:"vtt"))}}
    @Test func testTXTNeverInventsTimes() throws {let t=try SubtitleParser.parse(Data("plain material".utf8),format:"txt");XCTAssertTrue(t.cues.isEmpty);XCTAssertThrowsError(try Exporter.render(t,kind:.bilingualVTT));XCTAssertEqual(try Exporter.render(t,kind:.text),Data("plain material".utf8))}
    @Test func testDirectoryCycleAndCustomCourse() throws {var l=Library();for name in ["CourseC","IM","CourseA","CourseB","Custom"] {l.courses.append(Course(name:name))};let c=l.courses[4];let a=Folder(name:"A",courseID:c.id);let b=Folder(name:"B",courseID:c.id,parentID:a.id);l.folders=[a,b];try l.validate();XCTAssertThrowsError(try l.checkMove(a.id,to:b.id));XCTAssertThrowsError(try l.checkMove(a.id,to:a.id));l.courses[4].name="Renamed";l.courses[4].archived=true;XCTAssertEqual(l.folders[0].courseID,c.id);try l.validate()}
    @Test func testLoadingDoesNotEraseProgressOrSpeed() throws {var p=PlaybackState();p.speed=1.5;p.record(123,ready:true);p.record(0,ready:false);XCTAssertEqual(p.position,123);p.record(.nan,ready:true);XCTAssertEqual(p.position,123);let restored=try Codec.decode(PlaybackState.self,Codec.encode(p));XCTAssertEqual(restored.speed,1.5);XCTAssertEqual(restored.position,123)}
    @Test func testStrictTranslationIDs() throws {let t=try parsed();let valid=t.cues.map{TranslatedItem(id:$0.id,zh:"中文")};try validateTranslations(valid,targets:t.cues);try validateTranslations(Array(valid.reversed()),targets:t.cues);for bad in [Array(valid.prefix(1)),valid+[valid[0]],[valid[0],valid[0]],[TranslatedItem(id:valid[0].id,zh:" "),valid[1]]] {XCTAssertThrowsError(try validateTranslations(bad,targets:t.cues))}}
    @Test func testCacheKeyIncludesConfigurationSourceAndContext() throws {let t=try parsed();let b=TranslationBatch.make(t)[0];let base=try b.key(TranslationConfig());var c=TranslationConfig();c.glossary="NPV=净现值";XCTAssertNotEqual(base,try b.key(c));c=TranslationConfig(model:"other");XCTAssertNotEqual(base,try b.key(c));c=TranslationConfig(effort:"low");XCTAssertNotEqual(base,try b.key(c));var changed=b;changed.context=[t.cues[0]];XCTAssertNotEqual(base,try changed.key(TranslationConfig()));changed=b;changed.sourceVersion="new";XCTAssertNotEqual(base,try changed.key(TranslationConfig()))}
    @Test func testExportsReparseAndPartialMarker() throws {var t=try parsed();t.translations[t.cues[0].id]=Translation(ai:"你好，欢迎",cacheKey:"test");for kind in [ExportKind.englishVTT,.chineseVTT,.bilingualVTT,.bilingualSRT] {let data=try Exporter.render(t,kind:kind);let round=try SubtitleParser.parse(data,format:kind.ext);XCTAssertEqual(round.cues.map(\.start),t.cues.map(\.start));XCTAssertEqual(round.cues.map(\.end),t.cues.map(\.end))};let md=String(data:try Exporter.render(t,kind:.markdown),encoding:.utf8)!;XCTAssertTrue(md.contains("部分翻译"));XCTAssertTrue(md.contains("[未翻译]"))}
    @Test func testBackupRoundTripAndRejectedSchema() throws {var l=Library();let c=Course(name:"Custom");l.courses=[c];var item=Lecture(title:"Sample",courseID:c.id,folderID:nil,url:URL(fileURLWithPath:"/missing.mp4"),bookmark:nil,identity:"1");let t=try parsed();item.transcriptVersion=t.version;item.state.record(90,ready:true);item.marks=[Mark(seconds:5,note:"Review")];l.lectures=[item];let b=Backup(library:l,transcripts:["\(item.id)-\(t.version)":t]);try b.validate();let data=try Codec.encode(b);let restored=try Codec.decode(Backup.self,data);XCTAssertEqual(restored.library,l);XCTAssertFalse(String(data:data,encoding:.utf8)!.contains("api-key"));var bad=b;bad.schema=999;XCTAssertThrowsError(try bad.validate());bad=b;bad.transcripts=[:];XCTAssertThrowsError(try bad.validate())}
    @Test func testLargeTranscript() throws {let source="WEBVTT\n\n"+(0..<4000).map{"\($0)\n\(stamp($0*2)) --> \(stamp($0*2+2))\nSentence \($0)\n"}.joined(separator:"\n");let t=try SubtitleParser.parse(Data(source.utf8),format:"vtt");XCTAssertEqual(t.cues.count,4000);XCTAssertEqual(t.active(at:7000.5,offset:0).count,1);XCTAssertEqual(t.cues.filter{$0.en.contains("Sentence 3999")}.count,1)}
    func stamp(_ s:Int)->String{String(format:"%02d:%02d:%02d.000",s/3600,s/60%60,s%60)}
    @Test func testResponseTruncationRefusalAndUnknownUsage() throws {let t=try parsed();let items=t.cues.map{["id":$0.id,"zh":"中文"]};let json=String(data:try JSONSerialization.data(withJSONObject:["translations":items]),encoding:.utf8)!;var response:[String:Any]=["status":"completed","output":[["content":[["type":"output_text","text":json]]]]];let r=try OpenAIProvider.decode(JSONSerialization.data(withJSONObject:response),targets:t.cues);XCTAssertNil(r.inputTokens);response["status"]="incomplete";XCTAssertTrue(try OpenAIProvider.decode(JSONSerialization.data(withJSONObject:response),targets:t.cues).problem != nil);response=["status":"completed","output":[["content":[["type":"refusal","refusal":"No"]]]]];XCTAssertTrue(try OpenAIProvider.decode(JSONSerialization.data(withJSONObject:response),targets:t.cues).problem != nil)}
}
final class MockURLProtocol:URLProtocol,@unchecked Sendable {
    static var handler:((URLRequest)throws->(Int,Data))!
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){do{let(code,data)=try Self.handler(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)}catch{client?.urlProtocol(self,didFailWithError:error)}}
    override func stopLoading(){}
}
@Suite(.serialized) struct NetworkTests {
    func provider()->OpenAIProvider{let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[MockURLProtocol.self];return OpenAIProvider(key:"MOCK-NOT-A-REAL-KEY",session:URLSession(configuration:config))}
    func batch() throws->TranslationBatch {TranslationBatch.make(try SubtitleParser.parse(Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHello\n".utf8),format:"vtt"))[0]}
    @Test func test401DoesNotRetry() async throws {var calls=0;MockURLProtocol.handler={_ in calls+=1;return(401,Data())};do{_ = try await provider().translate(batch(),config:TranslationConfig());XCTFail()}catch{XCTAssertEqual((error as? APIError)?.status,401)};XCTAssertEqual(calls,1)}
    @Test func test429StopsWithoutRetry() async throws {var calls=0;MockURLProtocol.handler={_ in calls+=1;return(429,Data())};do{_ = try await provider().translate(batch(),config:TranslationConfig());XCTFail()}catch{XCTAssertEqual((error as? APIError)?.status,429)};XCTAssertEqual(calls,1)}
    @Test func testTimeoutStopsWithoutRetry() async throws {var calls=0;MockURLProtocol.handler={_ in calls+=1;throw URLError(.timedOut)};do{_ = try await provider().translate(batch(),config:TranslationConfig());XCTFail()}catch{XCTAssertEqual((error as? URLError)?.code,.timedOut)};XCTAssertEqual(calls,1)}
    @Test func testCancellationBeforeDispatch() async throws {
        var calls=0;MockURLProtocol.handler={_ in calls += 1; return(429,Data())}
        let p=provider(),b=try batch()
        let task=Task { withUnsafeCurrentTask { $0?.cancel() }; return try await p.translate(b,config:TranslationConfig()) }
        do { _ = try await task.value;XCTFail() } catch { #expect(error is CancellationError) }
        #expect(calls == 0)
    }
}

func XCTAssertEqual<T:Equatable>(_ a:@autoclosure () throws->T,_ b:@autoclosure () throws->T,sourceLocation:SourceLocation = #_sourceLocation) {do {let x=try a();let y=try b();#expect(x==y,sourceLocation:sourceLocation)}catch{Issue.record(error,sourceLocation:sourceLocation)}}
func XCTAssertNotEqual<T:Equatable>(_ a:@autoclosure () throws->T,_ b:@autoclosure () throws->T,sourceLocation:SourceLocation = #_sourceLocation) {do {let x=try a();let y=try b();#expect(x != y,sourceLocation:sourceLocation)}catch{Issue.record(error,sourceLocation:sourceLocation)}}
func XCTAssertTrue(_ a:Bool,sourceLocation:SourceLocation = #_sourceLocation){#expect(a,sourceLocation:sourceLocation)}
func XCTAssertFalse(_ a:Bool,sourceLocation:SourceLocation = #_sourceLocation){#expect(!a,sourceLocation:sourceLocation)}
func XCTAssertNil<T>(_ a:T?,sourceLocation:SourceLocation = #_sourceLocation){#expect(a==nil,sourceLocation:sourceLocation)}
func XCTAssertThrowsError<T>(_ a:@autoclosure () throws->T,sourceLocation:SourceLocation = #_sourceLocation){do{_ = try a();Issue.record("Expected an error",sourceLocation:sourceLocation)}catch{}}
func XCTFail(sourceLocation:SourceLocation = #_sourceLocation){Issue.record("Unexpected success",sourceLocation:sourceLocation)}
struct ImportAndSafetyTests {
    @Test func scanSkipsHiddenAndSymlinkAndMatchesSuffix() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LP-scan-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for name in ["Lecture.mp4","Lecture.en.vtt",".hidden.mp4"] {try Data().write(to:root.appendingPathComponent(name))}
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("cycle"),withDestinationURL:root)
        let files=try ImportPlanner.scan([root]);#expect(files.count==2);let candidates=ImportPlanner.candidates(for:root.appendingPathComponent("Lecture.mp4"),in:files);#expect(candidates.map(\.lastPathComponent)==["Lecture.en.vtt"])
        try Data().write(to:root.appendingPathComponent("Lecture.srt"));#expect(ImportPlanner.candidates(for:root.appendingPathComponent("Lecture.mp4"),in:try ImportPlanner.scan([root])).count==2)
    }
    @Test func backupRejectsTraversal() throws {
        let t=try SubtitleParser.parse(Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHello\n".utf8),format:"vtt")
        let b=Backup(library:Library(),transcripts:["\(UUID())/../../outside-\(t.version)":t]);#expect(throws:(any Error).self){try b.validate()}
    }
}
extension NetworkTests {
    @Test func mockSuccessUsesResponsesSchemaAndNoTimestamps() async throws {
        let b=try batch();MockURLProtocol.handler={request in
            #expect(request.url?.absoluteString=="https://api.openai.com/v1/responses")
            var data=request.httpBody
            if data==nil,let stream=request.httpBodyStream {stream.open();defer{stream.close()};var bytes=[UInt8](repeating:0,count:4096);var all=Data();while stream.hasBytesAvailable {let n=stream.read(&bytes,maxLength:bytes.count);if n<=0{break};all.append(bytes,count:n)};data=all}
            let requestData=try #require(data);let object=try JSONSerialization.jsonObject(with:requestData);let body=try #require(object as? [String:Any]);#expect(body["model"] as? String=="gpt-5.6-luna");#expect(body["response_format"]==nil);#expect((body["text"] as? [String:Any])?["format"] != nil)
            let input=try #require(body["input"] as? String);#expect(!input.contains("\"start\""));#expect(!input.contains("\"end\""))
            let output=String(data:try JSONSerialization.data(withJSONObject:["translations":b.targets.enumerated().map{["id":String(format:"c%03d",$0.offset+1),"zh":"你好"]}]),encoding:.utf8)!
            return (200,try JSONSerialization.data(withJSONObject:["status":"completed","output":[["content":[["type":"output_text","text":output]]]],"usage":["input_tokens":123,"output_tokens":45]]))
        }
        let result=try await provider().translate(b,config:TranslationConfig());#expect(result.items[0].zh=="你好");#expect(result.inputTokens==123);#expect(result.outputTokens==45)
    }
}
