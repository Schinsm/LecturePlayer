import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V081PreservationTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP08_DATA"] != nil))
    func latestLibraryBackupAndAllVariantsPreserved() throws {
        let path=try #require(ProcessInfo.processInfo.environment["LP08_DATA"])
        try #require(["/private/tmp/LP081/data","/private/tmp/LP082/data","/private/tmp/LP083/data","/private/tmp/LP084/data"].contains(path))
        let root=URL(fileURLWithPath:path),repository=try Repository(root:root),library=try repository.load()
        let urls=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("transcripts"),includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}
        let originals=try Dictionary(uniqueKeysWithValues:urls.map{($0,try Data(contentsOf:$0))})
        let transcripts=try Dictionary(uniqueKeysWithValues:originals.map{($0.key.deletingPathExtension().lastPathComponent,try Codec.decode(Transcript.self,$0.value))})
        let records=try AnalysisRepository.readAll(root:root)
        let backup=Backup(library:library,transcripts:transcripts,analyses:try Backup.analysisPayload(records),processing:[])
        try backup.validate()
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent("LP081-restored-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:destination)}
        let target=try Repository(root:destination)
        try BackupPayloadTransaction.restore(try Codec.decode(Backup.self,Codec.encode(backup)),root:destination){try target.save(library)}
        func ordered(_ input:Library)->Library {var v=input;v.courses.sort{$0.id.uuidString<$1.id.uuidString};v.folders.sort{$0.id.uuidString<$1.id.uuidString};v.lectures.sort{$0.id.uuidString<$1.id.uuidString};return v}
        try #require(ordered(try target.load())==ordered(library))
        for lesson in library.lectures {#expect(try target.read(lesson)==repository.read(lesson))}
        #expect(try AnalysisRepository.readAll(root:destination).sorted{$0.lessonID.uuidString<$1.lessonID.uuidString} == records.sorted{$0.lessonID.uuidString<$1.lessonID.uuidString})
        for (url,bytes) in originals {#expect(try Data(contentsOf:url)==bytes)}
        print("LP081_BACKUP_PRESERVED lessons=\(library.lectures.count) translations=\(transcripts.values.reduce(0){$0+$1.allTranslatedCount}) analyses=\(records.count) originalTranscriptBytes=true allStudyMetadata=true")
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP081_GUI"] != nil))
    func prepareClearlyLabeledHierarchyFixture() async throws {
        let path=try #require(ProcessInfo.processInfo.environment["LP081_GUI"])
        try #require(path=="/private/tmp/LP081/gui-data")
        let root=URL(fileURLWithPath:path),repo=try Repository(root:root)
        var library=try repo.load()
        let index=try #require(library.lectures.firstIndex{$0.title.contains("SAMPLE1001")})
        let lesson=library.lectures[index],t=try #require(try repo.read(lesson))
        let cues=AnalysisPlan.ordered(t.cues)
        var points:[AnalysisChapter]=[]
        for n in 0..<6 {
            let members=Array(cues[(n*cues.count/6)..<((n+1)*cues.count/6)])
            var point=AnalysisChapter(id:"mock-\(n)",startCueID:members[0].id,endCueID:members.last!.id,title:"离线验收知识点 \(n+1)",points:["仅验证界面与跳转，不是课程总结。"])
            point.memberCueIDs=members.map(\.id);points.append(point)
        }
        var record=LessonAnalysis(lessonID:lesson.id,sourceVersion:t.version);record.schema=2
        var doc=AnalysisDocument(chapters:points,overview:[.init(text:"离线界面验收示例",chapterID:points[0].id)])
        doc.topics=(0..<2).map {AnalysisTopic(id:"topic-\($0)",title:"离线验收主题 \($0+1)",overview:"验证展开与搜索",subtopics:Array(points[($0*3)..<(($0+1)*3)]))}
        record.completed=doc;record.completedAt=Date();record.completedConfig=AnalysisConfig(model:"gpt-5.6-luna")
        try record.validate(transcript:t);try await AnalysisRepository(root:root).save(record)
        library.lastLecture=lesson.id;library.lectures[index].studyPanel="chapters"
        library.lectures[index].state.offset=14;library.lectures[index].state.position=90
        library.lectures[index].videoCaptions=VideoCaptionPreferences();library.lectures[index].videoCaptions!.enabled=true
        try repo.save(library)
    }
}
