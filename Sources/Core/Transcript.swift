import Foundation

public struct Cue: Codable, Identifiable, Equatable, Sendable {
    public var id: String; public var sourceID: String?; public var start: Int; public var end: Int; public var en: String
    public init(id: String, sourceID: String? = nil, start: Int, end: Int, en: String) { self.id = id; self.sourceID = sourceID; self.start = start; self.end = end; self.en = en }
}
public struct Translation: Codable, Equatable, Sendable {
    public var service: TranslationService?; public var model: String?
    public var ai: String; public var edited: String?; public var cacheKey: String
    public var text: String { edited ?? ai }
    public init(ai: String, cacheKey: String) { self.ai = ai; self.cacheKey = cacheKey }
}
public struct TranslationVariant: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var service: TranslationService?
    public var translations: [String: Translation] = [:]
    public var task: TranslationTaskState?
    public var completedBatches: [String] = []
    public var sidecars: [String:String]?
    public var fileStatus: String?
    public init(id:String, service:TranslationService?) {self.id=id;self.service=service}
    public var title:String {service?.title ?? "历史译文"}
}
public struct Transcript: Codable, Equatable, Sendable {
    private var legacyTask: TranslationTaskState?
    private var legacyTranslations: [String:Translation] = [:]
    private var legacyBatches: [String] = []
    public var variants: [String:TranslationVariant]?
    public var activeVariantID: String?
    public var attempts: [TranslationAttempt]?
    public var schema = 2; public var version: String; public var original: Data; public var format: String; public var cues: [Cue]; public var plain: String?; public var usage: [TranslationUsage]?
    enum CodingKeys:String,CodingKey {case legacyTask="task",legacyTranslations="translations",legacyBatches="completedBatches",variants,activeVariantID,attempts,schema,version,original,format,cues,plain,usage}
    public var variantID:String {activeVariantID ?? "openAI"}
    public var translations:[String:Translation] {
        get {variants == nil ? legacyTranslations : variants?[variantID]?.translations ?? [:]}
        set {if variants == nil {legacyTranslations=newValue}else{ensureVariant(variantID);variants![variantID]!.translations=newValue}}
    }
    public var task:TranslationTaskState? {
        get {variants == nil ? legacyTask : variants?[variantID]?.task}
        set {if variants == nil {legacyTask=newValue}else{ensureVariant(variantID);variants![variantID]!.task=newValue}}
    }
    public var completedBatches:[String] {
        get {variants == nil ? legacyBatches : variants?[variantID]?.completedBatches ?? []}
        set {if variants == nil {legacyBatches=newValue}else{ensureVariant(variantID);variants![variantID]!.completedBatches=newValue}}
    }
    public var translatedCount: Int { cues.filter { translations[$0.id] != nil }.count }
    public var allTranslatedCount:Int {variants?.values.reduce(0){$0+$1.translations.count} ?? translatedCount}
    public init(version: String, original: Data, format: String, cues: [Cue], plain: String? = nil) { self.version = version; self.original = original; self.format = format; self.cues = cues; self.plain = plain;variants=["openAI":TranslationVariant(id:"openAI",service:.openAI)];activeVariantID="openAI" }
    public mutating func ensureVariant(_ id:String) {if variants?[id] == nil {variants?[id]=TranslationVariant(id:id,service:TranslationService(rawValue:id))}}
    public func viewing(_ id:String?) -> Transcript {var copy=self;if let id {copy.activeVariantID=id};return copy}
    public mutating func migrateVariants() throws {
        try validate()
        guard schema==1 else{return}
        // Attribution uses explicit per-cue provenance or unambiguous recorded batch usage only.
        var result:[String:TranslationVariant]=[:]
        for (id,value) in legacyTranslations {
            let matching=(usage ?? []).filter{$0.batchKey==value.cacheKey}
            let services=Set(matching.map{($0.service ?? .openAI).rawValue})
            let service=value.service ?? (services.count==1 ? TranslationService(rawValue:services.first!) : nil)
            let key=service?.rawValue ?? "legacy"
            if result[key]==nil {result[key]=TranslationVariant(id:key,service:service)}
            result[key]!.translations[id]=value
        }
        if let old=legacyTask {let key=old.config.providerID.rawValue;if result[key]==nil{result[key]=TranslationVariant(id:key,service:old.config.providerID)};var task=old;task.variantID=key;result[key]!.task=task}
        if result.isEmpty {result["openAI"]=TranslationVariant(id:"openAI",service:.openAI)}
        activeVariantID=result.values.sorted{$0.translations.count == $1.translations.count ? $0.id<$1.id : $0.translations.count>$1.translations.count}.first!.id
        // Keep unclassified batch markers in the historical version; they never determine pending cues.
        if !legacyBatches.isEmpty {if result["legacy"]==nil{result["legacy"]=TranslationVariant(id:"legacy",service:nil)};result["legacy"]!.completedBatches=legacyBatches}
        if usage != nil {for i in usage!.indices {usage![i].variantID=(usage![i].service ?? .openAI).rawValue}}
        if attempts != nil {for i in attempts!.indices {attempts![i].variantID=(attempts![i].service ?? .openAI).rawValue}}
        variants=result;schema=2;legacyTranslations=[:];legacyTask=nil;legacyBatches=[]
        try validate()
    }
    public func active(at seconds: Double, offset: Double) -> [String] { TranscriptTimeline(cues).active(at: seconds, mapper: SubtitleTimingMapper(offset: offset)) }
    public func target(_ cue: Cue, offset: Double) -> Double { SubtitleTimingMapper(offset: offset).seekTarget(cue) }
    public func validate() throws {
        let ids=Set(cues.map(\.id))
        guard (schema==1 || schema==2), version==digest(original), ids.count==cues.count,cues.allSatisfy({$0.start>=0 && $0.end>$0.start && !$0.en.isEmpty}),legacyTranslations.keys.allSatisfy({ids.contains($0)}) else{throw Failure("字幕版本、时间或译文映射无效")}
        if schema==2 {guard let variants,!variants.isEmpty else{throw Failure("缺少译文版本")};for (id,v) in variants {guard id==v.id,(id=="legacy" && v.service==nil) || v.service?.rawValue==id,v.translations.keys.allSatisfy({ids.contains($0)}),v.task == nil || (v.task!.version==version && v.task!.ids.allSatisfy{ids.contains($0)}) else{throw Failure("译文版本映射无效")}}}
    }
}
public enum SubtitleParser {
    public static func parse(_ data: Data, format: String) throws -> Transcript {
        guard var source = String(data: data, encoding: .utf8) else { throw Failure("字幕必须为 UTF-8 编码") }
        source = source.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let version = digest(data)
        if format.lowercased() == "txt" { return Transcript(version: version, original: data, format: "txt", cues: [], plain: source) }
        let lines = source.components(separatedBy: "\n"); var i = 0; var cues: [Cue] = []
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }
            if line.hasPrefix("WEBVTT") || line == "STYLE" || line == "REGION" || line == "NOTE" || line.hasPrefix("NOTE ") {
                while i < lines.count && !lines[i].isEmpty { i += 1 }; continue
            }
            var sourceID: String?
            if !line.contains("-->") { sourceID = line; i += 1 }
            guard i < lines.count, lines[i].contains("-->") else { throw Failure("第 \(i+1) 行：缺少时间轴") }
            let parts = lines[i].components(separatedBy: "-->")
            guard parts.count == 2 else { throw Failure("第 \(i+1) 行：时间轴格式错误") }
            let start: Int; let end: Int
            do { start = try timestamp(parts[0].trimmingCharacters(in: .whitespaces)); end = try timestamp(String(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")) }
            catch { throw Failure("第 \(i+1) 行：\(error.localizedDescription)") }
            guard end > start else { throw Failure("第 \(i+1) 行：结束时间必须晚于开始时间") }
            i += 1; var body: [String] = []
            while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { body.append(lines[i]); i += 1 }
            let text = clean(body.joined(separator: "\n"))
            guard !text.isEmpty else { throw Failure("第 \(i+1) 行：字幕正文为空") }
            cues.append(Cue(id: "\(version.prefix(16))-\(cues.count)", sourceID: sourceID, start: start, end: end, en: text))
        }
        guard !cues.isEmpty else { throw Failure("没有找到有效字幕") }
        return Transcript(version: version, original: data, format: format.lowercased(), cues: cues)
    }
    public static func timestamp(_ value: String) throws -> Int {
        guard value.range(of: "^(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}[.,][0-9]{3}$", options: .regularExpression) != nil else { throw Failure("无效时间 \(value)") }
        let fields = value.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard fields.count == 2 || fields.count == 3 else { throw Failure("无效时间 \(value)") }
        let sec = fields.last!.split(separator: ".")
        guard sec.count == 2, sec[1].count == 3, let s = Int(sec[0]), let ms = Int(sec[1]), let m = Int(fields[fields.count-2]), let h = fields.count == 3 ? Int(fields[0]) : 0, (0..<60).contains(s), (0..<60).contains(m), h >= 0, h <= (Int.max - 3_599_999) / 3_600_000, (0..<1000).contains(ms) else { throw Failure("无效时间 \(value)") }
        return ((h*60+m)*60+s)*1000+ms
    }
    static func clean(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "<v(?:\\.[^ >]+)?\\s+([^>]+)>", with: "$1: ", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a,b) in [("&lt;","<"),("&gt;",">"),("&nbsp;"," "),("&lrm;",""),("&rlm;",""),("&quot;","\""),("&#39;","'"),("&amp;","&")] { value = value.replacingOccurrences(of: a, with: b) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
public func timeLabel(_ seconds: Double) -> String { let s = max(0, Int(seconds.isFinite ? seconds : 0)); return String(format:"%02d:%02d:%02d",s/3600,s/60%60,s%60) }
