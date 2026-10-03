import Foundation
import Testing
@testable import Core

private final class CompactMockProtocol:URLProtocol,@unchecked Sendable {
    nonisolated(unsafe) static var handler:((URLRequest)throws->Data)?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {let data=try Self.handler!(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["x-request-id":"mock-compact"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        }catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}
@Suite(.serialized) struct V085RequestTests {
    @Test func actualProviderUsesCompactSchemaFrozenLimitAndSingleRequest()async throws {
        let chunk=AnalysisChunk(id:"block",targets:[Cue(id:"a",start:0,end:1000,en:"Cash flow.")])
        let children=try HierarchicalAnalysis.build([.init(start:"c0001",title:"现金流",points:["说明"])],chunk:chunk)
        let sessionConfig=URLSessionConfiguration.ephemeral;sessionConfig.protocolClasses=[CompactMockProtocol.self]
        let session=URLSession(configuration:sessionConfig);defer{session.invalidateAndCancel();CompactMockProtocol.handler=nil}
        var calls=0
        CompactMockProtocol.handler={request in
            calls += 1
            let body=try ModelRequestTests().body(request)
            #expect(body["max_output_tokens"] as? Int==6000 && body["model"] as? String=="gpt-4o-mini")
            let format=(body["text"] as? [String:Any])?["format"] as? [String:Any]
            #expect(format?["name"] as? String=="lecture_compact_topics")
            let schema=try #require(format?["schema"] as? [String:Any]),encoded=try JSONSerialization.data(withJSONObject:schema)
            let text=String(decoding:encoded,as:UTF8.self)
            #expect(!text.contains("subtopics") && !text.contains("points"))
            let output=#"{"topics":[{"start":"p0001","title":"主题","summary":"概述"}],"overview":[{"text":"总结","source":"p0001"}]}"#
            return try JSONSerialization.data(withJSONObject:["status":"completed","usage":["input_tokens":40,"output_tokens":60],"output":[["content":[["type":"output_text","text":output]]]]])
        }
        var config=AnalysisConfig(model:"gpt-4o-mini");config.protocolVersion=3
        let r=try await OpenAIAnalysisProvider(key:"mock-only",session:session).synthesize(children,config:config)
        #expect(calls==1 && r.value?.chapters==children && r.result.requestID=="mock-compact")
    }
}
