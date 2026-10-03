import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V05AppTests {
    @Test func partialSaveUsageAndRetryAcrossReopen() async throws {
        let (root,varLibrary,varT)=try PersistenceTests().fixture();let store=AppStore(root:root)
        var library=varLibrary;var t=varT
        t.cues.append(Cue(id:"second",start:11000,end:12000,en:"World"))
        library.lectures[0].state.offset=14
        try store.repository?.write(t,for:library.lectures[0].id);store.library=library;try store.repository?.save(library)
        let lesson=library.lectures[0],batch=TranslationBatch.make(t)[0]
        let result=TranslationResult(items:[TranslatedItem(id:t.cues[0].id,zh:"你好")],inputTokens:99,outputTokens:10)
        #expect(try await !store.translation.apply(result,batch:batch,config:TranslationConfig(model:"gpt-4o-mini"),lecture:lesson,store:store))
        let saved=try #require(try Repository(root:root).read(lesson))
        #expect(saved.translatedCount == 1 && saved.usage?.last?.inputTokens == 99 && saved.attempts?.last?.saved == 1)
        #expect(store.translation.retryIDs(saved) == ["second"])
        #expect(saved.cues == t.cues && library.lectures[0].state.offset == 14)
        let next=TranslationBatch.make(saved,ids:store.translation.retryIDs(saved),maxCues:10)
        #expect(next[0].targets.map(\.id) == ["second"])
        #expect(try await store.translation.apply(TranslationResult(items:[TranslatedItem(id:"second",zh:"世界")]),batch:next[0],config:TranslationConfig(model:"gpt-4o-mini"),lecture:lesson,store:store))
        let completed=try #require(try store.repository?.read(lesson));#expect(completed.translatedCount == 2 && completed.usage?.count == 2)
        #expect(completed.translations[t.cues[0].id] == saved.translations[t.cues[0].id])
    }
    @Test func failedResponseRecordsUnknownUsageWithoutTranslations() async throws {
        let (root,library,t)=try PersistenceTests().fixture();let store=AppStore(root:root);store.library=library
        try store.repository?.write(t,for:library.lectures[0].id);try store.repository?.save(library)
        let b=TranslationBatch.make(t)[0]
        #expect(try await !store.translation.apply(TranslationResult(items:[],problem:"响应未完成或已截断"),batch:b,config:TranslationConfig(),lecture:library.lectures[0],store:store))
        let saved=try #require(try store.repository?.read(library.lectures[0]))
        #expect(saved.translations.isEmpty && saved.usage?.count == 1 && saved.usage?[0].inputTokens == nil && saved.completedBatches.isEmpty)
    }
}

private actor PartialProvider: TranslationProvider {
    var calls=0
    func translate(_ batch:TranslationBatch,config:TranslationConfig) async throws -> TranslationResult {
        calls += 1
        return TranslationResult(items:[TranslatedItem(id:batch.targets[0].id,zh:"保存这一句")],inputTokens:70,outputTokens:12)
    }
}
extension V05AppTests {
    @Test func partialJobStopsBeforeNextPaidRequest() async throws {
        let (root,library,initial)=try PersistenceTests().fixture();let store=AppStore(root:root)
        var t=initial;t.cues += (1..<61).map { Cue(id:"cue-\($0)",start:$0*1000,end:$0*1000+900,en:"English") }
        store.library=library;try store.repository?.write(t,for:library.lectures[0].id);try store.repository?.save(library)
        let provider=PartialProvider()
        await store.translation.run(store:store,lecture:library.lectures[0],batches:TranslationBatch.make(t),config:TranslationConfig(),provider:provider)
        #expect(await provider.calls == 1)
        let saved=try #require(try store.repository?.read(library.lectures[0]));#expect(saved.translatedCount == 1 && saved.attempts?.count == 1)
    }
    @Test func manualPolicyNoStartupScanAndExplicitScanWorks() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LP05-schedule-\(UUID())")
        let folder=root.appendingPathComponent("Media/CourseA/Week8");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let store=AppStore(root:root);store.library.directoryRoot=root.appendingPathComponent("Media").path
        store.setRefreshPolicy(.manual);store.refreshIfDue(startup:true);#expect(!store.scanning && store.lastDirectoryAttempt == nil)
        store.refreshDirectory();try await V042AppTests().wait(store);#expect(store.library.courses.count == 1)
        let date=try #require(store.lastDirectoryAttempt)
        store.setRefreshPolicy(.hourly);#expect(!store.scanning && store.lastDirectoryAttempt == date)
        store.lastDirectoryAttempt=Date().addingTimeInterval(-3700);store.refreshIfDue();try await V042AppTests().wait(store)
        let fresh=store.lastDirectoryAttempt;store.refreshIfDue();#expect(!store.scanning && store.lastDirectoryAttempt == fresh)
        store.library.lectures=[];#expect(store.unlinkedCount == 0)
    }
}

