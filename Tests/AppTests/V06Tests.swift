import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

private actor ConcurrentMock:TranslationProvider {
    var active=0,peak=0;var calls:[[String]]=[]
    let fail:Bool;let delay:UInt64
    init(fail:Bool=false,delay:UInt64=80_000_000){self.fail=fail;self.delay=delay}
    func translate(_ b:TranslationBatch,config:TranslationConfig) async throws -> TranslationResult {
        calls.append(b.targets.map(\.id));active += 1;peak=max(peak,active);defer{active -= 1}
        try await Task.sleep(nanoseconds:calls.count==1 ? delay*2 : delay)
        if fail {return TranslationResult(items:[],inputTokens:30,outputTokens:2,problem:"mock 截断")}
        return TranslationResult(items:b.targets.map{TranslatedItem(id:$0.id,zh:"中文 "+$0.id)},inputTokens:30,outputTokens:20)
    }
}
@Suite(.serialized) @MainActor struct V06AppTests {
    func fixture() throws -> (AppStore,Transcript) {
        let (store,t)=try V052AppTests().fixture()
        var config=TranslationConfig(model:"gpt-4o-mini");config.accelerated=true
        for l in store.library.lectures{try store.translation.saveTask(TranslationTaskState(transcript:t,ids:t.cues.map(\.id),config:config),lesson:l,store:store)}
        return (store,t)
    }
    @Test func parallelOutOfOrderMergesAndStoresSidecarsWithoutLosingRecords() async throws {
        let (s,t)=try fixture();let l=s.library.lectures[0],root=s.repository!.root
        let subtitle=root.appendingPathComponent("original.vtt");try t.original.write(to:subtitle)
        s.updateLecture(l.id){$0.subtitlePath=subtitle.path}
        let mock=ConcurrentMock()
        await s.translation.executeQueue(store:s,ids:[l.id],provider:mock)
        let result=try #require(try s.repository?.read(l))
        #expect(await mock.peak==2)
        #expect(await mock.calls.count==3)
        #expect(result.translatedCount==25 && result.cues==t.cues)
        #expect(result.attempts?.count==3 && Set(result.attempts!.map(\.id)).count==3)
        #expect(result.attempts!.last?.sidecarSeconds != nil) // Coalesced file writes are measured once.
        #expect(result.attempts!.allSatisfy{$0.requestSeconds != nil && $0.databaseSeconds != nil && $0.validationSeconds != nil})
        #expect(result.usage!.allSatisfy{$0.attemptID != nil})
        #expect(result.translations.values.allSatisfy{$0.service == .openAI})
        #expect(try Data(contentsOf:subtitle)==t.original)
        let files=try #require(s.library.lectures[0].sidecars)
        #expect(files.count==2)
        let vtt=try #require(files.keys.first{$0.hasSuffix("zh.vtt")})
        #expect(try SubtitleParser.parse(Data(contentsOf:URL(fileURLWithPath:vtt)),format:"vtt").cues.count==25)
        let reopened=AppStore(root:root),again=ConcurrentMock()
        await reopened.translation.executeQueue(store:reopened,ids:[l.id],provider:again)
        #expect(await again.calls.isEmpty)
        #expect(reopened.library.lectures[0].state.offset==14)
    }
    @Test func pauseDrainsOnlyInflightAndManualResumeKeepsScope() async throws {
        let (s,_)=try fixture(),m=ConcurrentMock(delay:150_000_000);let ids=s.library.lectures.map(\.id)
        let task=Task{await s.translation.executeQueue(store:s,ids:ids,provider:m)}
        for _ in 0..<100 {if await m.calls.count==2{break};try await Task.sleep(nanoseconds:5_000_000)}
        s.translation.pause();await task.value
        #expect(await m.calls.count==2)
        #expect(try s.repository?.read(s.library.lectures[0])?.translatedCount==20)
        #expect(try s.repository?.read(s.library.lectures[1])?.translatedCount==0)
        let reopened=AppStore(root:s.repository!.root),resume=ConcurrentMock()
        #expect(!reopened.translation.running)
        await reopened.translation.executeQueue(store:reopened,ids:[ids[0]],provider:resume)
        #expect(await resume.calls.flatMap{$0}.count==5)
        #expect(try reopened.repository?.read(reopened.library.lectures[0])?.translatedCount==25)
    }
    @Test func bothFailuresRetainAllFailedIDsAndUsage() async throws {
        let (s,_)=try fixture(),m=ConcurrentMock(fail:true),l=s.library.lectures[0]
        await s.translation.executeQueue(store:s,ids:s.library.lectures.map(\.id),provider:m)
        let t=try #require(try s.repository?.read(l))
        #expect(await m.calls.count==2)
        #expect(t.task?.failedIDs.count==20 && t.usage?.count==2 && t.translatedCount==0)
        #expect(t.task?.state=="已暂停")
    }
    @Test func cancellationRecordsUnknownAndStopsQueue() async throws {
        let (s,_)=try fixture(),m=ConcurrentMock(delay:1_000_000_000)
        let task=Task{await s.translation.executeQueue(store:s,ids:s.library.lectures.map(\.id),provider:m)}
        for _ in 0..<100 {if await m.calls.count==2{break};try await Task.sleep(nanoseconds:5_000_000)}
        task.cancel();await task.value
        let t=try #require(try s.repository?.read(s.library.lectures[0]))
        #expect(await m.calls.count==2 && t.translatedCount==0)
        #expect(t.usage?.count==2 && t.usage!.allSatisfy{$0.inputTokens==nil})
    }
    @Test func versionChangesDuringRequestNeverWriteIntoNewVersion() async throws {
        let (s,_)=try fixture(),m=ConcurrentMock(delay:100_000_000),l=s.library.lectures[0]
        let task=Task{await s.translation.executeQueue(store:s,ids:[l.id],provider:m)}
        for _ in 0..<100 {if await m.calls.count==2{break};try await Task.sleep(nanoseconds:5_000_000)}
        s.updateLecture(l.id){$0.transcriptVersion=String(repeating:"0",count:64)}
        await task.value
        let old=try #require(try s.repository?.read(l))
        #expect(old.translatedCount==0 && old.usage?.count==2)
        #expect(s.library.lectures[0].transcriptVersion != l.transcriptVersion)
    }
    @Test func azureTaskIgnoresOpenAIParallelSwitch() async throws {
        let (s,t)=try fixture(),l=s.library.lectures[0],m=ConcurrentMock()
        var config=TranslationConfig();config.service = .azure;config.accelerated=true
        try s.translation.saveTask(TranslationTaskState(transcript:t,ids:t.cues.map(\.id),config:config),lesson:l,store:s)
        await s.translation.executeQueue(store:s,ids:[l.id],provider:m)
        #expect(await m.peak==1)
        #expect(await m.calls.count==1)
        let saved=try #require(try s.repository?.read(l,variantID:"azure"))
        #expect(saved.translations.values.allSatisfy{$0.service == .azure})
        #expect(saved.usage?.first?.estimatedUSD==nil)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP06_DATA"] != nil))
    func latestLibraryPreservationAndNoRequests() async throws {
        let path=try #require(ProcessInfo.processInfo.environment["LP06_DATA"])
        #expect(path.hasPrefix("/private/tmp/LecturePlayer-06-QA/"))
        guard path.hasPrefix("/private/tmp/LecturePlayer-06-QA/") else{throw Failure("隔离测试路径无效")}
        let root=URL(fileURLWithPath:path),s=AppStore(root:root);#expect(!s.fatal)
        let library=s.library;var total=0
        for lesson in library.lectures {
            let before=try #require(try s.repository?.read(lesson));total += before.translatedCount
            let m=ConcurrentMock()
            try s.translation.saveTask(TranslationTaskState(transcript:before,ids:before.cues.map(\.id),config:TranslationConfig(model:"gpt-4o-mini")),lesson:lesson,store:s)
            await s.translation.executeQueue(store:s,ids:[lesson.id],provider:m)
            #expect(await m.calls.isEmpty)
            let after=try #require(try s.repository?.read(lesson))
            #expect(after.translations==before.translations && after.original==before.original && after.cues==before.cues)
        }
        let reopened=AppStore(root:root)
        #expect(reopened.library.lectures.map(\.state)==library.lectures.map(\.state))
        #expect(reopened.library.lectures.map(\.marks)==library.lectures.map(\.marks))
        #expect(!reopened.playback.playing && !reopened.translation.running)
        let backup=try Codec.decode(Backup.self,Data(contentsOf:root.appendingPathComponent("before-v07.json")));try backup.validate()
        print("LP06_REAL_COPY_PRESERVED=\(total); lessons=\(library.lectures.count); MOCK_REQUESTS=0")
    }
}
