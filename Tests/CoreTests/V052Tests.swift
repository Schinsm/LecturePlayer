import Foundation
import Testing
@testable import Core

struct V052CoreTests {
    @Test func preciseIncompleteReasonAndUsage() throws {
        let t=try CoreTests().parsed()
        for (reason,description) in [("max_output_tokens","达到输出上限"),("content_filter","内容过滤"),("other","原因未知")] {
            let data=try JSONSerialization.data(withJSONObject:["status":"incomplete","incomplete_details":["reason":reason],"usage":["input_tokens":1138,"output_tokens":12000,"output_tokens_details":["reasoning_tokens":0]],"output":[["content":[["type":"output_text","text":"{unfinished"]]]]])
            let r=try OpenAIProvider.decode(data,targets:t.cues,model:"gpt-4o-mini")
            #expect(r.items.isEmpty && r.problem?.contains(description)==true && r.outputTokens==12000)
            #expect(r.diagnostics?.outputLimit==12000 && r.diagnostics?.outputBytes==11)
            #expect(r.diagnostics?.incompleteReason == (reason=="other" ? "unknown" : reason))
        }
    }
    @Test func httpDiagnosticsWithoutLeakingBody() throws {
        let r=try OpenAIProvider.decode(Data("{\"error\":{\"message\":\"PRIVATE BODY\"}}".utf8),targets:[],requestID:"req_test",model:"gpt-4o-mini",httpStatus:429)
        #expect(r.requestID=="req_test" && r.inputTokens==nil && r.diagnostics?.httpStatus==429)
        #expect(r.problem?.contains("PRIVATE")==false)
    }
    @Test func smallerBatchesAndPersistedScopeResume() throws {
        var t=try CoreTests().parsed();t.cues=(0..<32).map{Cue(id:"cue-\($0)",start:$0*1000,end:$0*1000+900,en:String(repeating:"a",count:220))}
        let batches=TranslationBatch.make(t)
        #expect(batches.allSatisfy{$0.targets.count<=10 && $0.targets.reduce(0){$0+$1.en.utf8.count}<=2000})
        #expect(batches.flatMap(\.targets)==t.cues)
        var task=TranslationTaskState(transcript:t,ids:t.cues.map(\.id),config:TranslationConfig(model:"gpt-4o-mini"))
        task.failed(batches[0],transcript:t)
        #expect(task.retrySize==5)
        t.translations[t.cues[0].id]=Translation(ai:"saved",cacheKey:"legacy")
        let restored=try Codec.decode(TranslationTaskState.self,Codec.encode(task))
        let retry=restored.batches(t)
        #expect(retry[0].targets.count==5 && retry.flatMap(\.targets).count==31)
        #expect(!retry.flatMap(\.targets).contains{$0.id==t.cues[0].id})
        task.failed(retry[0],transcript:t);#expect(task.retrySize==1)
        #expect(task.batches(t)[0].targets.count==1)
    }
}
