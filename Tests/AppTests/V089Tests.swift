import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V089AppTests {
    @Test func interruptedTranscriptCommitRecoversFixedPaths() async throws {
        let (store,lesson,url,t)=try V0872Tests().fixture()
        let failing=TranslationWriter(writeTranscript:{_,_ in throw NSError(domain:NSPOSIXErrorDomain,code:28)})
        do {_=try await failing.saveFiles(lesson:lesson,url:url);Issue.record("Expected disk failure")} catch {}
        #expect(try Codec.decode(Transcript.self,Data(contentsOf:url))==t)
        let base=URL(fileURLWithPath:lesson.path).deletingLastPathComponent().appendingPathComponent("LecturePlayer")
        func files()->[String] {let e=FileManager.default.enumerator(at:base,includingPropertiesForKeys:nil)!;return e.compactMap{($0 as? URL)?.path}.filter{$0.hasSuffix(".vtt") || $0.hasSuffix(".md")}.sorted()}
        let before=files();#expect(before.count==2)
        let result=try await store.translation.writer.saveFiles(lesson:lesson,url:url)
        #expect(files()==before && result.transcript.variants?["openAI"]?.generatedFiles?.count==2)
        #expect(result.transcript.translations==t.translations && result.transcript.attempts==t.attempts)
    }
    @Test func fileWindowOnlyReadsSelectedLessonAndSkipsEmptyHistory() async throws {
        let (store,lesson,url,_)=try V0872Tests().fixture()
        _=try await store.translation.writer.saveFiles(lesson:lesson,url:url)
        let other=store.library.lectures.first{$0.id != lesson.id}!
        try Data("corrupt".utf8).write(to:try store.repository!.transcriptURL(other.id,other.transcriptVersion!))
        let value=try await LessonFileCache.shared.load(root:store.repository!.root,lesson:lesson)
        #expect(value.video.count==1 && value.translations.count==1)
        #expect(value.translations[0].files.count==2)
        let again=try await LessonFileCache.shared.load(root:store.repository!.root,lesson:lesson)
        #expect(again.translations[0].files.map(\.path)==value.translations[0].files.map(\.path))
    }
    @Test func backgroundPreparationCancelsAndBatchIsolatesCorruptLesson() async throws {
        let (store,_)=try V052AppTests().fixture()
        let lesson=store.library.lectures[0],other=store.library.lectures[1],root=store.repository!.root
        let bad=AnalysisRepository.fileURL(root:root,lessonID:other.id,sourceVersion:other.transcriptVersion!)
        try FileManager.default.createDirectory(at:bad.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("broken".utf8).write(to:bad)
        let rows=try await Task.detached{try ChapterBatchPlanner.rows(lessons:[lesson,other],root:root,entries:[],config:AnalysisConfig(model:"gpt-4o-mini"))}.value
        #expect(rows.first{$0.id==lesson.id}?.entry != nil)
        #expect(rows.first{$0.id==other.id}?.entry == nil)
        let work=Task.detached {
            try await Task.sleep(for:.seconds(1))
            return try AnalysisPreparation.load(root:root,lesson:lesson,config:AnalysisConfig(model:"gpt-4o-mini"))
        }
        work.cancel()
        do {_=try await work.value;Issue.record("Cancelled preparation returned a result")}catch is CancellationError {}
        #expect(!store.processing.running)
    }
    @Test func v4MigrationSnapshotsBeforeCommitAndBackupRestoresIndex() async throws {
        let (store,lesson,url,_)=try V0872Tests().fixture()
        let result=try await store.translation.writer.saveFiles(lesson:lesson,url:url)
        let backup=try store.snapshot();#expect(backup.schema==6)
        let decoded=try Codec.decode(Backup.self,Codec.encode(backup));try decoded.validate()
        #expect(decoded.transcripts["\(lesson.id)-\(lesson.transcriptVersion!)"]?.variants?["openAI"]?.generatedFiles==result.transcript.variants?["openAI"]?.generatedFiles)
        let restored=store.repository!.root.appendingPathComponent("restored")
        let repo=try Repository(root:restored)
        try BackupPayloadTransaction.restore(decoded,root:restored){try repo.save(decoded.library)}
        #expect(try repo.read(lesson)?.variants?["openAI"]?.generatedFiles==result.transcript.variants?["openAI"]?.generatedFiles)
    }
}

extension V089AppTests {
    @Test func metadataOnlyUpgradePreservesDamagedAnalysisWithoutBlockingOtherLessons() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("migration089-\(UUID())")
        let repo=try Repository(root:root)
        repo.context.insert(MetadataRecord(key:"schema",payload:try Codec.encode(4)))
        try repo.context.save()
        let bad=root.appendingPathComponent("analyses/broken.json")
        try FileManager.default.createDirectory(at:bad.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("original damaged file".utf8).write(to:bad)
        #expect(try repo.load().schema==5)
        let snapshot=try #require(FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("before-v089-")})
        #expect(try Data(contentsOf:snapshot.appendingPathComponent("analyses/broken.json"))==Data(contentsOf:bad))
        #expect(try Codec.decode(Library.self,Data(contentsOf:snapshot.appendingPathComponent("library.json"))).schema==4)
    }
}
