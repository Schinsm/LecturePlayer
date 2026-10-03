import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V0872Acceptance {
    @Test func repeatedExportBeforeAfterComparison() async throws {
        let f=V0872Tests();let (s,l,url,_)=try f.fixture()
        let old=Baseline0871Writer();let fixed=s.translation.writer
        _=try await old.saveFiles(lesson:l,url:url)
        var oldReplacements=0,oldBytes=0
        for _ in 0..<20 {
            let before=try f.stamp(url);_=try await old.saveFiles(lesson:l,url:url)
            if try f.stamp(url) != before {oldReplacements += 1;oldBytes += try Data(contentsOf:url).count}
        }
        _=try await fixed.saveFiles(lesson:l,url:url)
        var newReplacements=0
        for _ in 0..<20 {let before=try f.stamp(url);_=try await fixed.saveFiles(lesson:l,url:url);if try f.stamp(url) != before {newReplacements += 1}}
        #expect(oldReplacements==20 && newReplacements==0)
        print("WRITE_COMPARISON old replacements=\(oldReplacements) encoded bytes=\(oldBytes); fixed replacements=\(newReplacements)")
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP0872_IDLE"]=="1"))
    func latestSnapshotAndTenMinuteIdleRefresh() async throws {
        let base=URL(fileURLWithPath:"/private/tmp/LP0872/baseline-data")
        let root=URL(fileURLWithPath:"/private/tmp/LP0872/idle-data")
        if FileManager.default.fileExists(atPath:root.path) {throw Failure("Use a fresh acceptance directory")}
        try FileManager.default.copyItem(at:base,to:root)
        let repo=try Repository(root:root);let before=try repo.load()
        let transcripts=try before.lectures.compactMap{try repo.read($0)}
        let analyses=try AnalysisRepository.readAll(root:root)
        try repo.save(before)
        #expect(try repo.load()==before)
        #expect(try before.lectures.compactMap{try repo.read($0)}==transcripts)
        #expect(try AnalysisRepository.readAll(root:root)==analyses)
        // Every lesson gets isolated synthetic media and original subtitle bytes copied from its cache.
        var library=before;library.lastLecture=nil;library.directoryBookmark=nil
        let media=root.appendingPathComponent("Media");library.directoryRoot=media.path
        for i in library.lectures.indices {
            let dir=media.appendingPathComponent("QA/Week1/\(library.lectures[i].id)")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let video=dir.appendingPathComponent("s1.mp4");try Data("isolated video".utf8).write(to:video)
            library.lectures[i].path=video.path;library.lectures[i].bookmark=nil;library.lectures[i].sources=nil
            library.lectures[i].identity=try DirectoryIndex.identity(video);library.lectures[i].sidecars=nil
            if let t=try repo.read(library.lectures[i]) {
                let subtitle=dir.appendingPathComponent("source."+t.format);try t.original.write(to:subtitle)
                library.lectures[i].subtitlePath=subtitle.path;library.lectures[i].subtitleBookmark=nil
                var isolated=t
                for id in (isolated.variants ?? [:]).keys {isolated.variants?[id]?.sidecars=nil;isolated.variants?[id]?.fileInputKey=nil}
                try repo.write(isolated,for:library.lectures[i].id)
            }
        }
        try repo.save(library)
        let store=AppStore(root:root);store.watchesEnabled=true
        defer{store.directoryWatch.update([])}
        store.refreshDirectory();try await V042AppTests().wait(store)
        for task in Array(store.fileSaveTasks.values) {await task.value}
        #expect(store.scanIssues.isEmpty)
        guard store.scanIssues.isEmpty else {throw Failure("Isolated scan failed: "+store.scanIssues.joined(separator:";"))}
        // Allow generated file events and initial metadata adoption to settle.
        try await Task.sleep(for:.seconds(4));if let task=store.scanTask {await task.value}
        for task in Array(store.fileSaveTasks.values) {await task.value};store.flushMetadata()
        func tracked() throws -> [String:String] {
            var result:[String:String]=[:]
            let e=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)!
            for case let file as URL in e where file.path.contains("/transcripts/") || ImportPlanner.isGenerated(file) {
                if ["json","vtt","md"].contains(file.pathExtension) {result[file.path]=try V0872Tests().stamp(file)}
            }
            return result
        }
        let settled=try tracked();#expect(settled.count>transcripts.count);
        guard settled.count>transcripts.count else{throw Failure("Sidecars were not exercised")}
let lessonState=store.library.lectures.map{($0.id,$0.state,$0.marks,$0.finished)}
        let start=Date();var refreshes=0
        for n in 1...120 {
            try await Task.sleep(for:.seconds(5))
            if n%6==0 {store.refreshDirectory();try await V042AppTests().wait(store);for task in Array(store.fileSaveTasks.values){await task.value};refreshes += 1}
            #expect(try tracked()==settled)
            if n%12==0 {
                let text="elapsed=\(Int(Date().timeIntervalSince(start)))s refreshes=\(refreshes) files=\(settled.count) rewrites=0\n"
                try text.write(to:URL(fileURLWithPath:"/private/tmp/LP0872/evidence/idle-progress.txt"),atomically:true,encoding:.utf8)
                print(text)
            }
        }
        for (id,state,marks,finished) in lessonState {let l=try #require(store.library.lectures.first{$0.id==id});#expect(l.state==state && l.marks==marks && l.finished==finished)}
        #expect(try AnalysisRepository.readAll(root:root)==analyses)
        for original in transcripts {
            let l=try #require(store.library.lectures.first{$0.transcriptVersion==original.version})
            let saved=try #require(try store.repository?.read(l))
            #expect(saved.attempts==original.attempts && saved.usage==original.usage)
            for (id,v) in original.variants ?? [:] {#expect(saved.variants?[id]?.translations==v.translations)}
        }
        let report:[String:Any]=["seconds":Date().timeIntervalSince(start),"manualRefreshes":refreshes,"trackedFiles":settled.count,"rewrites":0,"lessons":before.lectures.count,"cues":transcripts.reduce(0){$0+$1.cues.count},"translations":transcripts.reduce(0){$0+$1.allTranslatedCount},"analyses":analyses.count]
        try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted).write(to:URL(fileURLWithPath:"/private/tmp/LP0872/evidence/idle-result.json"))
    }
}
