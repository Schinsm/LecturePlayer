import Foundation
import Testing
@testable import Core

struct V053Tests {
    @Test func sourceAnchorRejectsIDSwapsAndKeepsCorrectItems() throws {
        let t=try CoreTests().parsed()
        for swap in [false,true] {
            let body:[String:Any] = ["translations":["c001":["source":t.cues[swap ? 1 : 0].en,"zh":"一"],"c002":["source":t.cues[swap ? 0 : 1].en,"zh":"二"]]]
            let text=String(data:try JSONSerialization.data(withJSONObject:body),encoding:.utf8)!
            let data=try JSONSerialization.data(withJSONObject:["status":"completed","output":[["content":[["type":"output_text","text":text]]]],"usage":["input_tokens":90,"output_tokens":20]])
            let result=try OpenAIProvider.decode(data,targets:t.cues,shortIDs:true)
            #expect((result.problem != nil)==swap)
            #expect(result.items.count == (swap ? 0 : 2) && result.inputTokens==90)
        }
    }
    @Test func singleCueTaskPersistsAndSkipsCache() throws {
        var t=try CoreTests().parsed();var task=TranslationTaskState(transcript:t,ids:t.cues.map(\.id),config:TranslationConfig())
        task.singleCue=true
        t.translations[t.cues[0].id]=Translation(ai:"already",cacheKey:"old")
        let round=try Codec.decode(TranslationTaskState.self,Codec.encode(task)),batches=round.batches(t)
        #expect(batches.count==1 && batches[0].targets.count==1 && batches[0].targets[0].id==t.cues[1].id)
    }
}
extension ModelRequestTests {
    @Test func anchoredRequestRequiresNonemptyTextAndExactSource() async throws {
        let t=try CoreTests().parsed(),b=TranslationBatch.make(t)[0]
        ModelMockProtocol.handler={request in
            var data=request.httpBody ?? Data()
            if let stream=request.httpBodyStream {stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:4096);while true{let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(buffer,count:n)}}
            let raw=String(decoding:data,as:UTF8.self)
            let schemaStart=try #require(raw.range(of:"\"text\":{\"format\":"))
            let schemaText=String(raw[schemaStart.lowerBound...])
            let first=try #require(schemaText.range(of:"\"c001\":{")),second=try #require(schemaText.range(of:"\"c002\":{"))
            #expect(first.lowerBound < second.lowerBound)
            let source=try #require(schemaText.range(of:"\"source\":{")),zh=try #require(schemaText.range(of:"\"zh\":{"))
            #expect(source.lowerBound < zh.lowerBound)
            let body=try #require(JSONSerialization.jsonObject(with:data) as? [String:Any]),format=try #require((body["text"] as? [String:Any])?["format"] as? [String:Any])
            let schema=try #require(format["schema"] as? [String:Any]),props=try #require(schema["properties"] as? [String:Any])
            let translations=try #require(props["translations"] as? [String:Any]),fields=try #require(translations["properties"] as? [String:[String:Any]])
            for (index,cue) in b.targets.enumerated(){
                let entry=try #require(fields[String(format:"c%03d",index+1)]),sub=try #require(entry["properties"] as? [String:[String:Any]])
                #expect(entry["required"] as? [String]==["source","zh"])
                #expect(sub["source"]?["enum"] as? [String]==[cue.en])
                #expect(sub["zh"]?["minLength"] as? Int==1 && sub["zh"]?["pattern"] as? String=="\\S")
            }
            let output=Dictionary(uniqueKeysWithValues:b.targets.enumerated().map{(String(format:"c%03d",$0.offset+1),["source":$0.element.en,"zh":"mock"])})
            let text=String(data:try JSONSerialization.data(withJSONObject:["translations":output]),encoding:.utf8)!
            return (200,try JSONSerialization.data(withJSONObject:["status":"completed","output":[["content":[["type":"output_text","text":text]]]]]))
        }
        let result=try await provider().translate(b,config:TranslationConfig(model:"gpt-4o-mini"))
        #expect(result.items.count==t.cues.count && result.problem==nil)
    }
}
