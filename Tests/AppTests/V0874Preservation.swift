import Foundation
import Testing
import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V0874Preservation {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP0874_DATA"] == "1"))
    func completeLatestCopyBackupAndReadOnlyLoads() async throws {
        let base=URL(fileURLWithPath:ProcessInfo.processInfo.environment["LP0874_DATA_ROOT"] ?? "/private/tmp/LP0874/baseline-data")
        let root=URL(fileURLWithPath:"/private/tmp/LP0874/preservation-"+UUID().uuidString)
        try FileManager.default.copyItem(at:base,to:root)
        let repo=try Repository(root:root),before=try repo.load()
        let all=try before.lectures.compactMap {try repo.read($0)}
        let analyses=try AnalysisRepository.readAll(root:root)
        let loader=LessonLoadCoordinator()
        for lesson in before.lectures { let value=try await loader.load(lesson,root:root);#expect(value.transcript == (try repo.read(lesson))) }
        let backupURL=root.appendingPathComponent("verified-recovery.json")
        try repo.writeRecoverySnapshot(before,to:backupURL)
        let backup=try Codec.decode(Backup.self,Data(contentsOf:backupURL));try backup.validate()
        #expect(backup.transcripts.count==all.count);#expect(backup.analyses?.count==analyses.count)
        #expect(try Repository(root:root).load()==before)
        #expect(try before.lectures.compactMap{try repo.read($0)}==all)
        #expect(try AnalysisRepository.readAll(root:root)==analyses)
        let result:[String:Int]=["lessons":before.lectures.count,"cues":all.reduce(0){$0+$1.cues.count},"translations":all.reduce(0){$0+$1.allTranslatedCount},"analyses":analyses.count,"bookmarks":before.lectures.reduce(0){$0+$1.marks.count}]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/private/tmp/LP0874/preservation.json"))
    }
}
