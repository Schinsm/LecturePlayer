import AppKit
import Core
import UniformTypeIdentifiers
extension AppStore {
    func snapshot() throws -> Backup {
        captions.flush();readerPresentation.flush();playback.persist();try repository?.commits.flush();var transcripts:[String:Transcript]=[:]
        // Include historical subtitle versions, including manual edits, not just active versions.
        if let repository {for url in try FileManager.default.contentsOfDirectory(at:repository.root.appendingPathComponent("transcripts"),includingPropertiesForKeys:nil) where url.pathExtension=="json" {transcripts[url.deletingPathExtension().lastPathComponent]=try Codec.decode(Transcript.self,Data(contentsOf:url))}}
        var safe=library; safe.directoryBookmark = nil;for i in safe.lectures.indices {safe.lectures[i].bookmark=nil; safe.lectures[i].subtitleBookmark=nil; if safe.lectures[i].sources != nil { for j in safe.lectures[i].sources!.indices { safe.lectures[i].sources![j].bookmark = nil } }}
        let analyses = try repository.map { try Backup.analysisPayload(AnalysisRepository.readAll(root: $0.root)) }
        let backup=Backup(library:safe,transcripts:transcripts,analyses:analyses,processing:try repository.flatMap {try ImportProcessingEntry.read(root:$0.root)});try backup.validate();return backup
    }
    func backup() {perform {let data=try Codec.encode(snapshot());try saveOutput(data,name:"LecturePlayer-backup-\(Int(Date().timeIntervalSince1970)).json")}}
    func restore() {
        guard !translation.busy else{error="请先停止翻译、总结或连接测试，并等待保存完成后再恢复";return}
        guard let url=chooseFiles(types:[.json]).first else{return}
        perform {
            var backup=try Codec.decode(Backup.self,Data(contentsOf:url));try backup.validate(); backup.library = try LibraryMigration.upgrade(backup.library); for key in Array(backup.transcripts.keys) {try backup.transcripts[key]!.migrateVariants()}
            let a=NSAlert();a.messageText="恢复资料库？";a.informativeText="将替换当前逻辑目录，包含 \(backup.library.courses.count) 门课程、\(backup.library.lectures.count) 堂回放。先自动保存当前资料库备份；视频可能需要重新定位。Keychain 不受影响。";a.addButton(withTitle:"恢复");a.addButton(withTitle:"取消");guard a.runModal() == .alertFirstButtonReturn else{return}
            guard !translation.busy else { throw Failure("请等待当前请求及保存完成后再恢复") }
            guard let repository else{throw Failure("资料库不可用")}
            let previous=try Codec.encode(snapshot());try previous.write(to:repository.root.appendingPathComponent("before-restore-\(Int(Date().timeIntervalSince1970)).json"),options:.atomic)
            // Payloads are staged first; failed metadata commits restore both original directories.
            playback.close()
            try BackupPayloadTransaction.restore(backup, root: repository.root) { try repository.save(backup.library) }
            usageCache=nil;usageCacheToken="";library=backup.library;translation.restore(self);processing.restore(self);current=nil;transcript=nil;selectedCourse=library.courses.first?.id;selectedFolder=nil
            rootGeneration=UUID();scanResult=nil;directoryFiles=[];pendingFiles=[];configureRefreshSchedule();refreshDirectory()
        }
    }
    func export(_ kind:ExportKind) {
        guard let transcript,let lecture else{return}
        perform {
            var only=false
            if transcript.translatedCount<transcript.cues.count && ![ExportKind.englishVTT,.text].contains(kind) {let a=NSAlert();a.messageText="部分翻译：\(transcript.translatedCount)/\(transcript.cues.count)";a.informativeText="选择导出范围；未译位置会明确标记。";a.addButton(withTitle:"全部（标记未译）");a.addButton(withTitle:"仅已译");a.addButton(withTitle:"取消");let result=a.runModal();guard result != .alertThirdButtonReturn else{return};only=result == .alertSecondButtonReturn}
            let data=try Exporter.render(transcript,kind:kind,translatedOnly:only,marks:lecture.marks,hideSpeakers:UserDefaults.standard.object(forKey:"hideSpeakerLabels") as? Bool ?? true,grouped:lecture.readingGrouped ?? true);try saveOutput(data,name:lecture.title+"-"+kind.rawValue+"."+kind.ext)
        }
    }
    func editTranslation(_ cue:Cue,restore:Bool=false) {
        guard !translation.running else {error="请先暂停翻译并等待保存完成，再编辑中文。";return}
        guard var t=transcript,let id=current,var value=t.translations[cue.id] else{return}
        if restore {value.edited=nil} else {guard let text=askName("编辑中文译文",initial:value.text) else{return};value.edited=text}
        t.translations[cue.id]=value;perform {try saveTranscript(t,lectureID:id)}
    }
}
@MainActor func saveOutput(_ data:Data,name:String) throws {
    let p=NSSavePanel();p.nameFieldStringValue=name.replacingOccurrences(of:"/",with:"-");guard p.runModal() == .OK,let url=p.url else{return}
    guard !FileManager.default.fileExists(atPath:url.path) else{throw Failure("为保护原件，不覆盖已有文件。请换一个文件名。")};try data.write(to:url,options:.withoutOverwriting)
}
