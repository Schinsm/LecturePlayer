import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

private actor QueueMock:TranslationProvider {
    var calls:[[String]]=[]
    var mode:String
    init(_ mode:String="success"){self.mode=mode}
    func translate(_ batch:TranslationBatch,config:TranslationConfig) async throws -> TranslationResult {
        calls.append(batch.targets.map(\.id))
        if mode=="wait" {try await Task.sleep(nanoseconds:3_000_000_000)}
        if mode=="partial" {return TranslationResult(items:[TranslatedItem(id:batch.targets[0].id,zh:"已保存")],inputTokens:10,outputTokens:5)}
        return TranslationResult(items:batch.targets.map{TranslatedItem(id:$0.id,zh:"mock 译文")},inputTokens:10,outputTokens:5)
    }
}
@Suite(.serialized) @MainActor struct V052AppTests {
    func fixture() throws -> (AppStore,Transcript) {
        let (root,varLibrary,_)=try PersistenceTests().fixture();var library=varLibrary;library.lastLecture=nil
        let text="WEBVTT\n\n"+(0..<25).map {"cue\($0)\n\(String(format:"00:%02d.000",$0)) --> \(String(format:"00:%02d.900",$0))\nEnglish \($0)\n"}.joined(separator:"\n")
        let t=try SubtitleParser.parse(Data(text.utf8),format:"vtt")
        library.lectures[0].transcriptVersion=t.version;library.lectures[0].state.offset=14
        var second=library.lectures[0];second.id=UUID();second.title="Other";library.lectures.append(second)
        let r=try Repository(root:root);try r.save(library);for l in library.lectures{try r.write(t,for:l.id)}
        return (AppStore(root:root),t)
    }
    func stage(_ store:AppStore,_ t:Transcript) throws {
        for l in store.library.lectures{try store.translation.saveTask(TranslationTaskState(transcript:t,ids:t.cues.map(\.id),config:TranslationConfig(model:"gpt-4o-mini")),lesson:l,store:store)}
    }
    @Test func partialPausesAllAndResumeKeepsOriginalScope() async throws {
        let (store,t)=try fixture();try stage(store,t);let ids=store.library.lectures.map(\.id),p=QueueMock("partial")
        await store.translation.executeQueue(store:store,ids:ids,provider:p)
        #expect(await p.calls.count==1)
        #expect(store.translation.states.values.allSatisfy{$0.state=="已暂停"})
        let first=store.library.lectures[0],saved=try #require(try store.repository?.read(first))
        #expect(saved.translatedCount==1 && saved.task?.ids.count==25 && saved.task?.retrySize==5)
        let reopened=AppStore(root:store.repository!.root)
        #expect(!reopened.translation.running && reopened.translation.states[first.id]?.state=="待恢复")
        let mock=QueueMock();reopened.current=ids[1]
        await reopened.translation.executeQueue(store:reopened,ids:[ids[0]],provider:mock)
        let calls=await mock.calls
        #expect(calls[0].count==5 && calls.flatMap{$0}.count==24 && !calls.flatMap{$0}.contains(t.cues[0].id))
        #expect(try reopened.repository?.read(first)?.translatedCount==25)
        #expect(try reopened.repository?.read(reopened.library.lectures[1])?.translatedCount==0)
        #expect(reopened.translation.states[ids[0]]?.state=="完成" && reopened.library.lectures[0].state.offset==14)
    }
    @Test func queueSequentialCancelAndNoNextLesson() async throws {
        let (store,t)=try fixture();try stage(store,t);let provider=QueueMock("wait")
        let task=Task{await store.translation.executeQueue(store:store,ids:store.library.lectures.map(\.id),provider:provider)}
        defer{task.cancel()}
        // Cancel an in-flight request, rather than racing task startup on a busy host.
        for _ in 0..<500 {if await !provider.calls.isEmpty {break};try await Task.sleep(for:.milliseconds(10))}
        try #require(await provider.calls.count==1)
        task.cancel();await task.value
        #expect(await provider.calls.count==1)
        #expect(store.translation.states.values.allSatisfy{$0.state=="已暂停"})
        let saved=try #require(try store.repository?.read(store.library.lectures[0]))
        #expect(saved.translatedCount==0 && saved.usage?.last?.inputTokens==nil)
    }
    @Test func changedVersionAndCachedCuesNeverDispatch() async throws {
        let (store,t)=try fixture();try stage(store,t)
        let first=store.library.lectures[0];var modified=t
        for cue in t.cues{modified.translations[cue.id]=Translation(ai:"缓存",cacheKey:"legacy")}
        modified.task=t.task // restore task below
        modified.task=store.translation.states[first.id]
        try store.repository?.write(modified,for:first.id)
        let p=QueueMock();await store.translation.executeQueue(store:store,ids:[first.id],provider:p)
        #expect(await p.calls.isEmpty)
        let other=store.library.lectures[1];store.updateLecture(other.id){$0.transcriptVersion="missing"}
        await store.translation.executeQueue(store:store,ids:[other.id],provider:p)
        #expect(await p.calls.isEmpty)
    }
    @Test func importEnqueueOnlyExplicitSuccessfulIDs() async throws {
        let (store,t)=try fixture(),p=QueueMock()
        try store.translation.enqueueImports([],store:store,provider:p)
        #expect(!store.translation.running && store.translation.states.isEmpty)
        let lesson=store.library.lectures[0]
        let preview=ImportTranslationPreview(rowID:UUID(),transcript:t,config:TranslationConfig(model:"gpt-4o-mini"),summary:"")
        try store.translation.enqueueImports([(lesson.id,preview)],store:store,provider:p)
        for _ in 0..<100 {if !store.translation.running{break};try await Task.sleep(nanoseconds:20_000_000)}
        #expect(await p.calls.count==3)
        #expect(try store.repository?.read(lesson)?.translatedCount==25)
        #expect(try store.repository?.read(store.library.lectures[1])?.translatedCount==0)
    }
    @Test func changedImportPreviewPreventsAllDispatchAndStaging() throws {
        let (store,t)=try fixture(),mock=QueueMock()
        let good=ImportTranslationPreview(rowID:UUID(),transcript:t,config:TranslationConfig(),summary:"")
        var changed=t;changed.version=String(repeating:"a",count:64)
        let bad=ImportTranslationPreview(rowID:UUID(),transcript:changed,config:TranslationConfig(),summary:"")
        #expect(throws:(any Error).self) {try store.translation.enqueueImports([(store.library.lectures[0].id,good),(store.library.lectures[1].id,bad)],store:store,provider:mock)}
        #expect(!store.translation.running && store.translation.states.isEmpty)
        #expect(try store.repository?.read(store.library.lectures[0])?.task==nil)
    }
    @Test func thumbnailRealFrameCacheAndFallback() async throws {
        let (_,library,_)=try PersistenceTests().fixture();var lesson=library.lectures[0]
        let camera=lesson.mediaSources[0];var missing=camera;missing.id=UUID();missing.path="/missing-screen";missing.role = .screen
        var fallback=camera;fallback.role = .camera;lesson.mediaSources=[missing,fallback]
        #expect(ThumbnailRequest.source(for:lesson)?.id==fallback.id)
        #expect(ThumbnailRequest.time(duration:10)==5 && ThumbnailRequest.time(duration:6000)==30)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LP052-thumbs-\(UUID())"),renderer=ThumbnailRenderer(root:root)
        let request=ThumbnailRequest(source:camera)
        async let one=renderer.image(request);async let two=renderer.image(request);async let three=renderer.image(request)
        let urls=try await [one,two,three]
        #expect(Set(urls).count==1 && FileManager.default.fileExists(atPath:urls[0].path))
        #expect(await renderer.peakActive<=2)
        let stamp=try FileManager.default.attributesOfItem(atPath:urls[0].path)[.modificationDate] as? Date
        _ = try await renderer.image(request)
        #expect(try FileManager.default.attributesOfItem(atPath:urls[0].path)[.modificationDate] as? Date == stamp)
    }
}

