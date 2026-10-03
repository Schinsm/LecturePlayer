import Foundation
import Testing
@testable import Core

@Suite struct V07CoreTests {
    func sample() throws -> Transcript {try SubtitleParser.parse(Data("WEBVTT\n\noriginal-1\n00:01.000 --> 00:02.000\nHello\n\noriginal-2\n00:03.000 --> 00:04.000\nNo loss\n".utf8),format:"vtt")}
    func legacy(_ t:Transcript) throws -> Transcript {
        var json=try JSONSerialization.jsonObject(with:Codec.encode(t)) as! [String:Any]
        json["schema"]=1;json.removeValue(forKey:"variants");json.removeValue(forKey:"activeVariantID")
        json["translations"]=try JSONSerialization.jsonObject(with:Codec.encode(t.translations))
        return try Codec.decode(Transcript.self,JSONSerialization.data(withJSONObject:json))
    }
    @Test func selectedSourceUsesItsOwnModelWhenGlobalProviderDiffers() {
        let name="LP07-config-\(UUID())",defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set("deepL",forKey:"translationService");defaults.set("gpt-4o-mini",forKey:"model")
        let open=TranslationPreferences.load(defaults,service:.openAI)
        #expect(open.providerID == .openAI && open.model=="gpt-4o-mini")
        #expect(TranslationPreferences.load(defaults,service:.apple).model=="apple-standard")
    }
    @Test func provenanceUnknownManualEditsAndLegacyBackup() throws {
        var t=try sample();var a=Translation(ai:"你好",cacheKey:"a");a.service = .azure;a.edited="人工中文";t.translations[t.cues[0].id]=a
        t.translations[t.cues[1].id]=Translation(ai:"历史",cacheKey:"unknown")
        var old=try legacy(t);let original=old
        try old.migrateVariants();try old.validate()
        #expect(old.schema==2 && old.allTranslatedCount==2)
        #expect(old.variants?["azure"]?.translations[t.cues[0].id]==a)
        #expect(old.variants?["legacy"]?.translations[t.cues[1].id]?.ai=="历史")
        #expect(old.cues==original.cues && old.original==original.original)
        var lib=Library();lib.schema=3;var b=Backup(library:lib,transcripts:["\(UUID())-\(t.version)":original]);b.schema=2;try b.validate()
        var future=b;future.schema=6;#expect(throws:(any Error).self){try future.validate()}
    }
    @Test func serviceVariantsDoNotBlockEachOtherOrChangeTiming() throws {
        var t=try sample();let id=t.cues[0].id;t.translations[id]=Translation(ai:"A",cacheKey:"same")
        var other=t.viewing("deepL");#expect(other.translatedCount==0)
        other.translations[id]=Translation(ai:"B",cacheKey:"same")
        #expect(other.viewing("openAI").translations[id]?.text=="A")
        var c=TranslationConfig();c.service = .deepL
        #expect(TranslationTaskState(transcript:other,ids:other.cues.map(\.id),config:c).batches(other).flatMap(\.targets).map(\.id)==[t.cues[1].id])
        #expect(other.cues==t.cues && other.target(t.cues[0],offset:14)==15)
        let round=try Codec.decode(Transcript.self,Codec.encode(other));#expect(round==other)
    }
    @Test func boundedProviderBatchingPreservesEveryCue() throws {
        let data=Data("fixture".utf8)
        let cues=(0..<73).map{Cue(id:"\($0)",start:$0*1000,end:$0*1000+900,en:String(repeating:"A",count:$0==34 ? 6000 : 240))}
        let t=Transcript(version:digest(data),original:data,format:"vtt",cues:cues)
        for service in [TranslationService.deepL,.apple] {
            var c=TranslationConfig();c.service=service;let b=c.batches(t)
            #expect(b.flatMap(\.targets)==cues)
            #expect(b.allSatisfy{$0.targets.count<=30 && ($0.targets.count==1 || $0.targets.reduce(0){$0+$1.en.unicodeScalars.count}<=5000)})
        }
    }
    @Test func deepLCountEmptyQuotaAuthRateAndUsage() throws {
        let t=try sample()
        func decode(_ rows:[[String:Any]]) throws -> TranslationResult {DeepLProvider.decode(try JSONSerialization.data(withJSONObject:["translations":rows]),targets:t.cues,status:200,requestID:"safe-request")}
        let result=try decode([["text":"你好","billed_characters":5],["text":"不丢失","billed_characters":7]])
        #expect(result.meteredCharacters==12 && result.items.map(\.id)==t.cues.map(\.id))
        #expect(TranslationAssessment(result.items,targets:t.cues).complete)
        #expect(try decode([["text":"漏项"]]).problem != nil)
        #expect(try decode([]).meteredCharacters==nil)
        let empty=try decode([["text":"有效"],["text":"  "]]);#expect(TranslationAssessment(empty.items,targets:t.cues).accepted.count==1)
        for status in [401,403,429,456,500] {let r=DeepLProvider.decode(Data("{}".utf8),targets:t.cues,status:status);#expect(r.problem != nil && r.items.isEmpty && r.meteredCharacters==nil)}
        #expect(DeepLProvider.decode(Data("{".utf8),targets:t.cues,status:200).problem != nil)
    }
    @Test func appleIdentifierOrderLanguageDuplicateAndEmpty() throws {
        let t=try sample()
        func item(_ i:Int,_ text:String="中文",_ language:String="zh") -> LocalTranslationResponse {LocalTranslationResponse(id:t.cues[i].id,source:t.cues[i].en,text:text,targetLanguage:language)}
        let r=LocalTranslationValidator.result([item(1),item(0)],targets:t.cues)
        #expect(TranslationAssessment(r.items,targets:t.cues).complete)
        #expect(LocalTranslationValidator.result([item(0),item(1,"中文","fr")],targets:t.cues).problem != nil)
        #expect(!TranslationAssessment(LocalTranslationValidator.result([item(0),item(0)],targets:t.cues).items,targets:t.cues).complete)
        #expect(!TranslationAssessment(LocalTranslationValidator.result([item(0),item(1,"")],targets:t.cues).items,targets:t.cues).complete)
    }
    @Test func providerFilesUseScreenDirectoryAndProtectEdits() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("variants-\(UUID())")
        for part in ["screen","camera","sub"] {try FileManager.default.createDirectory(at:root.appendingPathComponent(part),withIntermediateDirectories:true)}
        var t=try sample();t.translations[t.cues[0].id]=Translation(ai:"一",cacheKey:"a")
        let subtitle=root.appendingPathComponent("sub/original.vtt");try t.original.write(to:subtitle)
        var l=Lecture(title:"test",courseID:UUID(),folderID:nil,url:root.appendingPathComponent("screen/s1.mp4"),bookmark:nil,identity:"screen")
        l.sidecars=try SidecarWriter.write(t,lesson:l,beside:subtitle)
        let first=try #require(l.sidecars?.keys.first{$0.hasSuffix("zh.vtt")});#expect(first.contains("/screen/") && first.contains(".openai."))
        let originalFile=try Data(contentsOf:URL(fileURLWithPath:first));let parsed=try SubtitleParser.parse(originalFile,format:"vtt");#expect(parsed.cues[0].sourceID=="original-1" && parsed.cues[0].start==1000)
        t=t.viewing("deepL");t.translations[t.cues[0].id]=Translation(ai:"第二版本",cacheKey:"b")
        l.sidecars=try SidecarWriter.write(t,lesson:l,beside:subtitle)
        #expect(l.sidecars?.count==4 && l.sidecars!.keys.contains{$0.contains(".deepl.")})
        #expect(try Data(contentsOf:URL(fileURLWithPath:first))==originalFile)
        let second=try #require(l.sidecars?.keys.first{$0.contains(".deepl.") && $0.hasSuffix("zh.vtt")});try Data("USER EDIT".utf8).write(to:URL(fileURLWithPath:second))
        t.translations[t.cues[1].id]=Translation(ai:"新句",cacheKey:"c");let files=try SidecarWriter.write(t,lesson:l,beside:subtitle)
        let edited=String(data:try Data(contentsOf:URL(fileURLWithPath:second)),encoding:.utf8)
        #expect(files.count==5 && edited=="USER EDIT")
        #expect(try ImportPlanner.scan([root]).count==1)
    }
}

