import Foundation
import Testing
import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V088DataTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP088_DATA"]=="1"))
    func latestIsolatedSnapshotAndBackupPreserveEveryLesson() async throws {
        let base=URL(fileURLWithPath:"/private/tmp/LP088/baseline-data")
        let root=URL(fileURLWithPath:"/private/tmp/LP088/regression-"+UUID().uuidString)
        try FileManager.default.copyItem(at:base,to:root)
        let repo=try Repository(root:root),before=try repo.load()
        let transcripts=try before.lectures.compactMap{try repo.read($0)},analyses=try AnalysisRepository.readAll(root:root)
        for t in transcripts {
            let prepared=PreparedReading(t.cues)
            for offset in [0.0,14.0] {
                for cue in t.cues {
                    let position=Double(cue.start)/1000+offset
                    #expect(prepared.timeline.readingFocus(at:position,mapper:SubtitleTimingMapper(offset:offset)).contains(cue.id))
                }
            }
        }
        try repo.save(before)
        let backupURL=root.appendingPathComponent("qa-backup.json")
        try repo.writeRecoverySnapshot(before,to:backupURL)
        let backup=try Codec.decode(Backup.self,Data(contentsOf:backupURL));try backup.validate()
        #expect(try Repository(root:root).load()==before)
        #expect(try before.lectures.compactMap{try repo.read($0)}==transcripts)
        #expect(try AnalysisRepository.readAll(root:root)==analyses)
        let result:[String:Int]=["lessons":before.lectures.count,"cues":transcripts.reduce(0){$0+$1.cues.count},"translations":transcripts.reduce(0){$0+$1.allTranslatedCount},"analyses":analyses.count,"bookmarks":before.lectures.reduce(0){$0+$1.marks.count}]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/private/tmp/LP088/preservation.json"))
        let gui=URL(fileURLWithPath:"/private/tmp/LP088/gui-data")
        if !FileManager.default.fileExists(atPath:gui.path) {
            try FileManager.default.copyItem(at:base,to:gui)
            let qa=try Repository(root:gui);var library=try qa.load()
            let sample=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samples/Synthetic.mp4")
            let target=gui.appendingPathComponent("QA-Synthetic.mp4");try FileManager.default.copyItem(at:sample,to:target)
            library.directoryRoot=nil;library.directoryBookmark=nil
            library.lastLecture=library.lectures.first(where:{$0.transcriptVersion != nil})?.id
            for i in library.lectures.indices {
                library.lectures[i].path=target.path;library.lectures[i].bookmark=nil;library.lectures[i].subtitlePath=nil;library.lectures[i].subtitleBookmark=nil
                library.lectures[i].state.position=0
                if library.lectures[i].sources != nil {for j in library.lectures[i].sources!.indices {library.lectures[i].sources![j].path=target.path;library.lectures[i].sources![j].bookmark=nil}}
            }
            try qa.save(library)
        }
    }
}
