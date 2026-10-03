import Foundation
import Testing
@testable import Core

private actor TestProvider:TranslationProvider {
    var calls=0
    let kind:String
    init(_ kind:String="success"){self.kind=kind}
    func translate(_ batch:TranslationBatch,config:TranslationConfig) async throws -> TranslationResult {
        calls += 1
        #expect(batch.targets.count==1 && batch.targets[0].en==ServiceTest.sample)
        #expect(batch.context.isEmpty)
        if kind=="timeout" {throw URLError(.timedOut)}
        if kind=="cancel" {throw CancellationError()}
        return TranslationResult(items:kind=="success" ? [.init(id:batch.targets[0].id,zh:"你好，这是翻译连接测试。")] : [],inputTokens:7,outputTokens:3,problem:kind=="failed" ? "认证失败" : nil)
    }
}
@Suite struct V071Tests {
    @Test func regionNormalizationAndLegacySelection() throws {
        #expect(try AzureRegion.normalize(" AustraliaEast \n")=="australiaeast")
        #expect(AzureRegion.selection("GLOBAL")=="global")
        #expect(AzureRegion.selection("eastus")=="other")
        #expect(throws:(any Error).self){try AzureRegion.normalize("Australia East")}
        #expect(throws:(any Error).self){try AzureRegion.normalize("")}
    }
    @Test(arguments:["success","failed","missing","timeout","cancel"])
    func oneRequestNoRetry(_ kind:String) async throws {
        let provider=TestProvider(kind)
        let result=try await ServiceTest.run(config:TranslationConfig(model:"gpt-4o-mini"),provider:provider)
        #expect(await provider.calls==1)
        #expect(result.success == (kind=="success"))
        #expect(result.usage.attemptID==result.id)
        if kind=="timeout" || kind=="cancel" {#expect(result.usage.inputTokens==nil)}
        else {#expect(result.usage.inputTokens==7 && result.usage.outputTokens==3)}
        #expect((result.translation != nil)==result.success)
    }
    @Test func isolatedLedgerPreservesRetriesAndNoCourseFiles() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let config=TranslationConfig(model:"gpt-4o-mini")
        let first=try await ServiceTest.run(config:config,provider:TestProvider())
        let second=try await ServiceTest.run(config:config,provider:TestProvider("failed"))
        try await ServiceTestLedger.shared.append(first,root:root)
        try await ServiceTestLedger.shared.append(second,root:root)
        let records=try ServiceTestLedger.read(root:root)
        #expect(records.count==2 && records[0].id != records[1].id)
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path)==["service-tests.json"])
        #expect(UsageSummary(records.map(\.usage)).requests==2)
    }
    @Test func calendarAcrossDSTAndMonthlyBoundaries() throws {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Australia/Melbourne")!
        let now=calendar.date(from:DateComponents(year:2026,month:10,day:5,hour:12))!
        let days=UsageAggregation.days(now:now,calendar:calendar)
        #expect(days.count==364 && Set(days).count==364)
        #expect(days.last==calendar.startOfDay(for:now))
        let previous=calendar.date(from:DateComponents(year:2026,month:9,day:30,hour:23))!
        #expect(!UsagePeriod.month.includes(previous,now:now,calendar:calendar))
        let u=TranslationUsage(result:TranslationResult(items:[],inputTokens:10,outputTokens:4,reasoningTokens:2),config:TranslationConfig(model:"gpt-4o-mini"),descriptor:try TranslationConfig(model:"gpt-4o-mini").usageDescriptor(),batchKey:"retry")
        #expect(UsageAggregation.buckets([u,u],component:.day,calendar:calendar).first?.values.count==2)
        #expect(UsageSummary([u]).input+UsageSummary([u]).output==14)
    }
    @Test func failedLedgerWriteDoesNotResend() async throws {
        let provider=TestProvider();let value=try await ServiceTest.run(config:TranslationConfig(model:"gpt-4o-mini"),provider:provider)
        do {try await ServiceTestLedger.shared.append(value,root:URL(fileURLWithPath:"/nonexistent-LecturePlayer-test"));Issue.record("Expected missing root failure")}catch{}
        #expect(await provider.calls==1)
    }
}

extension ModelRequestTests {
    @Test(arguments:[200,401,403,429,500])
    func serviceTestUsesAzureRegionAndReportsHTTP(_ status:Int) async throws {
        ModelMockProtocol.handler={request in
            #expect(request.value(forHTTPHeaderField:"Ocp-Apim-Subscription-Region")=="australiaeast")
            let body=status==200 ? #"[{"translations":[{"to":"zh-Hans","text":"你好"}]}]"# : #"{"error":{"code":403001}}"#
            return (status,Data(body.utf8))
        }
        let session=URLSessionConfiguration.ephemeral;session.protocolClasses=[ModelMockProtocol.self]
        var config=TranslationConfig();config.service = .azure;config.azureRegion=" AustraliaEast "
        let result=try await ServiceTest.run(config:config,provider:AzureProvider(key:"MOCK",session:URLSession(configuration:session),pacer:AzurePacer()))
        #expect(result.success == (status==200))
        #expect(result.usage.service == .azure && result.usage.inputTokens==nil)
        #expect(result.usage.submittedCharacters==ServiceTest.sample.utf16.count)
    }
}