private final class DeepLMockProtocol:URLProtocol,@unchecked Sendable {
    static var seen:[URLRequest]=[]
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.seen.append(request)
        let text=request.url!.lastPathComponent=="usage" ? "{\"character_count\":12,\"character_limit\":500000}" : "{\"translations\":[{\"text\":\"你好\",\"billed_characters\":5},{\"text\":\"不丢失\",\"billed_characters\":7}]}"
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(text.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
@Suite(.serialized) struct V07NetworkTests {
    @Test func onlyFreeEndpointAndExplicitAccountRefresh() async throws {
        DeepLMockProtocol.seen=[]
        let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[DeepLMockProtocol.self]
        let session=URLSession(configuration:c);defer{session.invalidateAndCancel()}
        let provider=DeepLProvider(key:"MOCK_ONLY",session:session),t=try V07CoreTests().sample()
        var config=TranslationConfig();config.service = .deepL
        _=try await provider.translate(config.batches(t)[0],config:config)
        #expect(DeepLMockProtocol.seen.count==1)
        let request=try #require(DeepLMockProtocol.seen.first)
        #expect(request.url?.absoluteString=="https://api-free.deepl.com/v2/translate")
        #expect(request.value(forHTTPHeaderField:"Authorization")=="DeepL-Auth-Key MOCK_ONLY")
        let account=try await provider.accountUsage();#expect(account.characters==12 && account.limit==500000)
        #expect(DeepLMockProtocol.seen.count==2 && DeepLMockProtocol.seen[1].url?.lastPathComponent=="usage")
    }
}
