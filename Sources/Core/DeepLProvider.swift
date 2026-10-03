import Foundation

public struct DeepLAccountUsage:Sendable {
    public let characters:Int; public let limit:Int;public let date:Date
    public init(characters:Int,limit:Int,date:Date=Date()){self.characters=characters;self.limit=limit;self.date=date}
}
public struct DeepLProvider:TranslationProvider {
    private let key:String;private let session:URLSession;private let gate:TranslationRequestGate?
    public init(key:String,session:URLSession = .shared,gate:TranslationRequestGate?=nil){self.key=key;self.session=session;self.gate=gate}
    private func request(_ path:String)->URLRequest {
        var r=URLRequest(url:URL(string:"https://api-free.deepl.com/v2/"+path)!);r.timeoutInterval=90
        r.setValue("DeepL-Auth-Key "+key,forHTTPHeaderField:"Authorization");r.setValue("application/json",forHTTPHeaderField:"Content-Type");return r
    }
    public func translate(_ batch:TranslationBatch,config:TranslationConfig) async throws -> TranslationResult {
        let batch=batch.withoutSpeakerLabels()
        var r=request("translate");r.httpMethod="POST"
        r.httpBody=try JSONSerialization.data(withJSONObject:["text":batch.targets.map(\.en),"source_lang":"EN","target_lang":"ZH-HANS","context":batch.context.map(\.en).joined(separator:"\n"),"show_billed_characters":true])
        guard batch.targets.count<=50,(r.httpBody?.count ?? 0)<128*1024 else{throw Failure("单条字幕超过 DeepL 请求大小限制，尚未发送")}
        if gate?.paused==true {throw TranslationNotSent()};try Task.checkCancellation()
        let (data,response)=try await session.data(for:r)
        guard let http=response as? HTTPURLResponse else{throw Failure("DeepL 未返回有效响应")}
        return Self.decode(data,targets:batch.targets,status:http.statusCode,requestID:http.value(forHTTPHeaderField:"x-request-id"))
    }
    public static func decode(_ data:Data,targets:[Cue],status:Int,requestID:String?=nil)->TranslationResult {
        var metered:Int?
        let safe=requestID.flatMap{$0.count<=128 && $0.range(of:"^[a-zA-Z0-9_-]+$",options:.regularExpression) != nil ? $0 : nil}
        func result(_ items:[TranslatedItem]=[],_ error:String?=nil)->TranslationResult {
            var r=TranslationResult(items:items,problem:error,requestID:safe,diagnostics:TranslationDiagnostics(status:error==nil ? "completed" : "failed",model:"deepL-standard",outputBytes:data.count,httpStatus:status));r.meteredCharacters=metered;return r
        }
        guard (200..<300).contains(status) else{return result([],status==456 ? "DeepL 免费额度已用完；请查看账户，不会切换收费端点。" : status==429 ? "DeepL 请求受限，请稍后手动继续。" : status==401 || status==403 ? "DeepL Key 或套餐不适用于 API Free，请检查设置。" : "DeepL 请求失败（HTTP \(status)），未自动重试。")}
        guard let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let rows=root["translations"] as? [[String:Any]] else{return result([],"DeepL 格式无法解析，本组未保存")}
        let costs=rows.compactMap{$0["billed_characters"] as? Int};if !rows.isEmpty && costs.count==rows.count && costs.allSatisfy({$0>=0}) {metered=costs.reduce(0,+)}
        guard rows.count==targets.count else{return result([],"DeepL 返回数量与字幕不一致，本组未保存")}
        var items:[TranslatedItem]=[]
        for (i,row) in rows.enumerated() {guard let text=row["text"] as? String else{return result([],"DeepL 返回格式不正确，本组未保存")};if let language=row["detected_source_language"] as? String,language.uppercased() != "EN" {return result([],"DeepL 源语言与英文字幕不符，本组未保存")};items.append(TranslatedItem(id:targets[i].id,zh:text))}
        return result(items)
    }
    public func accountUsage() async throws -> DeepLAccountUsage {
        let (data,response)=try await session.data(for:request("usage"))
        guard let http=response as? HTTPURLResponse,http.statusCode==200,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],let count=root["character_count"] as? Int,let limit=root["character_limit"] as? Int,count>=0,limit>=0 else{throw Failure("无法读取 DeepL Free 账户用量，请检查 Key 和套餐；没有发起翻译")}
        return DeepLAccountUsage(characters:count,limit:limit)
    }
}
