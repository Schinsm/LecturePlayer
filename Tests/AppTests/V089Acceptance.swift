import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V089Acceptance {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP089_DATA"]=="1"))
    func latestIsolatedMigrationExportsCleanupAndRefresh() async throws {
        let base=URL(fileURLWithPath:"/private/tmp/LP089/baseline-data")
        let root=URL(fileURLWithPath:"/private/tmp/LP089/regression-\(UUID())")
        try FileManager.default.copyItem(at:base,to:root)
        let repo=try Repository(root:root),before=try repo.load()
        #expect(before.schema==5)
        let originals=try before.lectures.compactMap{try repo.read($0)}
        let analyses=try AnalysisRepository.readAll(root:root)
        let rawSnapshots=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("before-v089-")}
        #expect(rawSnapshots.count==1)
        var library=before;library.lastLecture=nil;library.directoryBookmark=nil
        library.directoryRoot=root.appendingPathComponent("Media").path
        var decisions:[HistoricalExportDecision]=[],replacementRecords:[GeneratedFileRecord]=[]
        let writer=TranslationWriter()
        var timings:[String:[Double]]=["filesCold":[],"filesCache":[],"analysisPreparation":[]]
        var exportStamps:[String:String]=[:]
        // Reproduce the previous global sheet's read/decode work using this same isolated snapshot.
        timings["previousGlobalRead"]=[]
        for _ in 0..<3 {
            let start=Date()
            for lesson in before.lectures {
                if let source=try repo.read(lesson) {_=(source.variants ?? [:]).values.sorted{$0.id<$1.id}.map{"\($0.title)：\($0.translations.count)/\(source.cues.count)"}}
                _=(lesson.sidecars ?? [:]).keys.sorted()
            }
            timings["previousGlobalRead"]!.append(Date().timeIntervalSince(start))
        }
        for i in library.lectures.indices {
            let prior=library.lectures[i],dir=root.appendingPathComponent("Media/QA/\(prior.id)")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            var lesson=prior
            for j in lesson.mediaSources.indices {
                var sources=lesson.mediaSources
                sources[j].path=dir.appendingPathComponent("s\(j+1).mp4").path;sources[j].bookmark=nil
                try Data("isolated mock media".utf8).write(to:URL(fileURLWithPath:sources[j].path))
                sources[j].identity=try DirectoryIndex.identity(URL(fileURLWithPath:sources[j].path));lesson.mediaSources=sources
            }
            lesson.bookmark=nil;lesson.subtitleBookmark=nil
            guard let source=try repo.read(prior) else {continue}
            let subtitle=dir.appendingPathComponent("source."+source.format);try source.original.write(to:subtitle);lesson.subtitlePath=subtitle.path
            let url=try repo.transcriptURL(lesson.id,source.version)
            let result=try await writer.saveFiles(lesson:lesson,url:url)
            #expect(result.fileOutcome != .failed)
            let saved=result.transcript
            #expect(saved.cues==source.cues && saved.original==source.original && saved.attempts==source.attempts && saved.usage==source.usage)
            for (id,v) in source.variants ?? [:] {
                #expect(saved.variants?[id]?.translations==v.translations && saved.variants?[id]?.task==v.task)
                let records=saved.variants?[id]?.generatedFiles ?? [];replacementRecords += records
                let old=(prior.sidecars ?? [:]).merging(v.sidecars ?? [:]){old,_ in old}
                for (path,hash) in GeneratedFiles.legacyFiles(old,lessonID:prior.id,version:source.version,serviceID:id) {
                    decisions.append(HistoricalExportAudit.evaluate(url:URL(fileURLWithPath:path),knownHash:hash,transcript:source.viewing(id),lesson:prior,replacements:records))
                }
            }
            for record in (saved.variants ?? [:]).values.flatMap({$0.generatedFiles ?? []}) {exportStamps[record.path]=try V0872Tests().stamp(URL(fileURLWithPath:record.path))}
            lesson.sidecars=result.sidecars;lesson.sidecarStatus=result.fileStatus;lesson.generatedFilePaths=result.currentFilePaths;library.lectures[i]=lesson
            let started=Date();_=try await LessonFileCache.shared.load(root:root,lesson:lesson);timings["filesCold"]!.append(Date().timeIntervalSince(started))
            let hit=Date();_=try await LessonFileCache.shared.load(root:root,lesson:lesson);timings["filesCache"]!.append(Date().timeIntervalSince(hit))
            let prepared=Date();_=try await Task.detached {try AnalysisPreparation.load(root:root,lesson:lesson,config:AnalysisConfig(model:"gpt-4o-mini"))}.value;timings["analysisPreparation"]!.append(Date().timeIntervalSince(prepared))
        }
        try repo.save(library)
        let payloads=try library.lectures.compactMap{try repo.read($0)}
        let backup=Backup(library:library,transcripts:Dictionary(uniqueKeysWithValues:zip(library.lectures,payloads).map{("\($0.id)-\($1.version)",$1)}),analyses:try Backup.analysisPayload(analyses))
        try backup.validate();#expect(backup.schema==6)
        let restored=try Repository(root:root.appendingPathComponent("Restore"))
        try BackupPayloadTransaction.restore(backup,root:restored.root){try restored.save(backup.library)}
        func ordered(_ input:Library)->Library {
            var value=input;value.courses.sort{$0.id.uuidString<$1.id.uuidString};value.folders.sort{$0.id.uuidString<$1.id.uuidString};value.lectures.sort{$0.id.uuidString<$1.id.uuidString};return value
        }
        #expect(try ordered(restored.load())==ordered(library))
        #expect(try library.lectures.compactMap{try restored.read($0)}==payloads)
        let store=AppStore(root:root)
        for _ in 0..<8 {
            store.refreshDirectory();await store.scanTask?.value
            for task in Array(store.fileSaveTasks.values) {await task.value}
        }
        for (path,stamp) in exportStamps {#expect(try V0872Tests().stamp(URL(fileURLWithPath:path))==stamp)}
        #expect(try library.lectures.compactMap{try repo.read($0)}==payloads)
        #expect(try AnalysisRepository.readAll(root:root)==analyses)
        for original in before.lectures {
            let saved=try #require(store.library.lectures.first{$0.id==original.id})
            #expect(saved.state==original.state && saved.marks==original.marks && saved.finished==original.finished)
        }
        let evidence=URL(fileURLWithPath:"/private/tmp/LP089/evidence")
        try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
        try Codec.encode(decisions.sorted{$0.path<$1.path}).write(to:evidence.appendingPathComponent("cleanup-audit.json"),options:.atomic)
        try Codec.encode(replacementRecords).write(to:evidence.appendingPathComponent("replacement-files.json"),options:.atomic)
        let report:[String:Any]=["root":root.path,"lessons":before.lectures.count,"transcripts":originals.count,"translations":originals.reduce(0){$0+$1.allTranslatedCount},"analyses":analyses.count,"exportFiles":exportStamps.count,"refreshes":8,"rewrites":0,"historyFiles":decisions.count,"candidates":decisions.filter(\.candidate).count,"candidateBytes":decisions.filter(\.candidate).reduce(0){$0+$1.bytes},"timings":timings]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:evidence.appendingPathComponent("acceptance.json"))
        print("LP089_ACCEPTANCE \(report)")
    }
}
