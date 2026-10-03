import Foundation

public enum TranslationService: String, Codable, CaseIterable, Sendable {
    case openAI, azure, deepL, apple
    public var title: String {switch self {case .openAI:return "OpenAI";case .azure:return "Azure";case .deepL:return "DeepL";case .apple:return "Apple 本机"}}
    public var needsKey:Bool {self != .apple}
}
public extension TranslationConfig {
    var displayModel: String {providerID == .openAI ? (TranslationModelCatalog.find(model)?.displayName ?? model) : providerID == .apple ? "设备语言模型 · 英文 → 简体中文" : "Standard · 英文 → 简体中文"}
    var confirmationLabel:String {providerID == .openAI ? "确认付费翻译" : providerID == .apple ? "开始本机翻译" : "确认使用 \(providerID.title) 翻译"}
    func usageDescriptor() throws -> TranslationModelDescriptor {
        if providerID == .openAI {return try descriptor()}
        return TranslationModelDescriptor(id:providerID.rawValue+"-standard",displayName:providerID.title,description:"按服务统计",supportsReasoning:false,defaultReasoning:.none,pricing:TokenPricing(inputPerMillion:0,outputPerMillion:0,checkedDate:"2026-09-18",sourceURL:"https://azure.microsoft.com/en-us/pricing/details/translator/"))
    }
    var parallelism: Int { providerID == .openAI && accelerated == true ? 2 : 1 }
    func batches(_ transcript: Transcript, ids: Set<String>? = nil) -> [TranslationBatch] {
        switch providerID {
        case .azure:return TranslationBatch.make(transcript,ids:ids,budget:5000,maxCues:100,utf16:true)
        case .deepL,.apple:return TranslationBatch.make(transcript,ids:ids,budget:5000,maxCues:30,unicodeScalars:true)
        case .openAI:return TranslationBatch.make(transcript,ids:ids)
        }
    }
    func estimate(_ batches: [TranslationBatch]) throws -> String {
        if providerID == .azure {
            return "本次提交约 \(batches.flatMap(\.targets).reduce(0) { $0 + $1.en.utf16.count }) 字符。F0 额度内免费；应用无法核验账户套餐及剩余额度，请确认资源为 F0。"
        }
        if providerID == .deepL {return "本次约 \(batches.flatMap(\.targets).reduce(0){$0+$1.en.unicodeScalars.count}) 字符，仅使用 API Free 端点；额度以账户为准，到限额停止。"}
        if providerID == .apple {return "在本机处理约 \(batches.flatMap(\.targets).reduce(0){$0+$1.en.unicodeScalars.count}) 字符，无云 API 费用；首次可能需要确认下载语言资源。"}
        return try TranslationCostEstimate(batches: batches, config: self, model: descriptor()).summary
    }
}
public actor AzurePacer {
    public static let shared = AzurePacer()
    private var next = Date.distantPast
    public init() {}
    public func wait(characters: Int) async throws {
        let now = Date(), start = max(now, next)
        next = start.addingTimeInterval(Double(characters) / 500)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
    }
}
public struct TranslationNotSent: Error, Sendable {}
public final class TranslationRequestGate: @unchecked Sendable {
    private let lock=NSLock();private var stopped=false
    public init(){}
    public func setPaused(_ value:Bool){lock.lock();stopped=value;lock.unlock()}
    public var paused:Bool {lock.lock();defer{lock.unlock()};return stopped}
}
public struct AzureProvider: TranslationProvider {
    private let key: String; private let session: URLSession; private let pacer: AzurePacer;private let gate:TranslationRequestGate?
    public init(key: String, session: URLSession = .shared, pacer: AzurePacer = .shared,gate:TranslationRequestGate?=nil) { self.key=key;self.session=session;self.pacer=pacer;self.gate=gate }
    public func translate(_ batch: TranslationBatch, config: TranslationConfig) async throws -> TranslationResult {
        let batch=batch.withoutSpeakerLabels()
        let chars=batch.targets.reduce(0) { $0 + $1.en.utf16.count }
        guard chars <= 50000, batch.targets.count <= 1000 else { throw Failure("单条字幕超出 Azure 请求限制，请检查原字幕；尚未发送") }
        let region=try AzureRegion.normalize(config.azureRegion ?? "global")
        guard region.range(of:"^[a-zA-Z0-9-]+$",options:.regularExpression) != nil else { throw Failure("请填写正确的 Azure 资源区域") }
        try await pacer.wait(characters:chars)
        if gate?.paused == true {throw TranslationNotSent()}
        var req=URLRequest(url:URL(string:"https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&from=en&to=zh-Hans")!)
        req.httpMethod="POST";req.timeoutInterval=90
        req.setValue(key,forHTTPHeaderField:"Ocp-Apim-Subscription-Key")
        if region.lowercased() != "global" {req.setValue(region,forHTTPHeaderField:"Ocp-Apim-Subscription-Region")}
        req.setValue("application/json; charset=UTF-8",forHTTPHeaderField:"Content-Type")
        req.setValue(UUID().uuidString,forHTTPHeaderField:"X-ClientTraceId")
        req.httpBody=try JSONSerialization.data(withJSONObject:batch.targets.map{["Text":$0.en]})
        let (data,response)=try await session.data(for:req)
        guard let http=response as? HTTPURLResponse else {throw Failure("Azure 未返回有效响应")}
        return Self.decode(data,targets:batch.targets,status:http.statusCode,requestID:http.value(forHTTPHeaderField:"X-requestid"),metered:http.value(forHTTPHeaderField:"X-metered-usage").flatMap(Int.init))
    }
    public static func decode(_ data:Data, targets:[Cue], status:Int, requestID:String?=nil, metered:Int?=nil)->TranslationResult {
        let safe=requestID.flatMap { $0.count<=128 && $0.range(of:"^[a-zA-Z0-9_-]+$",options:.regularExpression) != nil ? $0 : nil }
        func result(_ items:[TranslatedItem]=[],_ problem:String?=nil)->TranslationResult {
            var r=TranslationResult(items:items,problem:problem,requestID:safe,diagnostics:TranslationDiagnostics(status:problem == nil ? "completed" : "failed",model:"standard",outputBytes:data.count,httpStatus:status));r.meteredCharacters=metered.flatMap{$0>=0 ? $0 : nil};return r
        }
        let json=try? JSONSerialization.jsonObject(with:data)
        if !(200..<300).contains(status) {
            let code=((json as? [String:Any])?["error"] as? [String:Any])?["code"] as? Int
            let reason=code == 403001 ? "免费额度已用完，请查看 Azure 账户" : status == 401 ? "Key 或资源区域不正确，请检查设置" : status == 429 ? "请求暂时受限，请稍后手动继续" : "请求失败（HTTP \(status)），请查看设置或稍后重试"
            return result([],"Azure："+reason)
        }
        guard let rows=json as? [[String:Any]],rows.count==targets.count else {return result([],"Azure 返回数量与字幕不一致，本组未保存")}
        var items:[TranslatedItem]=[]
        for (index,row) in rows.enumerated() {
            guard let values=row["translations"] as? [[String:Any]],values.count==1,values[0]["to"] as? String == "zh-Hans",let zh=values[0]["text"] as? String else {return result([],"Azure 响应格式或目标语言不正确，本组未保存")}
            items.append(TranslatedItem(id:targets[index].id,zh:zh))
        }
        return result(items)
    }
}
public enum UsagePeriod: String, CaseIterable, Sendable { case today="今天",month="本月",all="全部"
    public func includes(_ date:Date,now:Date=Date(),calendar:Calendar = .current)->Bool {
        switch self {case .all:return true;case .today:return calendar.isDate(date,inSameDayAs:now);case .month:return calendar.isDate(date,equalTo:now,toGranularity:.month)}
    }
}
public struct UsageSummary: Sendable {
    public var requests=0,unknown=0,input=0,output=0,cached=0,reasoning=0,characters=0,estimatedCharacters=0,localCharacters=0
    public var usd=0.0
    public init(_ entries:[TranslationUsage]) {
        for u in entries {
            requests += 1
            if u.service == .apple {localCharacters += u.submittedCharacters ?? 0}
            else if (u.service ?? .openAI) != .openAI {
                if let c=u.meteredCharacters {characters += c} else {unknown += 1;estimatedCharacters += u.submittedCharacters ?? 0}
            } else {
                input += u.inputTokens ?? 0;output += u.outputTokens ?? 0;cached += u.cachedInputTokens ?? 0;reasoning += u.reasoningTokens ?? 0
                usd += u.estimatedUSD ?? 0
                if u.inputTokens == nil || u.outputTokens == nil {unknown += 1}
            }
        }
    }
}
