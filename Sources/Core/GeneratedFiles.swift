import Foundation

public struct GeneratedFileRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Format:String,Codable,Sendable,CaseIterable {case chineseVTT,bilingualMarkdown
        public var suffix:String {self == .chineseVTT ? "zh.vtt":"bilingual.md"}
    }
    public var lessonID:UUID;public var sourceVersion:String;public var serviceID:String
    public var format:Format;public var path:String;public var checksum:String
    public var id:String {"\(lessonID)-\(sourceVersion)-\(serviceID)-\(format.rawValue)"}
    public init(lessonID:UUID,sourceVersion:String,serviceID:String,format:Format,path:String,checksum:String) {
        self.lessonID=lessonID;self.sourceVersion=sourceVersion;self.serviceID=serviceID;self.format=format;self.path=path;self.checksum=checksum
    }
}
/// Journal is written before replacing output. It survives a later transcript/metadata commit failure.
public enum GeneratedFiles {
    public static let marker=".lectureplayer-exports"
    private struct Intent:Codable {let record:GeneratedFileRecord;let previous:String?}
    public static func legacyFiles(_ files:[String:String],lessonID:UUID,version:String,serviceID:String)->[String:String] {
        let prefix=".lectureplayer-\(lessonID.uuidString.prefix(8))-\(version.prefix(8)).".lowercased()
        return files.filter {path,_ in
            let name=URL(fileURLWithPath:path).lastPathComponent.lowercased()
            guard let range=name.range(of:prefix) else{return false}
            let tail=String(name[range.upperBound...])
            if serviceID=="legacy" {return tail=="zh.vtt" || tail=="bilingual.md"}
            return tail.hasPrefix(serviceID.lowercased()+".")
        }
    }
    public static func write(_ t:Transcript,lesson:Lecture,hideSpeakers:Bool,journalRoot:URL?=nil,writeFile:(Data,URL,Data.WritingOptions)throws->Void = {try $0.write(to:$1,options:$2)}) throws -> SidecarWriteReport {
        guard t.translations.values.contains(where:{!$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else {
            return SidecarWriteReport(files:[:],outcome:.unchanged)
        }
        guard let media=lesson.mediaSources.first(where:{$0.role == .screen}) ?? (lesson.mediaSources.count==1 ? lesson.mediaSources.first:nil) else {throw Failure("无法确定译文保存的视频目录")}
        let fm=FileManager.default
        let base=URL(fileURLWithPath:media.path).deletingLastPathComponent().appendingPathComponent("LecturePlayer",isDirectory:true)
        guard fm.fileExists(atPath:base.deletingLastPathComponent().path) else {throw StorageIssue(.unavailable)}
        // Never take over an unrelated folder or follow an export symlink outside the course directory.
        if fm.fileExists(atPath:base.path) {
            guard (try base.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else {throw StorageIssue(.conflict)}
            if !fm.fileExists(atPath:base.appendingPathComponent(marker).path), !(try fm.contentsOfDirectory(atPath:base.path)).isEmpty {throw StorageIssue(.conflict)}
        }
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        let markerURL=base.appendingPathComponent(marker)
        if !fm.fileExists(atPath:markerURL.path) {try Data("LecturePlayer exports v1\n".utf8).write(to:markerURL,options:.withoutOverwriting)}
        let safe=String(lesson.title.map {"/:\\\n\r".contains($0) ? "_":$0}.prefix(70))
        let defaultFolder=base.appendingPathComponent("\(safe)-\(lesson.id.uuidString.prefix(8))-\(t.version.prefix(12))",isDirectory:true)
        let journal=journalRoot ?? base.appendingPathComponent(".write-intents",isDirectory:true)
        try fm.createDirectory(at:journal,withIntermediateDirectories:true)
        let owned=(t.variants?[t.variantID]?.generatedFiles ?? []).filter{$0.lessonID==lesson.id && $0.sourceVersion==t.version && $0.serviceID==t.variantID}
        var records:[GeneratedFileRecord]=[],writes=0,bytes=0,conflict=false
        // A remembered folder remains stable across title edits, but a moved video gets a new sibling folder.
        var folder=owned.first.map{URL(fileURLWithPath:$0.path).deletingLastPathComponent()}
        if folder?.deletingLastPathComponent().standardizedFileURL != base.standardizedFileURL {folder=nil}
        for format in GeneratedFileRecord.Format.allCases {
            try Task.checkCancellation()
            let kind:ExportKind = format == .chineseVTT ? .chineseVTT:.markdown
            let data=try Exporter.render(t,kind:kind,translatedOnly:kind == .chineseVTT,marks:lesson.marks,hideSpeakers:hideSpeakers,grouped:lesson.readingGrouped ?? true)
            let hash=digest(data)
            var record=owned.first{$0.format==format}
            let identity="\(lesson.id)-\(t.version)-\(t.variantID)-\(format.rawValue)"
            let intentURL=journal.appendingPathComponent(digest(identity)+".json")
            // Accept only a journal for this exact owner, inside the selected export root, whose bytes match.
            if let pending=try? Codec.decode(Intent.self,Data(contentsOf:intentURL)),pending.record.id==identity {
                let target=URL(fileURLWithPath:pending.record.path)
                if target.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL==base.standardizedFileURL,
                   let existing=try? Data(contentsOf:target),digest(existing)==pending.record.checksum {
                    record=pending.record;folder=target.deletingLastPathComponent()
                }
            }
            let directory=folder ?? defaultFolder;folder=directory
            if fm.fileExists(atPath:directory.path), (try directory.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink==true {throw StorageIssue(.conflict)}
            try fm.createDirectory(at:directory,withIntermediateDirectories:true)
            if record.map({URL(fileURLWithPath:$0.path).deletingLastPathComponent() != directory}) == true {record=nil}
            var target=record.map{URL(fileURLWithPath:$0.path)} ?? directory.appendingPathComponent(t.variantID.lowercased()+"."+format.suffix)
            var previous:String?
            if fm.fileExists(atPath:target.path) {
                let existing=try Data(contentsOf:target);previous=digest(existing)
                if previous != hash && previous != record?.checksum {
                    // One alternate is selected and journaled; later batches keep updating it.
                    conflict=true;target=directory.appendingPathComponent(t.variantID.lowercased()+"-"+UUID().uuidString.prefix(8)+"."+format.suffix);previous=nil
                }
            }
            let next=GeneratedFileRecord(lessonID:lesson.id,sourceVersion:t.version,serviceID:t.variantID,format:format,path:target.path,checksum:hash)
            if previous != hash {
                try Codec.encode(Intent(record:next,previous:previous)).write(to:intentURL,options:.atomic)
                if previous != nil {try writeFile(data,target,.atomic)}
                else {try writeFile(data,target,.withoutOverwriting)}
                writes += 1;bytes += data.count
            }
            records.append(next)
        }
        return SidecarWriteReport(files:Dictionary(uniqueKeysWithValues:records.map{($0.path,$0.checksum)}),outcome:conflict ? .conflict:(writes==0 ? .unchanged:.written),writes:writes,bytes:bytes,records:records)
    }
}
