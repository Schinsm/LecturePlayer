import Foundation
import Testing
import SwiftData
@testable import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V07AppTests {
    @Test func concurrentVariantsAndViewSelectionRemainIndependent() async throws {
        let (s,t)=try V052AppTests().fixture();let l=s.library.lectures[0];s.current=l.id;s.transcript=t
        let batch=TranslationBatch.make(t,maxCues:2)[0]
        let open=TranslationConfig(model:"gpt-4o-mini");var deepConfig=open;deepConfig.service = .deepL;let deep=deepConfig
        let first=TranslationResult(items:batch.targets.map{TranslatedItem(id:$0.id,zh:"OpenAI")})
        let second=TranslationResult(items:batch.targets.map{TranslatedItem(id:$0.id,zh:"DeepL")})
        s.selectTranslation("apple")
        async let a=s.translation.commit(first,batch:batch,config:open,lecture:l,store:s)
        async let b=s.translation.commit(second,batch:batch,config:deep,lecture:l,store:s)
        _=try await(a,b)
        #expect(s.transcript?.variantID=="apple" && s.transcript?.translatedCount==0)
        let saved=try #require(try s.repository?.read(l))
        #expect(saved.variants?["openAI"]?.translations.count==2 && saved.variants?["deepL"]?.translations.count==2)
        #expect(Set(saved.usage!.compactMap(\.variantID))==["openAI","deepL"])
        #expect(s.library.lectures[0].state==l.state && s.library.lectures[0].marks==l.marks)
        let reopened=AppStore(root:s.repository!.root)
        #expect(reopened.library.lectures[0].selectedTranslationVariantID=="apple" && !reopened.translation.running)
    }
    @Test func fileRetryRetainsTranslationsAndAddsNoRequests() async throws {
        let (s,t)=try V052AppTests().fixture();var l=s.library.lectures[0]
        let root=s.repository!.root,subtitle=root.appendingPathComponent("source.vtt");try t.original.write(to:subtitle)
        l.subtitlePath=subtitle.path;l.sources=nil;l.path=root.appendingPathComponent("missing/s1.mp4").path
        var value=t.viewing("deepL");value.translations[t.cues[0].id]=Translation(ai:"保存",cacheKey:"mock");try s.repository!.write(value,for:l.id)
        let url=try s.repository!.transcriptURL(l.id,t.version)
        let failed=try await s.translation.writer.saveFiles(lesson:l,url:url)
        #expect(failed.fileStatus.contains("待保存") && failed.transcript.translations==value.translations)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("missing"),withIntermediateDirectories:true)
        let success=try await s.translation.writer.saveFiles(lesson:l,url:url)
        #expect(success.sidecars?.count==2 && success.transcript.usage==nil && success.transcript.attempts==nil)
    }
    @Test func interruptedMigrationRollsBackOriginalPayloads() throws {
        let (root,lib,t)=try PersistenceTests().fixture();let repo=try Repository(root:root)
        let journal=root.appendingPathComponent("migration-v07.pending"),old=journal.appendingPathComponent("original")
        try FileManager.default.createDirectory(at:old,withIntermediateDirectories:true)
        let name="\(lib.lectures[0].id)-\(t.version).json";let bytes=try Codec.encode(t)
        try bytes.write(to:old.appendingPathComponent(name));try Data("corrupt staged payload".utf8).write(to:root.appendingPathComponent("transcripts/"+name))
        try repo.recoverVariantMigration(schema:3)
        #expect(try Data(contentsOf:root.appendingPathComponent("transcripts/"+name))==bytes)
        #expect(!FileManager.default.fileExists(atPath:journal.path))
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP07_DATA"] != nil))
    func latestRealCopyMigratesEveryValueAndRestoresBackup() throws {
        let path=try #require(ProcessInfo.processInfo.environment["LP07_DATA"])
        guard path.hasPrefix("/private/tmp/LecturePlayer-07-QA/") else{throw Failure("Requires isolated data")}
        let root=URL(fileURLWithPath:path),files=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("transcripts"),includingPropertiesForKeys:nil)
        var old:[String:Transcript]=[:];for f in files where f.pathExtension=="json" {old[f.lastPathComponent]=try Codec.decode(Transcript.self,Data(contentsOf:f))}
        let repo=try Repository(root:root),lib=try repo.load();#expect(lib.schema==4)
        var count=0
        for (name,before) in old {
            let after=try Codec.decode(Transcript.self,Data(contentsOf:root.appendingPathComponent("transcripts/"+name)));try after.validate()
            let flattened=after.variants!.values.reduce(into:[String:Translation]()){$0.merge($1.translations){a,_ in a}}
            #expect(flattened==before.translations && after.cues==before.cues && after.original==before.original)
            count += flattened.count
        }
        let snapshots=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("before-v07-")}
        let backup=try Codec.decode(Backup.self,Data(contentsOf:try #require(snapshots.first)));try backup.validate()
        #expect(lib.lectures.map(\.state)==backup.library.lectures.map(\.state) && lib.lectures.map(\.marks)==backup.library.lectures.map(\.marks))
        let reopened=try Repository(root:root).load();#expect(reopened==lib)
        for (_,var t) in backup.transcripts {let prior=t.translations;try t.migrateVariants();#expect(t.allTranslatedCount==prior.count)}
        print("LP07_MIGRATION: lessons=\(lib.lectures.count) preservedTranslations=\(count) networkRequests=0")
    }
}