@Suite(.serialized) @MainActor struct V05RealTranscriptTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP_05_COPY"] != nil))
    func currentLibraryUpgradeAndRealCourseBIMMockBatches() async throws {
        let path=try #require(ProcessInfo.processInfo.environment["LP_05_COPY"])
        guard path.hasPrefix("/private/tmp/LecturePlayer-05-QA/") else { throw Failure("需要专用隔离副本") }
        let root=URL(fileURLWithPath:path),store=AppStore(root:URL(fileURLWithPath:path))
        #expect(!store.fatal && store.library.lectures.count == 3 && store.unlinkedCount == 0)
        let original=store.library
        let snapshot=try Codec.decode(Backup.self,Data(contentsOf:root.appendingPathComponent("before-v07.json")))
        #expect(snapshot.library.lectures.map(\.state) == original.lectures.map(\.state))
        var evidence:[[String:Any]]=[]
        for lesson in original.lectures {
            let t=try #require(try store.repository?.read(lesson))
            if t.translatedCount == t.cues.count {
                store.current=lesson.id;store.transcript=t;store.translation.start(store:store,ids:nil)
                #expect(!store.translation.running && store.translation.status.contains("没有发起请求"))
                #expect(try store.repository?.read(lesson) == t)
                continue
            }
            let batches=TranslationBatch.make(t,budget:4000,maxCues:30)
            #expect(batches.allSatisfy { $0.targets.count <= 30 })
            #expect(batches.flatMap(\.targets) == t.cues)
            let batch=batches[0]
            let reply=Array(batch.targets.dropLast().reversed()).map { TranslatedItem(id:$0.id,zh:"MOCK，仅用于软件测试") }
            #expect(try await !store.translation.apply(TranslationResult(items:reply,inputTokens:400,outputTokens:200),batch:batch,config:TranslationConfig(model:"gpt-4o-mini"),lecture:lesson,store:store))
            let partial=try #require(try store.repository?.read(lesson));#expect(partial.translatedCount == 29 && partial.cues == t.cues && partial.original == t.original)
            let retry=TranslationBatch.make(partial,ids:store.translation.retryIDs(partial),maxCues:10)
            #expect(retry.count == 1 && retry[0].targets.count == 1)
            #expect(try await store.translation.apply(TranslationResult(items:retry[0].targets.map {TranslatedItem(id:$0.id,zh:"MOCK 补译")},inputTokens:20,outputTokens:10),batch:retry[0],config:TranslationConfig(model:"gpt-4o-mini"),lecture:lesson,store:store))
            let reopened=try #require(try Repository(root:root).read(lesson));#expect(reopened.translatedCount == 30 && reopened.cues == t.cues)
            evidence.append(["title":lesson.title,"originalCues":t.cues.count,"maxBatchCues":batches.map(\.targets.count).max() ?? 0,"savedBeforeRetry":29,"savedAfterRetry":30,"network":"mock only"])
        }
        #expect(store.library.lectures.map(\.state) == original.lectures.map(\.state))
        #expect(store.library.lectures.map(\.marks) == original.lectures.map(\.marks))
        let backup=try store.snapshot();try backup.validate()
        try JSONSerialization.data(withJSONObject:evidence,options:.prettyPrinted).write(to:root.appendingPathComponent("mock-validation.json"))
    }
}
