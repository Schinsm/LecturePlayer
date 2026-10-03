import Foundation
public enum ExportKind:String,CaseIterable,Sendable {case englishVTT="英文 VTT",chineseVTT="中文 VTT",bilingualVTT="双语 VTT",bilingualSRT="双语 SRT",text="英文 TXT",markdown="双语 Markdown";public var ext:String {switch self {case .englishVTT,.chineseVTT,.bilingualVTT:return "vtt";case .bilingualSRT:return "srt";case .text:return "txt";case .markdown:return "md"}}}
public enum Exporter {
    public static func render(_ t:Transcript,kind:ExportKind,translatedOnly:Bool=false,marks:[Mark]=[],hideSpeakers:Bool=false,grouped:Bool=false) throws -> Data {
        let selected = translatedOnly ? t.cues.filter {t.translations[$0.id] != nil} : t.cues
        let units = ReadingUnits.make(selected, grouped: grouped)
        if kind == .text {return Data(SpeakerLabel.clean(t.plain ?? units.map {$0.content(translations: [:], mode: "英文", hideSpeakers: hideSpeakers).text}.joined(separator: "\n\n"), hide: hideSpeakers).utf8)}
        if kind == .markdown && grouped && t.plain == nil {
            var lines = ["# 学习转写", "翻译：\(t.translatedCount)/\(t.cues.count)", "原字幕时间轴；按句阅读。", ""]
            for unit in units {lines += ["## " + stamp(unit.cues[0].start,false), unit.content(translations:t.translations,mode:"双语",hideSpeakers:hideSpeakers).text, ""]}
            lines += ["# 书签"] + marks.map {"- \(timeLabel($0.seconds)) \($0.note)"}
            return Data(lines.joined(separator: "\n\n").utf8)
        }
        if let plain=t.plain {guard kind == .markdown else{throw Failure("TXT 没有时间戳，不能导出同步字幕")};return Data(("# 无时间戳资料\n\n"+SpeakerLabel.clean(plain,hide:hideSpeakers)).utf8)}
        if kind == .englishVTT && t.format == "vtt" && !hideSpeakers {return t.original}
        let cues=translatedOnly ? t.cues.filter {t.translations[$0.id] != nil} : t.cues
        guard !cues.isEmpty else{throw Failure("所选范围没有可导出的字幕")}
        let partial=t.translatedCount<t.cues.count
        var lines:[String]=[]
        if kind == .markdown {lines=["# 学习转写", "翻译：\(t.translatedCount)/\(t.cues.count)"+(partial ? "（部分翻译）" : ""),"偏移未写入导出；保留原时间轴。",""]}
        else if kind != .bilingualSRT {lines=["WEBVTT",""];if partial && kind != .englishVTT {lines += ["NOTE 部分翻译；未完成内容明确标记。",""]}}
        for (index,c) in cues.enumerated() {
            let zh=SpeakerLabel.cleanTranslation(t.translations[c.id]?.text ?? "[未翻译]",source:c.en,hide:hideSpeakers)
            let en=SpeakerLabel.clean(c.en,hide:hideSpeakers)
            if kind == .markdown {lines += ["## \(stamp(c.start,false))",en,"",zh,""];continue}
            let body=kind == .englishVTT ? en : kind == .chineseVTT ? zh : en+"\n"+zh
            let identifier=kind == .bilingualSRT ? "\(index+1)" : c.sourceID ?? c.id
            lines += [identifier,"\(stamp(c.start,kind == .bilingualSRT)) --> \(stamp(c.end,kind == .bilingualSRT))",body.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;"),""]
        }
        if kind == .markdown {lines += ["# 书签"]+marks.map{"- \(timeLabel($0.seconds)) \($0.note)"}}
        return Data(lines.joined(separator:"\n").utf8)
    }
    static func stamp(_ ms:Int,_ srt:Bool)->String {String(format:"%02d:%02d:%02d%@%03d",ms/3600000,ms/60000%60,ms/1000%60,srt ? "," : ".",ms%1000)}
}
public struct Backup: Codable, Sendable {
    public var schema = 4
    public var created = Date()
    public var library: Library
    public var transcripts: [String: Transcript]
    /// Optional so pre-0.8 backups decode without inventing summaries.
    public var processing: [ImportProcessingEntry]?
    public var analyses: [String: LessonAnalysis]?
    public init(library: Library, transcripts: [String: Transcript], analyses: [String: LessonAnalysis]? = nil, processing: [ImportProcessingEntry]? = nil) {
        self.library = library; self.transcripts = transcripts; self.analyses = analyses; self.processing=processing
        if processing != nil || analyses?.values.contains(where:{$0.schema==2}) == true {schema=5}
    }
    public static func analysisPayload(_ records: [LessonAnalysis]) throws -> [String: LessonAnalysis] {
        var result: [String: LessonAnalysis] = [:]
        for record in records {
            let key = AnalysisRepository.fileURL(root: URL(fileURLWithPath: "/"), lessonID: record.lessonID, sourceVersion: record.sourceVersion).deletingPathExtension().lastPathComponent
            guard result[key] == nil else { throw Failure("重复的课程总结版本") }
            result[key] = record
        }
        return result
    }
    public func validate() throws {
        guard (1...5).contains(schema) else { throw Failure("不支持的备份版本") }
        _ = try LibraryMigration.upgrade(library)
        for (key, transcript) in transcripts {
            try transcript.validate()
            guard let id = UUID(uuidString: String(key.prefix(36))), key == "\(id)-\(transcript.version)" else { throw Failure("备份字幕标识不匹配") }
        }
        for lesson in library.lectures {
            if let version = lesson.transcriptVersion {
                guard transcripts["\(lesson.id)-\(version)"] != nil else { throw Failure("备份缺少回放字幕") }
            }
        }
        if let processing {
            guard schema>=5,Set(processing.map(\.id)).count==processing.count else {throw Failure("导入任务备份无效")}
            for entry in processing {
                guard library.lectures.contains(where:{$0.id==entry.id}) else {throw Failure("任务课件缺失")}
                if let a=entry.analysis {try a.validate();guard let t=transcripts["\(entry.id)-\(a.plan.sourceVersion)"],a.plan == (try AnalysisPlan.make(t)) else {throw Failure("总结任务原文不匹配")}}
                if let task=entry.translation {guard let t=transcripts["\(entry.id)-\(task.version)"],Set(task.ids).isSubset(of:Set(t.cues.map(\.id))) else {throw Failure("翻译任务原文不匹配")}}
            }
        }
        if let analyses {
            guard schema >= 4 || analyses.isEmpty else { throw Failure("旧版备份不能包含课程总结") }
            let expected = try Self.analysisPayload(Array(analyses.values))
            guard Set(expected.keys) == Set(analyses.keys) else { throw Failure("备份总结标识不匹配") }
            for (key, record) in analyses {
                let expectedKey = AnalysisRepository.fileURL(root: URL(fileURLWithPath: "/"), lessonID: record.lessonID, sourceVersion: record.sourceVersion).deletingPathExtension().lastPathComponent
                guard key == expectedKey else { throw Failure("备份总结标识不匹配") }
                guard library.lectures.contains(where: { $0.id == record.lessonID }),
                      let transcript = transcripts["\(record.lessonID)-\(record.sourceVersion)"] else { throw Failure("备份总结缺少对应课件或原字幕版本") }
                try record.validate(transcript: transcript)
            }
        }
    }
}

/// Changes both payload directories as one recoverable operation. The caller commits its
/// metadata only after all JSON files have been staged and validated. A legacy backup's
/// empty analyses directory intentionally replaces the current one, preventing stale data.
public enum BackupPayloadTransaction {
    public static func restore(_ backup: Backup, root: URL, commit: () throws -> Void) throws {
        try backup.validate()
        let fm = FileManager.default
        let transaction = root.appendingPathComponent(".restore-\(UUID())", isDirectory: true)
        let staged = transaction.appendingPathComponent("staged", isDirectory: true)
        let previous = transaction.appendingPathComponent("previous", isDirectory: true)
        let names = ["transcripts", "analyses", "processing-queue.json"]
        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        var swapped: [String] = []
        var movedOriginals: [String] = []
        do {
            for name in names.prefix(2) { try fm.createDirectory(at: staged.appendingPathComponent(name), withIntermediateDirectories: true) }
            for (key, transcript) in backup.transcripts {
                let bytes = try Codec.encode(transcript)
                try bytes.write(to: staged.appendingPathComponent("transcripts/\(key).json"), options: .atomic)
            }
            for (key, analysis) in backup.analyses ?? [:] {
                let bytes = try Codec.encode(analysis)
                try bytes.write(to: staged.appendingPathComponent("analyses/\(key).json"), options: .atomic)
            }
            try Codec.encode(backup.processing ?? []).write(to:staged.appendingPathComponent("processing-queue.json"),options:.atomic)
            for name in names {
                let target = root.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) {
                    try fm.moveItem(at: target, to: previous.appendingPathComponent(name)); movedOriginals.append(name)
                }
                try fm.moveItem(at: staged.appendingPathComponent(name), to: target); swapped.append(name)
            }
            try commit()
        } catch {
            let originalError = error
            do {
                for name in swapped.reversed() { try fm.removeItem(at: root.appendingPathComponent(name)) }
                for name in movedOriginals.reversed() { try fm.moveItem(at: previous.appendingPathComponent(name), to: root.appendingPathComponent(name)) }
            } catch {
                // Keep the transaction's original files available for explicit recovery.
                throw Failure("恢复失败，回滚未完成。原数据保留在 \(transaction.path)。\(originalError.localizedDescription)；\(error.localizedDescription)")
            }
            try? fm.removeItem(at: transaction)
            throw originalError
        }
        try? fm.removeItem(at: transaction)
    }
}
