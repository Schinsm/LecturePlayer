import Foundation

public enum AzureRegion {
    public static func normalize(_ value:String) throws -> String {
        let code=value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard code.range(of:"^[a-z0-9]+(?:-[a-z0-9]+)*$",options:.regularExpression) != nil else {throw Failure("请填写 Azure 门户中的区域代码，例如 australiaeast；不要填写带空格的显示名称。")}
        return code
    }
    public static func selection(_ value:String)->String {
        let code=(try? normalize(value)) ?? value
        return ["global","australiaeast"].contains(code) ? code : "other"
    }
}
public struct ServiceTestResult:Codable,Identifiable,Sendable {
    public var id:UUID;public var date:Date;public var service:TranslationService
    public var configuration:TranslationConfig;public var success:Bool;public var message:String
    public var translation:String?;public var seconds:Double;public var usage:TranslationUsage
    public var requestID:String?
}
public enum ServiceTest {
    public static let sample="Hello. This is a translation connection test."
    public static func batch() throws -> TranslationBatch {
        let text="WEBVTT\n\nconnection-test\n00:00.000 --> 00:01.000\n"+sample+"\n"
        return TranslationBatch.make(try SubtitleParser.parse(Data(text.utf8),format:"vtt"))[0]
    }
    public static func run(config:TranslationConfig,provider:any TranslationProvider) async throws -> ServiceTestResult {
        let batch=try batch(),descriptor=try config.usageDescriptor(),id=UUID(),start=Date()
        try Task.checkCancellation()
        let response:TranslationResult
        do {response=try await provider.translate(batch,config:config)}
        catch {response=(error as? APIError)?.result ?? TranslationResult(items:[],problem: error is CancellationError || (error as? URLError)?.code == .cancelled ? "测试已取消；已发送请求的用量可能未知。" : (error as? URLError)?.code == .timedOut ? "连接超时；请求可能已计费，没有自动重试。" : "网络或服务失败，原因未确认；请检查网络和服务配置。")}
        let assessment=TranslationAssessment(response.items,targets:batch.targets)
        let success=response.problem == nil && assessment.complete
        var usage=TranslationUsage(result:response,config:config,descriptor:descriptor,batchKey:"connection-test-"+id.uuidString)
        usage.attemptID=id;usage.submittedCharacters=config.providerID == .azure ? sample.utf16.count : sample.unicodeScalars.count
        return ServiceTestResult(id:id,date:start,service:config.providerID,configuration:config,success:success,message:response.problem ?? (success ? "连接成功，已完成测试翻译。" : "服务已响应，但译文不完整或格式异常。"),translation:success ? assessment.accepted.first?.zh : nil,seconds:Date().timeIntervalSince(start),usage:usage,requestID:response.requestID)
    }
}
public actor ServiceTestLedger {
    public static let shared=ServiceTestLedger()
    public func append(_ result:ServiceTestResult,root:URL) throws {
        let file=root.appendingPathComponent("service-tests.json")
        var records=try Self.read(root:root);records.append(result)
        try Codec.encode(records).write(to:file,options:.atomic)
    }
    public static func read(root:URL) throws -> [ServiceTestResult] {
        let file=root.appendingPathComponent("service-tests.json")
        return FileManager.default.fileExists(atPath:file.path) ? try Codec.decode([ServiceTestResult].self,Data(contentsOf:file)) : []
    }
}
public struct UsageBucket:Identifiable {public var id:Date{date};public var date:Date;public var values:[TranslationUsage]}
public enum UsageAggregation {
    public static func buckets(_ values:[TranslationUsage],component:Calendar.Component,calendar:Calendar = .current)->[UsageBucket] {
        Dictionary(grouping:values){calendar.dateInterval(of:component,for:$0.date)?.start ?? $0.date}.map{UsageBucket(date:$0.key,values:$0.value)}.sorted{$0.date<$1.date}
    }
    public static func days(now:Date=Date(),calendar:Calendar = .current)->[Date] {
        let today=calendar.startOfDay(for:now)
        return (-363...0).compactMap{calendar.date(byAdding:.day,value:$0,to:today)}
    }
}
