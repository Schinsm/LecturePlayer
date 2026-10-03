import Foundation
import Testing
@testable import Core

struct V06Tests {
    @Test func legacyConfigAndUsageKeepUnknownFields() throws {
        let config=try Codec.decode(TranslationConfig.self,Data(#"{"model":"gpt-4o-mini","effort":"none","glossary":"","promptVersion":"faithful-zh-1","language":"zh-Hans"}"#.utf8))
        #expect(config.providerID == .openAI && config.parallelism==1)
        let t=try CoreTests().parsed();let old=Translation(ai:"已有",cacheKey:"legacy")
        let data=try Codec.encode(old);#expect(try Codec.decode(Translation.self,data)==old)
        var azure=config;azure.service = .azure
        #expect(try TranslationBatch.make(t)[0].key(config) != TranslationBatch.make(t)[0].key(azure))
    }
    @Test func azureBatchUTF16NoLossAndOversizeSingleCue() {
        let cues=(0..<205).map{Cue(id:"\($0)",start:$0*1000,end:$0*1000+900,en:String(repeating:"😀",count:30))}
        let t=Transcript(version:"x",original:Data(),format:"vtt",cues:cues)
        var c=TranslationConfig();c.service = .azure;c.accelerated=true
        let b=c.batches(t)
        #expect(c.parallelism==1 && b.flatMap(\.targets)==cues)
        #expect(b.allSatisfy{$0.targets.count<=100 && $0.targets.reduce(0){$0+$1.en.utf16.count}<=5000})
        var long=t;long.cues=[Cue(id:"huge",start:0,end:1,en:String(repeating:"a",count:6000))]
        #expect(c.batches(long).count==1)
    }
    @Test func azureMapsByPositionAndRejectsMismatchLanguage() throws {
        let t=try CoreTests().parsed()
        let good=try JSONSerialization.data(withJSONObject:t.cues.enumerated().map{["translations":[["to":"zh-Hans","text":"中文\($0.offset)"]]]})
        let result=AzureProvider.decode(good,targets:t.cues,status:200,metered:12)
        #expect(result.items.map(\.id)==t.cues.map(\.id) && result.meteredCharacters==12)
        #expect(AzureProvider.decode(Data("[]".utf8),targets:t.cues,status:200).problem != nil)
        let wrong=Data(String(decoding:good,as:UTF8.self).replacingOccurrences(of:"zh-Hans",with:"de").utf8)
        #expect(AzureProvider.decode(wrong,targets:t.cues,status:200).items.isEmpty)
        let empty=try JSONSerialization.data(withJSONObject:t.cues.map{_ in ["translations":[["to":"zh-Hans","text":""]]]})
        #expect(TranslationAssessment(AzureProvider.decode(empty,targets:t.cues,status:200).items,targets:t.cues).empty==t.cues.count)
    }
    @Test func azureErrorsNoRawBodyLeak() {
        for (status,code,text) in [(401,401000,"Key"),(403,403001,"免费额度"),(429,429001,"受限"),(503,503000,"HTTP 503")] {
            let data=Data("{\"error\":{\"code\":\(code),\"message\":\"SECRET\"}}".utf8)
            let r=AzureProvider.decode(data,targets:[],status:status,requestID:"req_123")
            #expect(r.problem?.contains(text)==true && r.requestID=="req_123" && r.meteredCharacters==nil)
            #expect(r.problem?.contains("SECRET")==false)
        }
    }
    @Test func failedIDsUnionAcrossParallelBatches() throws {
        let t=try CoreTests().parsed();var task=TranslationTaskState(transcript:t,ids:t.cues.map(\.id),config:TranslationConfig())
        for b in TranslationBatch.make(t,maxCues:1){task.failed(b,transcript:t)}
        #expect(Set(task.failedIDs)==Set(t.cues.map(\.id)))
    }
    @Test func usageCountsRetriesUnknownAndReasoningOnlyOnce() throws {
        let c=TranslationConfig(model:"gpt-4o-mini"),desc=try c.descriptor()
        var r=TranslationResult(items:[],inputTokens:100,outputTokens:50,reasoningTokens:20);r.cachedInputTokens=60
        let u=TranslationUsage(result:r,config:c,descriptor:desc,batchKey:"same")
        var azure=c;azure.service = .azure
        var a=TranslationResult(items:[]);a.meteredCharacters=400
        let au=TranslationUsage(result:a,config:azure,descriptor:try azure.usageDescriptor(),batchKey:"a")
        let unknown=TranslationUsage(result:TranslationResult(items:[]),config:c,descriptor:desc,batchKey:"same")
        let s=UsageSummary([u,u,unknown,au])
        #expect(s.requests==4 && s.unknown==1 && s.output==100 && s.reasoning==40 && s.cached==120 && s.characters==400)
        #expect(au.estimatedUSD==nil)
        #expect(try Codec.decode(TranslationUsage.self,Codec.encode(u)).inputTokens==100)
    }
    @Test func localCalendarMonthAndDay() {
        var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:36000)!
        let now=ISO8601DateFormatter().date(from:"2026-09-30T14:05:00Z")!,before=now.addingTimeInterval(-600)
        #expect(!UsagePeriod.month.includes(before,now:now,calendar:cal))
        #expect(!UsagePeriod.today.includes(before,now:now,calendar:cal))
        #expect(UsagePeriod.all.includes(before,now:now,calendar:cal))
    }
}
// Share the existing serialized network suite, avoiding global URLProtocol handler races.
extension ModelRequestTests {
    @Test func pausedAzureGateDoesNotReachHTTP() async throws {
        let t=try CoreTests().parsed(),gate=TranslationRequestGate();gate.setPaused(true)
        ModelMockProtocol.handler={_ in Issue.record("Paused request reached network");return (500,Data())}
        let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[ModelMockProtocol.self]
        let p=AzureProvider(key:"MOCK",session:URLSession(configuration:c),pacer:AzurePacer(),gate:gate)
        var config=TranslationConfig();config.service = .azure
        do {_ = try await p.translate(config.batches(t)[0],config:config);Issue.record("Expected pause")}
        catch is TranslationNotSent {} catch {Issue.record("Unexpected error")}
    }
    @Test func cachedAndReasoningTokensParsedWithoutDoubleCounting() throws {
        let r=try OpenAIProvider.decode(Data(#"{"status":"incomplete","usage":{"input_tokens":120,"output_tokens":50,"input_tokens_details":{"cached_tokens":100},"output_tokens_details":{"reasoning_tokens":30}},"incomplete_details":{"reason":"max_output_tokens"}}"#.utf8),targets:[])
        #expect(r.cachedInputTokens==100 && r.reasoningTokens==30 && r.outputTokens==50 && r.problem != nil)
    }
    @Test func azureWireAuthenticationAndMeteringWithMock() async throws {
        let t=try CoreTests().parsed()
        for region in ["global","australiaeast"] {
            ModelMockProtocol.handler={req in
                #expect(req.url?.host=="api.cognitive.microsofttranslator.com")
                #expect(req.url?.query?.contains("to=zh-Hans")==true)
                #expect(req.value(forHTTPHeaderField:"Ocp-Apim-Subscription-Key")=="MOCK-AZURE")
                #expect(req.value(forHTTPHeaderField:"Ocp-Apim-Subscription-Region")==((region=="global") ? nil : region))
                return (200,try JSONSerialization.data(withJSONObject:t.cues.map{_ in ["translations":[["to":"zh-Hans","text":"中文"]]]}))
            }
            let sessionConfig=URLSessionConfiguration.ephemeral;sessionConfig.protocolClasses=[ModelMockProtocol.self]
            let provider=AzureProvider(key:"MOCK-AZURE",session:URLSession(configuration:sessionConfig),pacer:AzurePacer())
            var config=TranslationConfig();config.service = .azure;config.azureRegion=region
            let r=try await provider.translate(config.batches(t)[0],config:config)
            #expect(r.items.count==t.cues.count && r.problem==nil)
        }
    }
}
