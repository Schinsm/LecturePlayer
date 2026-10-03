import Foundation

public struct HistoricalExportDecision:Codable,Sendable {
    public let path:String;public let service:String;public let bytes:Int;public let checksum:String?
    public let candidate:Bool;public let reason:String
}
public enum HistoricalExportAudit {
    /// Conservative proof: known ownership digest, exact reproduction from a subset of saved translations,
    /// and verified complete replacements. Similar filenames or matching fragments are never enough.
    public static func evaluate(url:URL,knownHash:String?,transcript:Transcript,lesson:Lecture,replacements:[GeneratedFileRecord]) -> HistoricalExportDecision {
        var count=0,hash:String?
        func result(_ candidate:Bool,_ reason:String)->HistoricalExportDecision {HistoricalExportDecision(path:url.path,service:transcript.variantID,bytes:count,checksum:hash,candidate:candidate,reason:reason)}
        do {
            let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard info.isRegularFile==true,info.isSymbolicLink != true else {return result(false,"非普通生成文件，保留")}
            let data=try Data(contentsOf:url);count=data.count;hash=digest(data)
            guard knownHash==hash else {return result(false,"未匹配最后保存校验值；可能经过修改，保留")}
            guard !transcript.cues.isEmpty,transcript.cues.allSatisfy({transcript.translations[$0.id]?.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false}) else {return result(false,"当前译文尚不完整，保留")}
            let current=replacements.filter{$0.lessonID==lesson.id && $0.sourceVersion==transcript.version && $0.serviceID==transcript.variantID}
            guard Set(current.map(\.format)).count==2,current.allSatisfy({(try? Data(contentsOf:URL(fileURLWithPath:$0.path))).map(digest)==$0.checksum}) else {return result(false,"完整替代文件尚未核验，保留")}
            guard !current.contains(where:{$0.path==url.path}) else{return result(false,"当前输出，保留")}
            let kind:ExportKind
            var subset=transcript
            if url.lastPathComponent.hasSuffix(".zh.vtt") {
                kind = .chineseVTT
                let old=try SubtitleParser.parse(data,format:"vtt")
                var ids=Set<String>()
                for cue in old.cues {
                    let matches=transcript.cues.filter {($0.sourceID ?? $0.id)==(cue.sourceID ?? cue.id) && $0.start==cue.start && $0.end==cue.end}
                    guard matches.count==1,let source=matches.first,let translation=transcript.translations[source.id],
                          [false,true].contains(where:{SpeakerLabel.cleanTranslation(translation.text,source:source.en,hide:$0)==cue.en}) else{return result(false,"旧译文与当前保存内容不一致，保留")}
                    ids.insert(source.id)
                }
                subset.translations=transcript.translations.filter{ids.contains($0.key)}
            } else if url.lastPathComponent.hasSuffix(".bilingual.md") {
                kind = .markdown
                // Historical writer emitted ordered prefix batches. Only a byte-exact regeneration is accepted.
                guard let text=String(data:data,encoding:.utf8),let range=text.range(of:"翻译：[0-9]+/[0-9]+",options:.regularExpression) else {return result(false,"无法核验旧 Markdown 结构，保留")}
                let fields=text[range].dropFirst(3).split(separator:"/")
                guard fields.count==2,let n=Int(fields[0]),let total=Int(fields[1]),n>0,n<=total,total==transcript.cues.count else {return result(false,"旧字幕范围无法对应，保留")}
                let ids=Set(transcript.cues.prefix(n).map(\.id));subset.translations=transcript.translations.filter{ids.contains($0.key)}
            } else {return result(false,"非受支持的历史导出，保留")}
            for hidden in [false,true] {for grouped in [false,true] {
                for marks in [lesson.marks,[]] {
                    if try Exporter.render(subset,kind:kind,translatedOnly:kind == .chineseVTT,marks:marks,hideSpeakers:hidden,grouped:grouped)==data {return result(true,"归属校验值吻合、可逐字再现且完整当前译文已覆盖")}
                }
            }}
            return result(false,"无法逐字再现历史导出，保留")
        } catch {return result(false,"读取或核验失败，保留："+error.localizedDescription)}
    }
}