@Suite(.serialized) @MainActor struct V052RealCopyTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP052_DATA"] != nil))
    func latestIsolatedCourseBFailureScopeAndPreservation() async throws {
        let path=try #require(ProcessInfo.processInfo.environment["LP052_DATA"])
        guard path.hasPrefix("/private/tmp/LecturePlayer-052-QA/") else{throw Failure("必须使用隔离副本")}
        let store=AppStore(root:URL(fileURLWithPath:path));#expect(!store.fatal)
        let baseline=store.library
        let lesson=try #require(baseline.lectures.first{$0.title.contains("SAMPLE1002")})
        let t=try #require(try store.repository?.read(lesson))
        let failure=try #require(t.attempts?.last(where:{$0.expected==30 && $0.saved==0}))
        let ids=try #require(failure.targetIDs),batches=TranslationBatch.make(t,ids:Set(ids))
        #expect(batches.count==3 && batches.flatMap(\.targets).map(\.id)==ids)
        var record=TranslationTaskState(transcript:t,ids:ids,config:TranslationConfig(model:"gpt-4o-mini"))
        record.failedIDs=ids;record.retrySize=5
        try store.translation.saveTask(record,lesson:lesson,store:store)
        let mock=QueueMock();await store.translation.executeQueue(store:store,ids:[lesson.id],provider:mock)
        let saved=try #require(try store.repository?.read(lesson))
        #expect(saved.cues==t.cues && saved.original==t.original)
        #expect(t.translations.allSatisfy{saved.translations[$0.key]==$0.value})
        #expect(saved.translatedCount==t.translatedCount+ids.filter{t.translations[$0]==nil}.count)
        #expect(store.library.lectures.map(\.state)==baseline.lectures.map(\.state))
        #expect(store.library.lectures.map(\.marks)==baseline.lectures.map(\.marks))
        let snapshot=try Codec.decode(Backup.self,Data(contentsOf:store.repository!.root.appendingPathComponent("before-v07.json")));try snapshot.validate()
        #expect(snapshot.library.lectures.map(\.state)==baseline.lectures.map(\.state))
        let report:[String:Any]=["network":"mock only","before":t.translatedCount,"after":saved.translatedCount,"failedScope":ids.count,"calls":await mock.calls.count,"originalAndExistingTranslationsPreserved":true]
        try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted).write(to:store.repository!.root.appendingPathComponent("v052-mock-report.json"))
    }
}
