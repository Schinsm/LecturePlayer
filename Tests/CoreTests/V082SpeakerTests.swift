import Foundation
import Testing
@testable import Core
private final class SpeakerMock:URLProtocol,@unchecked Sendable {
    static var handler:((URLRequest)throws->Data)!
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {do {let data=try Self.handler(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)} catch {client?.urlProtocol(self,didFailWithError:error)}}
    override func stopLoading() {}
}
@Suite(.serialized) struct V082SpeakerTests {
    func fixture()throws->Transcript {try SubtitleParser.parse(Data("WEBVTT\n\nx\n00:00.000 --> 00:01.000\nSpeaker 0: Revenue is not cash.\n\ny\n00:01.000 --> 00:02.000\nSpeaker 1: Correct.\n".utf8),format:"vtt")}
    @Test func requestProjectionPreservesSourceIdentityAndHistoricalDisplay() throws {
        let t=try fixture(),b=TranslationBatch.make(t,maxCues:1)[0],key=try b.key(TranslationConfig())
        let cleaned=b.withoutSpeakerLabels()
        #expect(cleaned.targets[0].en=="Revenue is not cash.")
        #expect(cleaned.context[0].en=="Correct.")
        #expect(cleaned.targets[0].id==b.targets[0].id && cleaned.targets[0].start==b.targets[0].start)
        #expect(try b.key(TranslationConfig())==key && b.targets[0].en.hasPrefix("Speaker"))
        let old="发言人 0：收入不是现金。 说话者 0: 注意。 扬声器 0：不要混淆。"
        #expect(SpeakerLabel.cleanTranslation(old,source:b.targets[0].en)=="收入不是现金。 注意。 不要混淆。")
        #expect(SpeakerLabel.cleanTranslation(old,source:b.targets[0].en,hide:false)==old)
        #expect(SpeakerLabel.cleanTranslation("扬声器 0：故障",source:"The loudspeaker is broken.")=="扬声器 0：故障")
        #expect(SpeakerLabel.clean("The speaker is discussing Speaker 0: as an example.")=="The speaker is discussing Speaker 0: as an example.")
    }
    @Test func allCloudWirePayloadsExcludeLabelsAndAnchorsMatch() async throws {
        let b=TranslationBatch.make(try fixture(),maxCues:1)[0]
        let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[SpeakerMock.self];let session=URLSession(configuration:c)
        var calls=0
        SpeakerMock.handler={r in
            calls+=1
            var data=r.httpBody ?? Data()
            if let stream=r.httpBodyStream {
                stream.open();defer {stream.close()};var bytes=[UInt8](repeating:0,count:4096)
                while true {let n=stream.read(&bytes,maxLength:bytes.count);if n<=0 {break};data.append(bytes,count:n)}
            }
            let text=String(decoding:data,as:UTF8.self)
            #expect(!text.contains("Speaker 0:") && !text.contains("Speaker 1:"))
            if r.url!.host=="api.openai.com" {
                let body=try JSONSerialization.jsonObject(with:data) as! [String:Any]
                #expect(!(body["instructions"] as! String).contains("Preserve speaker labels"))
                let inner="{\"translations\":{\"c001\":{\"source\":\"Revenue is not cash.\",\"zh\":\"收入不是现金。\"}}}"
                return try JSONSerialization.data(withJSONObject:["status":"completed","output":[["content":[["type":"output_text","text":inner]]]]])
            }
            if r.url!.host=="api-free.deepl.com" {return Data("{\"translations\":[{\"text\":\"收入不是现金。\",\"detected_source_language\":\"EN\"}]}".utf8)}
            return Data("[{\"translations\":[{\"text\":\"收入不是现金。\",\"to\":\"zh-Hans\"}]}]".utf8)
        }
        let open=try await OpenAIProvider(key:"mock",session:session).translate(b,config:TranslationConfig(model:"gpt-4o-mini"))
        #expect(open.problem==nil && open.items.first?.id==b.targets[0].id)
        let azure=try await AzureProvider(key:"mock",session:session).translate(b,config:TranslationConfig())
        #expect(azure.problem==nil)
        let deep=try await DeepLProvider(key:"mock",session:session).translate(b,config:TranslationConfig())
        #expect(deep.problem==nil && calls==3)
    }
}
